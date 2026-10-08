// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DuelToken} from "./DuelToken.sol";
import {DuelHook} from "./DuelHook.sol";
import {DuelMath} from "./libraries/DuelMath.sol";
import {IDuelFactory} from "./interfaces/IDuelFactory.sol";
import {DuelVersion} from "./libraries/DuelVersion.sol";

/// @title DuelFactory
/// @notice Launches Duel pairs: two opposing tokens, their two single-sided ETH pools and the A/D cross pool, all
///         seeded and locked in one transaction. Owns the protocol configuration, which only changes after a delay.
contract DuelFactory is IDuelFactory, IUnlockCallback, Ownable2Step {
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Protocol configuration; fee terms are frozen into each pair at creation.
    struct Config {
        address treasury; // receiver of the launch fee and of the protocol's share of swap fees
        uint96 launchFee; // ETH paid per pair
        uint96 startFdv; // launch FDV of each token, in wei
        uint16 crossShareBps; // share of each supply seeded in the cross pool
        uint16 swapFeeBps; // fee on ETH swaps
        uint16 switchFeeBps; // fee on cross pool swaps, burned
        uint16 protocolShareBps; // protocol share of the ETH swap fee
        uint16 potShareBps; // round pot share of the ETH swap fee
        uint16 snipeStartBps; // anti-snipe tax at launch
        uint16 snipeWindow; // seconds until the anti-snipe tax reaches zero
    }

    /// @notice Parameters of a new pair.
    struct CreateParams {
        string nameA;
        string symbolA;
        string nameD;
        string symbolD;
        string metadataURI;
        uint256 buyA; // ETH the creator spends on side A at launch, free of the anti-snipe tax
        uint256 buyD; // ETH the creator spends on side D at launch, free of the anti-snipe tax
        bool supporter; // give the creator's fee share to the round pots
        uint8 category; // what the duel is about, as the app numbers its categories: any number, 0 for none
        bytes32 config; // configHash() as the launcher was shown it: the launch reverts ConfigChanged once it changed
    }

    struct SeedData {
        PoolKey keyA;
        PoolKey keyD;
        PoolKey keyX;
        int24 startTick;
        uint256 crossAmount;
        address creator;
        uint256 buyA;
        uint256 buyD;
    }

    error CreationPaused();
    error InsufficientValue();
    error InvalidConfig();
    error NoPendingConfig();
    error ConfigNotReady();
    error NotPoolManager();
    error CreatorBuyTooLarge();
    error TransferFailed();
    error InvalidMetadata();
    error ConfigChanged();
    error NotCreator();
    error NotPendingCreator();

    event PairCreated(uint256 indexed pairId, address indexed creator, address tokenA, address tokenD);
    event ConfigProposed(Config config, uint256 eta);
    event ConfigApplied(Config config);
    event ConfigCancelled();
    event PausedSet(bool paused);
    event CreatorTransferStarted(uint256 indexed pairId, address indexed creator, address indexed newCreator);

    /// @notice Version of the launchpad this contract is part of (DuelVersion).
    uint256 public constant VERSION = DuelVersion.NUMBER;
    /// @notice Code name of the launchpad's version.
    string public constant CODENAME = DuelVersion.CODENAME;
    /// @notice Delay between proposing and applying a configuration.
    uint256 public constant CONFIG_DELAY = 48 hours;
    /// @notice Largest share of a side's supply the creator may buy at launch.
    uint256 public constant CREATOR_BUY_MAX_BPS = 500;
    /// @notice Longest name of a side, in bytes: 32 characters of any script, the launch form's limit.
    uint256 public constant MAX_NAME_BYTES = 128;
    /// @notice Longest ticker of a side, in bytes: 10 characters of any script.
    uint256 public constant MAX_SYMBOL_BYTES = 40;
    /// @notice Longest metadata URI, in bytes: the form's description, images and links, encoded, with room to spare.
    ///         What lists, pages and messages read of a duel stays bounded.
    uint256 public constant MAX_METADATA_BYTES = 4096;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_LAUNCH_FEE = 0.01 ether;
    uint256 internal constant MIN_START_FDV = 0.1 ether;
    uint256 internal constant MAX_START_FDV = 1000 ether;

    /// @notice Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice Hook shared by every Duel pool.
    DuelHook public immutable hook;

    /// @notice When the proposed configuration can be applied; zero when none is waiting.
    uint256 public pendingConfigEta;
    /// @notice When true, nobody but the owner can create a pair. Trading is never affected. True from the deployment:
    ///         the owner launches the first pair, whose id is 1, then opens the launches (`setPaused`).
    bool public paused = true;

    Config internal _config;
    Config internal _pendingConfig;

    /// @notice The address each pair's creator offered its role to, until it accepts; zero when none.
    mapping(uint256 pairId => address newCreator) public pendingCreator;

    /// @param _poolManager Uniswap V4 PoolManager.
    /// @param _hook DuelHook, deployed at an address carrying its permission flags.
    /// @param _owner Owner of the configuration (a multisig).
    /// @param config_ Initial configuration.
    constructor(IPoolManager _poolManager, DuelHook _hook, address _owner, Config memory config_) Ownable(_owner) {
        _validate(config_);
        poolManager = _poolManager;
        hook = _hook;
        _config = config_;
    }

    // ------------------------------------------------------------------
    // Pair creation
    // ------------------------------------------------------------------

    /// @notice Creates a pair, seeds its three pools and runs the creator's optional launch buys.
    /// @dev `msg.value` must cover the launch fee plus both launch buys; any excess is refunded. `params.config` must be
    ///      `configHash()`, the terms the launcher was shown.
    /// @return pairId Id of the new pair in the hook.
    function createPair(CreateParams calldata params) external payable returns (uint256 pairId) {
        // paused, the factory launches for its owner alone: from its deployment, so that the first pair is its own
        if (paused && msg.sender != owner()) revert CreationPaused();
        if (
            !_fits(params.nameA, MAX_NAME_BYTES) || !_fits(params.nameD, MAX_NAME_BYTES)
                || !_fits(params.symbolA, MAX_SYMBOL_BYTES) || !_fits(params.symbolD, MAX_SYMBOL_BYTES)
                || bytes(params.metadataURI).length > MAX_METADATA_BYTES
        ) revert InvalidMetadata();
        Config memory cfg = _config;
        // the terms the launcher agreed to: a configuration applied since they read it would change the duel's
        if (_hash(cfg) != params.config) revert ConfigChanged();
        uint256 cost = cfg.launchFee + params.buyA + params.buyD;
        if (msg.value < cost) revert InsufficientValue();

        DuelToken tokenA = new DuelToken(params.nameA, params.symbolA, params.metadataURI, address(this));
        DuelToken tokenD = new DuelToken(params.nameD, params.symbolD, params.metadataURI, address(this));
        uint256 supply = tokenA.TOTAL_SUPPLY();

        (uint160 sqrtStartPrice, int24 startTick) = DuelMath.startPrice(supply, cfg.startFdv, hook.ETH_TICK_SPACING());
        pairId = hook.registerPair(
            address(tokenA),
            address(tokenD),
            msg.sender,
            params.supporter,
            params.category,
            DuelHook.FeeConfig({
                swapFeeBps: cfg.swapFeeBps,
                switchFeeBps: cfg.switchFeeBps,
                protocolShareBps: cfg.protocolShareBps,
                potShareBps: cfg.potShareBps,
                snipeStartBps: cfg.snipeStartBps,
                snipeWindow: cfg.snipeWindow
            }),
            startTick
        );

        (PoolKey memory keyA, PoolKey memory keyD, PoolKey memory keyX) = hook.poolKeys(pairId);
        poolManager.initialize(keyA, sqrtStartPrice);
        poolManager.initialize(keyD, sqrtStartPrice);
        poolManager.initialize(keyX, uint160(DuelMath.Q96));
        poolManager.unlock(
            abi.encode(
                SeedData({
                    keyA: keyA,
                    keyD: keyD,
                    keyX: keyX,
                    startTick: startTick,
                    crossAmount: (supply * cfg.crossShareBps) / BPS,
                    creator: msg.sender,
                    buyA: params.buyA,
                    buyD: params.buyD
                })
            )
        );

        // announced before any ETH leaves: a launcher that launches again from its refund cannot reorder the logs
        emit PairCreated(pairId, msg.sender, address(tokenA), address(tokenD));
        _send(cfg.treasury, cfg.launchFee);
        _send(msg.sender, msg.value - cost);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SeedData memory s = abi.decode(data, (SeedData));
        address tokenA = Currency.unwrap(s.keyA.currency1);
        address tokenD = Currency.unwrap(s.keyD.currency1);
        uint256 supply = DuelToken(tokenA).TOTAL_SUPPLY();

        _seedEthPool(s.keyA, s.startTick, supply - s.crossAmount);
        _seedEthPool(s.keyD, s.startTick, supply - s.crossAmount);
        _seedCrossPool(s.keyX, s.crossAmount);
        _settleToken(tokenA);
        _settleToken(tokenD);

        _creatorBuy(s.keyA, s.buyA, s.creator, supply);
        _creatorBuy(s.keyD, s.buyD, s.creator, supply);
        return "";
    }

    /// @dev Single-sided position holding `amount` tokens from the lowest usable tick up to the launch tick.
    function _seedEthPool(PoolKey memory key, int24 startTick, uint256 amount) internal {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        uint128 liquidity = DuelMath.liquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(startTick), amount
        );
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: startTick, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Full-range position holding `amount` of each token at a 1:1 price.
    function _seedCrossPool(PoolKey memory key, uint256 amount) internal {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = DuelMath.liquidityForAmounts(
            uint160(DuelMath.Q96),
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount,
            amount
        );
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Pays what the positions need of `token` and burns the rounding dust left in the factory.
    function _settleToken(address token) internal {
        Currency currency = Currency.wrap(token);
        uint256 owed = uint256(-poolManager.currencyDelta(address(this), currency));
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        DuelToken(token).burn(IERC20(token).balanceOf(address(this)));
    }

    /// @dev Creator's launch buy: exempt from the anti-snipe tax (the hook recognises the factory), capped.
    function _creatorBuy(PoolKey memory key, uint256 ethIn, address creator, uint256 supply) internal {
        if (ethIn == 0) return;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 bought = uint256(int256(delta.amount1()));
        if (bought > (supply * CREATOR_BUY_MAX_BPS) / BPS) revert CreatorBuyTooLarge();
        poolManager.settle{value: uint256(int256(-delta.amount0()))}();
        poolManager.take(key.currency1, creator, bought);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice Current configuration.
    function config() external view returns (Config memory) {
        return _config;
    }

    /// @notice The hash of the current configuration, which a launch commits to (CreateParams.config).
    function configHash() external view returns (bytes32) {
        return _hash(_config);
    }

    function _hash(Config memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    /// @notice Configuration waiting for its delay.
    function pendingConfig() external view returns (Config memory) {
        return _pendingConfig;
    }

    /// @inheritdoc IDuelFactory
    function treasury() external view returns (address) {
        return _config.treasury;
    }

    /// @notice Proposes a new configuration, applicable after `CONFIG_DELAY`.
    function proposeConfig(Config calldata config_) external onlyOwner {
        _validate(config_);
        _pendingConfig = config_;
        pendingConfigEta = block.timestamp + CONFIG_DELAY;
        emit ConfigProposed(config_, pendingConfigEta);
    }

    /// @notice Applies the pending configuration once its delay has passed. Callable by anyone.
    function applyConfig() external {
        uint256 eta = pendingConfigEta;
        if (eta == 0) revert NoPendingConfig();
        if (block.timestamp < eta) revert ConfigNotReady();
        _config = _pendingConfig;
        delete _pendingConfig;
        pendingConfigEta = 0;
        emit ConfigApplied(_config);
    }

    /// @notice Drops the pending configuration.
    function cancelConfig() external onlyOwner {
        delete _pendingConfig;
        pendingConfigEta = 0;
        emit ConfigCancelled();
    }

    /// @notice Offers the creator role of a pair to `newCreator`, who takes it with `acceptCreator`: the creator fees
    ///         not yet claimed go with it, and every claim after pays the new creator. The creator keeps the role until
    ///         then, and withdraws the offer by making it to the zero address.
    function transferCreator(uint256 pairId, address newCreator) external {
        if (msg.sender != hook.getPair(pairId).creator) revert NotCreator();
        pendingCreator[pairId] = newCreator;
        emit CreatorTransferStarted(pairId, msg.sender, newCreator);
    }

    /// @notice Takes the creator role of a pair, offered to the caller (transferCreator).
    function acceptCreator(uint256 pairId) external {
        if (msg.sender != pendingCreator[pairId]) revert NotPendingCreator();
        delete pendingCreator[pairId];
        hook.setCreator(pairId, msg.sender);
    }

    /// @notice Lowers the protocol's part of every pair's swap fee at once, launched or to come, down to nothing, or
    ///         raises it back, never above the share each pair's terms give the protocol: `rateBps` of that share, the
    ///         rest going to the pair's round pot (DuelHook.protocolRateBps). Immediate: traders pay the same fee
    ///         either way, and the creators the same share.
    function setProtocolRate(uint16 rateBps) external onlyOwner {
        hook.setProtocolRate(rateBps);
    }

    /// @notice Pauses or resumes pair creation by anyone but the owner, who launches either way. Existing pairs keep
    ///         trading. The factory is deployed paused: the owner opens the launches once its first pair is launched.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @dev A name or a ticker: one byte at least, `longest` at most.
    function _fits(string calldata text, uint256 longest) internal pure returns (bool) {
        return bytes(text).length != 0 && bytes(text).length <= longest;
    }

    /// @dev Hard bounds every configuration must respect.
    function _validate(Config memory c) internal pure {
        if (
            c.treasury == address(0) || c.launchFee > MAX_LAUNCH_FEE || c.startFdv < MIN_START_FDV
                || c.startFdv > MAX_START_FDV || c.crossShareBps < 200 || c.crossShareBps > 2000 || c.swapFeeBps < 25
                || c.swapFeeBps > 200 || c.switchFeeBps > 100 || c.protocolShareBps > 5000 || c.potShareBps > 5000
                || c.snipeWindow > 60 || uint256(c.swapFeeBps) + c.snipeStartBps >= BPS
        ) revert InvalidConfig();
    }
}
