// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {DuelToken} from "./DuelToken.sol";
import {DuelMath} from "./libraries/DuelMath.sol";
import {IDuelFactory} from "./interfaces/IDuelFactory.sol";
import {DuelVersion} from "./libraries/DuelVersion.sol";

/// @title DuelHook
/// @notice Uniswap V4 hook shared by the three pools of every Duel pair: ETH/A, ETH/D and the A/D cross pool.
/// @dev What the hook does, per swap:
///      - takes the swap fee in ETH (and the decaying anti-snipe tax on early buys), held as ERC-6909 claims, and
///        shares it between the creator, the round pot and the protocol, whose part its rate can lower for every pair
///        at once (`protocolRateBps`), the rest going to the pot;
///      - burns the switch fee paid in the token a trader leaves when swapping through the cross pool;
///      - accrues the ratio of the two ETH prices, settles finished rounds and buys back the winner near its
///        reference price (its 30-minute EMA, or its price when that is lower); the cross pool's price never enters
///        the gauge or round oracle;
///      - realigns the three pools with a zero-fee internal arbitrage and keeps the profit for the round pot.
///      A fee taken before a swap counts the whole amount asked: such a swap must fill it all (`PartialFill`).
///      Liquidity can only be added by the factory and can never be removed.
contract DuelHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @notice Fee terms frozen for a pair when it is created.
    struct FeeConfig {
        uint16 swapFeeBps; // fee on every ETH swap, taken in ETH
        uint16 switchFeeBps; // fee on cross pool swaps, burned in the token sold
        uint16 protocolShareBps; // protocol share of the swap fee
        uint16 potShareBps; // round pot share of the swap fee (the creator gets the rest)
        uint16 snipeStartBps; // anti-snipe tax at launch
        uint16 snipeWindow; // seconds until the anti-snipe tax reaches zero
    }

    /// @notice State of a pair.
    struct Pair {
        address tokenA;
        address tokenD;
        address creator;
        FeeConfig fees;
        int24 startTick; // launch tick of both ETH pools, upper bound of their single-sided positions
        bool aIsCurrency0; // token ordering in the cross pool
        bool supporter; // the creator gave its fee share to the round pots
        uint8 category; // what the duel is about, as the app numbers its categories: any number, 0 for none
        bool roundTraded; // an ETH swap, or a trader's realignment changing ETH ticks, happened in this round
        uint40 launchTime;
        uint40 lastAccrual;
        uint40 roundStart;
        uint40 roundEnd;
        uint32 roundIndex;
        int64 tickCumulative; // ETH price-ratio tick, in cross currency order, integrated over time
        int64 roundStartCumulative;
        int40 emaA; // reference of A's buybacks, in 1/65536 of a tick: the 30-minute EMA of the ETH/A tick, or the
        int40 emaD; // tick itself when its price is lower (_reference)
        uint128 pot; // ETH waiting for the next round settlement
        uint128 creatorFees; // ETH claimable by the creator
        uint128 volume; // ETH traded against both ETH pools since launch
        uint128 buybacks; // ETH the pots spent buying back winners since launch
    }

    error NotPoolManager();
    error NotFactory();
    error NotSelf();
    error UnknownPool();
    error UnknownPair();
    error LiquidityLocked();
    error DonationsDisabled();
    error HookNotImplemented();
    error PartialFill();
    error NothingToClaim();
    error ArbitrageStarved();
    error InvalidRate();
    error NotCreator();

    event PairRegistered(
        uint256 indexed pairId, address tokenA, address tokenD, address indexed creator, uint8 category
    );
    event FeeTaken(uint256 indexed pairId, uint256 fee, uint256 snipeTax);
    event SwitchFeeBurned(uint256 indexed pairId, address indexed token, uint256 amount);
    event ArbitrageCaptured(uint256 indexed pairId, uint256 profit);
    event RoundSettled(
        uint256 indexed pairId,
        uint32 indexed roundIndex,
        int24 averageTick,
        address winner,
        uint256 ethSpent,
        uint256 tokensBurned
    );
    event CreatorFeesClaimed(uint256 indexed pairId, address indexed to, uint256 amount);
    event CreatorChanged(uint256 indexed pairId, address indexed from, address indexed to);
    event CreatorFeesGivenUp(uint256 indexed pairId, address indexed creator);
    event ProtocolFeesClaimed(address indexed to, uint256 amount);
    event ProtocolRateSet(uint16 rateBps);

    uint256 internal constant BPS = 10_000;
    uint256 internal constant ETH_ID = 0; // ERC-6909 id of native ETH in the PoolManager
    uint256 internal constant KIND_ETH = 1; // either ETH pool: the token tells which side
    uint256 internal constant KIND_CROSS = 3;
    uint8 internal constant ACTION_SETTLE = 0;
    uint8 internal constant ACTION_PAY = 1;

    /// @notice Version of the launchpad this contract is part of (DuelVersion).
    uint256 public constant VERSION = DuelVersion.NUMBER;
    /// @notice Code name of the launchpad's version.
    string public constant CODENAME = DuelVersion.CODENAME;
    /// @notice Tick spacing of the ETH pools.
    int24 public constant ETH_TICK_SPACING = 200;
    /// @notice Tick spacing of the cross pool.
    int24 public constant CROSS_TICK_SPACING = 60;
    /// @notice Rounds last four hours and all end on the same boundaries, every four hours from midnight UTC:
    ///         00:00, 04:00, 08:00, 12:00, 16:00 and 20:00 UTC.
    uint256 public constant ROUND_LENGTH = 4 hours;
    /// @notice Minimum length of the first round of a pair.
    uint256 public constant MIN_FIRST_ROUND = 4 hours;
    /// @notice Maximum price move of a buyback from the reference price, in ticks: 1.0001^953 is about 1.10, so a
    ///         buyback never pays more than about 10% above the winner's reference price, its 30-minute EMA or its
    ///         price when that is lower (DuelMath.emaDecayX128, `_reference`).
    int24 public constant BUYBACK_MAX_IMPACT_TICKS = 953;
    /// @notice Minimum mispricing, in basis points, before the internal arbitrage runs.
    uint256 public constant ARB_THRESHOLD_BPS = 10;

    /// @notice Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The only address allowed to register pairs, create pools and add liquidity.
    address public immutable factory;

    /// @notice Number of registered pairs; pair ids start at 1.
    uint256 public pairCount;
    /// @notice ETH owed to the protocol treasury.
    uint256 public protocolFees;
    /// @notice The part of every pair's protocol fee share the protocol takes, in basis points of that share: all of it
    ///         (10_000), as the pair's terms set it, or less, the rest going to the pair's round pot. The factory's owner
    ///         sets it at once for every pair, launched or to come (DuelFactory.setProtocolRate), never above 10_000: the
    ///         protocol never takes more than a pair's terms give it, and the creator's share never changes.
    uint16 public protocolRateBps = uint16(BPS);

    mapping(uint256 pairId => Pair) internal _pairs;
    mapping(PoolId poolId => uint256 ref) internal _poolRefs; // (pairId << 2) | kind

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager Uniswap V4 PoolManager.
    /// @param _factory DuelFactory allowed to register pairs.
    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ------------------------------------------------------------------
    // Pair registration
    // ------------------------------------------------------------------

    /// @notice Registers a new pair; called by the factory before it initializes the three pools.
    /// @return pairId Id of the new pair.
    function registerPair(
        address tokenA,
        address tokenD,
        address creator,
        bool supporter,
        uint8 category,
        FeeConfig calldata fees,
        int24 startTick
    ) external returns (uint256 pairId) {
        if (msg.sender != factory) revert NotFactory();
        pairId = ++pairCount;

        Pair storage p = _pairs[pairId];
        p.tokenA = tokenA;
        p.tokenD = tokenD;
        p.creator = creator;
        p.fees = fees;
        p.startTick = startTick;
        p.emaA = int40(int256(startTick) << DuelMath.EMA_FRACTION_BITS);
        p.emaD = p.emaA;
        p.aIsCurrency0 = tokenA < tokenD;
        p.supporter = supporter;
        p.category = category;
        p.launchTime = uint40(block.timestamp);
        p.lastAccrual = uint40(block.timestamp);
        p.roundStart = uint40(block.timestamp);
        p.roundEnd = uint40(firstRoundEnd(block.timestamp));

        _poolRefs[_ethKey(tokenA).toId()] = (pairId << 2) | KIND_ETH;
        _poolRefs[_ethKey(tokenD).toId()] = (pairId << 2) | KIND_ETH;
        _poolRefs[_crossKey(p).toId()] = (pairId << 2) | KIND_CROSS;

        emit PairRegistered(pairId, tokenA, tokenD, creator, category);
    }

    /// @notice End of the first round of a pair launched at `launchTime`: the first round boundary that leaves at
    ///         least `MIN_FIRST_ROUND` of trading.
    function firstRoundEnd(uint256 launchTime) public pure returns (uint256 end) {
        end = (launchTime / ROUND_LENGTH + 1) * ROUND_LENGTH;
        if (end - launchTime < MIN_FIRST_ROUND) end += ROUND_LENGTH;
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    /// @notice Hook permissions; the hook address must carry exactly these flags (0x2AEC).
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (_poolRefs[key.toId()] == 0) revert UnknownPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert LiquidityLocked();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert DonationsDisabled();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 pairId, uint256 kind) = _lookup(key);
        Pair storage p = _pairs[pairId];
        _sync(p, pairId);
        if (kind != KIND_CROSS) p.roundTraded = true;

        bool exactInput = params.amountSpecified < 0;
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 taken;
        if (kind == KIND_CROSS) {
            // exact input: the specified amount is the token the trader leaves
            if (exactInput) {
                taken = _takeSwitchFee(p, pairId, params.zeroForOne ? key.currency0 : key.currency1, amount, true);
            }
        } else if (params.zeroForOne == exactInput) {
            // ETH (currency0) is the specified amount: paid in on an exact-input buy, paid out on an exact-output sell
            taken = _takeEthFee(p, pairId, sender, params.zeroForOne, amount, exactInput);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(taken.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        (uint256 pairId, uint256 kind) = _lookup(key);
        Pair storage p = _pairs[pairId];

        bool exactInput = params.amountSpecified < 0;
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 taken;
        if (kind == KIND_CROSS) {
            if (exactInput) {
                // the switch fee was taken before the swap, on the whole amount
                _checkFill(params, delta, amount - _switchCut(p, amount, true));
            } else {
                // exact output: the token the trader leaves is the unspecified side
                (Currency input, int128 inputDelta) =
                    params.zeroForOne ? (key.currency0, delta.amount0()) : (key.currency1, delta.amount1());
                taken = _takeSwitchFee(p, pairId, input, uint256(int256(-inputDelta)), false);
            }
        } else if (params.zeroForOne == exactInput) {
            // the ETH fee was taken before the swap, on the whole amount: the same cut, worked out again
            (uint256 cut,,) = _ethCut(p, sender, params.zeroForOne, amount, exactInput);
            _checkFill(params, delta, exactInput ? amount - cut : amount + cut);
        } else {
            // ETH (currency0) is the unspecified amount: paid in on an exact-output buy, paid out on an exact-input sell
            int128 eth = delta.amount0();
            taken = _takeEthFee(p, pairId, sender, params.zeroForOne, uint256(int256(eth < 0 ? -eth : eth)), exactInput);
        }

        // A cross-only swap must not activate an otherwise quiet round. It counts only if its realignment changes
        // an ETH price tick. Buyback realignments in _sync do not activate the new round.
        bool checkActivity = kind == KIND_CROSS && !p.roundTraded;
        int24 tickABefore;
        int24 tickDBefore;
        if (checkActivity) (tickABefore, tickDBefore) = _ethTicks(p);
        _realign(pairId);
        if (checkActivity) {
            (int24 tickAAfter, int24 tickDAfter) = _ethTicks(p);
            p.roundTraded = tickAAfter != tickABefore || tickDAfter != tickDBefore;
        }
        return (IHooks.afterSwap.selector, taken.toInt128());
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------
    // Internal arbitrage
    // ------------------------------------------------------------------

    /// @notice Realigns the cross pool with the two ETH pools through a zero-fee triangle trade and keeps the ETH
    ///         profit in the round pot.
    /// @dev Only callable by the hook itself, from `afterSwap` and after a buyback, inside a `try` (`_realign`): a
    ///      failure of its own never blocks a swap, but a swap that leaves it too little gas reverts. Swaps initiated
    ///      by the hook skip its own callbacks, so they pay no fee and cannot recurse. The optimal size comes from the
    ///      closed form of three constant-liquidity ranges.
    ///      A cycle ends by selling a token into its ETH pool, so that pool must hold ETH, and the cycle is sized to
    ///      sell no more than that ETH pays for. Tokens can always be bought: an ETH pool without ETH trades from its
    ///      launch price, and both ETH pools hold the same locked position. The cross pool thus follows the ETH
    ///      prices from the first buy of either side.
    /// @return profit ETH captured for the pot.
    function arbitrage(uint256 pairId) external returns (uint256 profit) {
        if (msg.sender != address(this)) revert NotSelf();
        Pair storage p = _pairs[pairId];
        PoolKey memory keyA = _ethKey(p.tokenA);
        PoolKey memory keyD = _ethKey(p.tokenD);
        PoolKey memory keyX = _crossKey(p);

        (uint160 sqrtPriceA, int24 tickA,,) = poolManager.getSlot0(keyA.toId());
        (uint160 sqrtPriceD, int24 tickD,,) = poolManager.getSlot0(keyD.toId());
        bool liveA = tickA < p.startTick;
        bool liveD = tickD < p.startTick;
        if (!liveA && !liveD) return 0;
        uint128 liquidity = poolManager.getLiquidity((liveA ? keyA : keyD).toId());
        uint160 launchPrice = TickMath.getSqrtPriceAtTick(p.startTick);

        (uint160 sqrtPriceX,,,) = poolManager.getSlot0(keyX.toId());
        (uint256 ethA, uint256 tokA) = DuelMath.virtualReserves(liquidity, liveA ? sqrtPriceA : launchPrice);
        (uint256 ethD, uint256 tokD) = DuelMath.virtualReserves(liquidity, liveD ? sqrtPriceD : launchPrice);
        (uint256 cross0, uint256 cross1) = DuelMath.virtualReserves(poolManager.getLiquidity(keyX.toId()), sqrtPriceX);
        (uint256 crossA, uint256 crossD) = p.aIsCurrency0 ? (cross0, cross1) : (cross1, cross0);

        // cycle through D first: ETH -> D -> A -> ETH, which sells A
        uint256 input =
            liveA ? DuelMath.optimalCycleInput(ethD, tokD, crossD, crossA, tokA, ethA, ARB_THRESHOLD_BPS) : 0;
        if (input != 0) {
            input = DuelMath.capCycleInput(
                input, ethD, tokD, crossD, crossA, _sellable(liquidity, sqrtPriceA, launchPrice)
            );
            profit = _runCycle(keyD, keyX, keyA, !p.aIsCurrency0, input, p.startTick);
        } else {
            // cycle through A first: ETH -> A -> D -> ETH, which sells D
            input = liveD ? DuelMath.optimalCycleInput(ethA, tokA, crossA, crossD, tokD, ethD, ARB_THRESHOLD_BPS) : 0;
            if (input == 0) return 0;
            input = DuelMath.capCycleInput(
                input, ethA, tokA, crossA, crossD, _sellable(liquidity, sqrtPriceD, launchPrice)
            );
            profit = _runCycle(keyA, keyX, keyD, p.aIsCurrency0, input, p.startTick);
        }

        poolManager.mint(address(this), ETH_ID, profit);
        p.pot += profit.toUint128();
        emit ArbitrageCaptured(pairId, profit);
    }

    /// @dev Runs the arbitrage; a failure of its own never blocks the swap. A caller holding gas back must not be able
    ///      to choose that it fails: out of gas, the arbitrage leaves less than 1/32 of the gas there was before it
    ///      (EIP-150 keeps 1/64 at each call), and the swap reverts.
    function _realign(uint256 pairId) internal {
        uint256 gasBefore = gasleft();
        try this.arbitrage(pairId) {}
        catch {
            if (gasleft() < gasBefore / 32) revert ArbitrageStarved();
        }
    }

    /// @dev Tokens an ETH pool can buy back before it runs out of ETH at its launch price, less 0.1% for rounding.
    function _sellable(uint128 liquidity, uint160 sqrtPrice, uint160 launchPrice) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(sqrtPrice, launchPrice, liquidity, false) * 999 / 1000;
    }

    /// @dev Buys a token with ETH, swaps it for the other token in the cross pool and sells that one for ETH.
    function _runCycle(
        PoolKey memory buyKey,
        PoolKey memory crossKey,
        PoolKey memory sellKey,
        bool crossZeroForOne,
        uint256 ethIn,
        int24 startTick
    ) internal returns (uint256 profit) {
        uint256 bought = _swapExactIn(buyKey, true, ethIn, TickMath.MIN_SQRT_PRICE + 1);
        uint256 switched = _swapExactIn(
            crossKey,
            crossZeroForOne,
            bought,
            crossZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 ethOut = _swapExactIn(sellKey, false, switched, TickMath.getSqrtPriceAtTick(startTick));
        profit = ethOut - ethIn; // reverts, and the arbitrage is skipped, if rounding ate the edge
    }

    /// @dev Exact-input swap by the hook; reverts unless the whole input is consumed.
    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 amountOut)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -amountIn.toInt256(), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (uint256(int256(-inDelta)) != amountIn) revert PartialFill();
        amountOut = uint256(int256(outDelta));
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    /// @dev A fee taken before the swap counted the whole amount asked: the pool must have swapped `fill`, all of it,
    ///      or the trader would pay the fee on what did not trade (a price limit stops a swap short).
    function _checkFill(IPoolManager.SwapParams calldata params, BalanceDelta delta, uint256 fill) internal pure {
        int128 specified = (params.amountSpecified < 0) == params.zeroForOne ? delta.amount0() : delta.amount1();
        if (uint256(int256(specified < 0 ? -specified : specified)) != fill) revert PartialFill();
    }

    /// @dev The hook's cut of an ETH swap (the swap fee, and the anti-snipe tax on buys) at its `rateBps`, and the ETH
    ///      the swap counts in the volume. On an exact-input swap `ethAmount` includes the cut; on an exact-output swap
    ///      it does not, and the cut is grossed up so that both kinds of swap pay the same rates (an exact-output buy
    ///      must not halve the anti-snipe tax).
    function _ethCut(Pair storage p, address sender, bool isBuy, uint256 ethAmount, bool exactInput)
        internal
        view
        returns (uint256 total, uint256 gross, uint256 rateBps)
    {
        rateBps = p.fees.swapFeeBps + (isBuy && sender != factory ? _snipeTaxBps(p) : 0);
        gross = exactInput ? ethAmount : FullMath.mulDivRoundingUp(ethAmount, BPS, BPS - rateBps);
        total = exactInput ? (gross * rateBps) / BPS : gross - ethAmount;
    }

    /// @dev Takes the hook's cut of an ETH swap (`_ethCut`) as ERC-6909 claims.
    function _takeEthFee(Pair storage p, uint256 pairId, address sender, bool isBuy, uint256 ethAmount, bool exactInput)
        internal
        returns (uint256 total)
    {
        uint256 gross;
        uint256 rateBps;
        (total, gross, rateBps) = _ethCut(p, sender, isBuy, ethAmount, exactInput);
        p.volume += gross.toUint128();
        if (total == 0) return 0;
        // split between the fee and the tax at their rates: a sell has no tax, however the cut was rounded
        uint256 fee = (total * p.fees.swapFeeBps) / rateBps;
        uint256 tax = total - fee;

        poolManager.mint(address(this), ETH_ID, total);
        // the protocol's share as the pair's terms set it, of which it takes its rate: the rest goes to the pot
        uint256 protocolShare = (fee * p.fees.protocolShareBps) / BPS;
        uint256 protocolCut = (protocolShare * protocolRateBps) / BPS;
        uint256 potCut = (fee * p.fees.potShareBps) / BPS;
        uint256 creatorCut = fee - protocolShare - potCut;
        potCut += protocolShare - protocolCut;
        if (p.supporter) {
            potCut += creatorCut;
        } else {
            p.creatorFees += creatorCut.toUint128();
        }
        protocolFees += protocolCut;
        p.pot += (potCut + tax).toUint128();
        emit FeeTaken(pairId, fee, tax);
    }

    /// @dev The switch fee on `amount` of the token a trader leaves: included in it on an exact-input swap, grossed up
    ///      on an exact-output one, like the ETH fee.
    function _switchCut(Pair storage p, uint256 amount, bool exactInput) internal view returns (uint256) {
        uint256 bps = p.fees.switchFeeBps;
        return exactInput ? (amount * bps) / BPS : FullMath.mulDivRoundingUp(amount, BPS, BPS - bps) - amount;
    }

    /// @dev Takes the switch fee (`_switchCut`) in the token the trader leaves and burns it.
    function _takeSwitchFee(Pair storage p, uint256 pairId, Currency token, uint256 amount, bool exactInput)
        internal
        returns (uint256 fee)
    {
        fee = _switchCut(p, amount, exactInput);
        if (fee == 0) return 0;
        poolManager.take(token, address(this), fee);
        DuelToken(Currency.unwrap(token)).burn(fee);
        emit SwitchFeeBurned(pairId, Currency.unwrap(token), fee);
    }

    function _snipeTaxBps(Pair storage p) internal view returns (uint256) {
        return DuelMath.snipeTaxBps(p.fees.snipeStartBps, p.fees.snipeWindow, block.timestamp - p.launchTime);
    }

    // ------------------------------------------------------------------
    // Oracle and rounds
    // ------------------------------------------------------------------

    /// @dev Accrues the oracle up to now, settling the current round first if it has ended.
    function _sync(Pair storage p, uint256 pairId) internal {
        uint256 end = p.roundEnd;
        if (block.timestamp < end) return _accrue(p, block.timestamp);

        // the round's result, from the ticks that held until its end
        _accrue(p, end);
        int256 averageTick =
            (int256(p.tickCumulative) - int256(p.roundStartCumulative)) / int256(uint256(end - p.roundStart));
        address winner;
        if (p.roundTraded && averageTick != 0) {
            // a positive tick means currency0 is worth more than currency1
            winner = (averageTick > 0) == p.aIsCurrency0 ? p.tokenA : p.tokenD;
        }
        uint32 settled = p.roundIndex;

        // the current round, skipping those that passed without any swap; the oracle catches up before the buyback
        // moves any price
        uint256 newStart = end + ((block.timestamp - end) / ROUND_LENGTH) * ROUND_LENGTH;
        _accrue(p, newStart);
        p.roundIndex += uint32((newStart - end) / ROUND_LENGTH + 1);
        p.roundStart = uint40(newStart);
        p.roundEnd = uint40(newStart + ROUND_LENGTH);
        p.roundStartCumulative = p.tickCumulative;
        p.roundTraded = false;
        _accrue(p, block.timestamp);

        uint256 spent;
        uint256 burned;
        if (winner != address(0)) (spent, burned) = _buyback(p, winner);
        emit RoundSettled(pairId, settled, int24(averageTick), winner, spent, burned);
        // the buyback moved the winner's ETH price: realign the cross pool now, not in the next trader's favour
        if (spent != 0) _realign(pairId);
    }

    /// @dev Integrates the ETH price-ratio tick and updates the ETH pools' references up to `to`, from
    ///      the prices that held since the last accrual (read before the swap that accrues moves them).
    function _accrue(Pair storage p, uint256 to) internal {
        uint256 last = p.lastAccrual;
        if (to <= last) return;
        uint256 elapsed = to - last;
        (int24 tickA, int24 tickD) = _ethTicks(p);
        int24 ratio = DuelMath.ethRatioTick(tickA, tickD, p.aIsCurrency0);
        p.tickCumulative += int64(ratio) * int64(uint64(elapsed));
        p.emaA = int40(_reference(p.emaA, tickA, elapsed));
        p.emaD = int40(_reference(p.emaD, tickD, elapsed));
        p.lastAccrual = uint40(to);
    }

    /// @dev The buyback's reference: the EMA of a pool's tick while its price rises, the price itself as soon as it
    ///      falls under it (a higher tick is a lower price). The price never sits under its reference, so a buyback
    ///      never climbs more than its band from the price it finds: tokens sold a moment before the close are not
    ///      bought back near the average they left.
    function _reference(int256 previous, int24 tick, uint256 elapsed) internal pure returns (int256 ema) {
        ema = DuelMath.emaTick(previous, tick, elapsed);
        int256 held = int256(tick) << DuelMath.EMA_FRACTION_BITS;
        if (ema < held) ema = held;
    }

    /// @dev The ETH pools' ticks as they trade: one sold out of ETH sits wherever the last sell's price limit left it,
    ///      but trades from its launch price.
    function _ethTicks(Pair storage p) internal view returns (int24 tickA, int24 tickD) {
        (, tickA,,) = poolManager.getSlot0(_ethKey(p.tokenA).toId());
        (, tickD,,) = poolManager.getSlot0(_ethKey(p.tokenD).toId());
        int24 start = p.startTick;
        if (tickA > start) tickA = start;
        if (tickD > start) tickD = start;
    }

    /// @dev Spends the pot on the winner within `BUYBACK_MAX_IMPACT_TICKS` of its reference and burns what it buys.
    function _buyback(Pair storage p, address winner) internal returns (uint256 spent, uint256 burned) {
        uint256 budget = p.pot;
        if (budget == 0) return (0, 0);
        PoolKey memory key = _ethKey(winner);
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 limitTick = DuelMath.emaToTick(winner == p.tokenA ? p.emaA : p.emaD) - BUYBACK_MAX_IMPACT_TICKS;
        // the price already moved past the band around its average: keep the pot for the next round
        if (tick <= limitTick) return (0, 0);

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -budget.toInt256(),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            ""
        );
        spent = uint256(int256(-delta.amount0()));
        burned = uint256(int256(delta.amount1()));
        poolManager.burn(address(this), ETH_ID, spent);
        poolManager.take(key.currency1, address(this), burned);
        DuelToken(winner).burn(burned);
        p.pot = uint128(budget - spent);
        p.buybacks += uint128(spent);
    }

    // ------------------------------------------------------------------
    // Settlement and claims
    // ------------------------------------------------------------------

    /// @notice Settles a pair whose round ended without any swap since.
    function settle(uint256 pairId) external {
        if (pairId == 0 || pairId > pairCount) revert UnknownPair();
        poolManager.unlock(abi.encode(ACTION_SETTLE, abi.encode(pairId)));
    }

    /// @notice Pays the creator of a pair its accumulated fees.
    function claimCreatorFees(uint256 pairId) external returns (uint256 amount) {
        Pair storage p = _pairs[pairId];
        amount = p.creatorFees;
        if (amount == 0) revert NothingToClaim();
        p.creatorFees = 0;
        emit CreatorFeesClaimed(pairId, p.creator, amount);
        poolManager.unlock(abi.encode(ACTION_PAY, abi.encode(p.creator, amount)));
    }

    /// @notice Hands a pair's creator role to `creator`, with the creator fees not yet claimed and those to come. Only
    ///         the factory calls it, once the new creator accepted the role (DuelFactory.acceptCreator).
    function setCreator(uint256 pairId, address creator) external {
        if (msg.sender != factory) revert NotFactory();
        Pair storage p = _pairs[pairId];
        emit CreatorChanged(pairId, p.creator, creator);
        p.creator = creator;
    }

    /// @notice Gives a pair's creator share of every fee to come to its round pots, for good: the pair becomes a
    ///         supporter pair, as one launched so, and nothing turns it back. Only its creator calls it. The creator
    ///         keeps its role, and the creator fees taken until then, which it claims as before.
    function giveUpCreatorFees(uint256 pairId) external {
        Pair storage p = _pairs[pairId];
        if (msg.sender != p.creator) revert NotCreator();
        p.supporter = true;
        emit CreatorFeesGivenUp(pairId, msg.sender);
    }

    /// @notice Sets the part of every pair's protocol fee share the protocol takes (`protocolRateBps`), at once. Only the
    ///         factory calls it, for its owner (DuelFactory.setProtocolRate).
    function setProtocolRate(uint16 rateBps) external {
        if (msg.sender != factory) revert NotFactory();
        if (rateBps > BPS) revert InvalidRate();
        protocolRateBps = rateBps;
        emit ProtocolRateSet(rateBps);
    }

    /// @notice Pays the protocol treasury its accumulated fees.
    function claimProtocolFees() external returns (uint256 amount) {
        amount = protocolFees;
        if (amount == 0) revert NothingToClaim();
        protocolFees = 0;
        address to = IDuelFactory(factory).treasury();
        emit ProtocolFeesClaimed(to, amount);
        poolManager.unlock(abi.encode(ACTION_PAY, abi.encode(to, amount)));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_SETTLE) {
            uint256 pairId = abi.decode(payload, (uint256));
            _sync(_pairs[pairId], pairId);
        } else {
            (address to, uint256 amount) = abi.decode(payload, (address, uint256));
            poolManager.burn(address(this), ETH_ID, amount);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full state of a pair.
    function getPair(uint256 pairId) external view returns (Pair memory) {
        return _pairs[pairId];
    }

    /// @notice Pool keys of a pair: ETH/A, ETH/D and the A/D cross pool.
    function poolKeys(uint256 pairId)
        external
        view
        returns (PoolKey memory keyA, PoolKey memory keyD, PoolKey memory keyX)
    {
        Pair storage p = _pairs[pairId];
        return (_ethKey(p.tokenA), _ethKey(p.tokenD), _crossKey(p));
    }

    /// @notice Share of side A in the pair, in basis points, from the ratio of the two ETH price ticks.
    function gaugeBps(uint256 pairId) external view returns (uint256) {
        Pair storage p = _pairs[pairId];
        (int24 tickA, int24 tickD) = _ethTicks(p);
        uint256 share0 = DuelMath.share0BpsAtTick(DuelMath.ethRatioTick(tickA, tickD, p.aIsCurrency0));
        return p.aIsCurrency0 ? share0 : BPS - share0;
    }

    /// @notice Anti-snipe tax currently applied to buys of a pair, in basis points.
    function snipeTaxBps(uint256 pairId) external view returns (uint256) {
        return _snipeTaxBps(_pairs[pairId]);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _lookup(PoolKey calldata key) internal view returns (uint256 pairId, uint256 kind) {
        uint256 ref = _poolRefs[key.toId()];
        return (ref >> 2, ref & 3);
    }

    function _ethKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: ETH_TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function _crossKey(Pair storage p) internal view returns (PoolKey memory) {
        (address token0, address token1) = p.aIsCurrency0 ? (p.tokenA, p.tokenD) : (p.tokenD, p.tokenA);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: CROSS_TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }
}
