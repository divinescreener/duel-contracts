// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelDeploy} from "../../script/DuelDeploy.sol";

/// @notice Shared fixture: a local PoolManager, the Duel contracts and helpers to create pairs and trade.
abstract contract DuelTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    /// @dev Sunday 20 September 2026, 12:00 UTC: eight hours before a round boundary.
    uint256 internal constant START_TIME = 1_789_905_600;
    /// @dev The launch fee the deploy script sets: every launch in the tests pays it.
    uint256 internal constant LAUNCH_FEE = 0.01 ether;

    IPoolManager internal manager;
    DuelHook internal hook;
    DuelFactory internal factory;
    DuelRouter internal router;
    DuelLens internal lens;
    PoolSwapTest internal swapRouter;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    struct PairInfo {
        uint256 id;
        DuelToken a;
        DuelToken d;
        PoolKey keyA;
        PoolKey keyD;
        PoolKey keyX;
    }

    function setUp() public virtual {
        vm.warp(START_TIME);
        manager = IPoolManager(address(new PoolManager(address(this))));
        address hookAddress = address(uint160(0x4444) << 144 | HOOK_FLAGS);
        factory = new DuelFactory(manager, DuelHook(hookAddress), owner, defaultConfig());
        deployCodeTo("DuelHook.sol:DuelHook", abi.encode(address(manager), address(factory)), hookAddress);
        hook = DuelHook(hookAddress);
        if (_opened()) {
            vm.prank(owner);
            factory.setPaused(false);
        }
        router = new DuelRouter(manager);
        lens = new DuelLens(hook);
        swapRouter = new PoolSwapTest(manager);

        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /// @dev The factory is born paused, for its owner's first pair. The tests trade on a launchpad its owner has opened,
    ///      but those that look at a deployment as it is born, which answer false.
    function _opened() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev The configuration the deploy script launches with: the tests check what goes live.
    function defaultConfig() internal view returns (DuelFactory.Config memory) {
        return DuelDeploy.defaultConfig(treasury);
    }

    /// @dev A launch's parameters, committed to the factory's configuration as it stands: built before a prank or an
    ///      expected revert, which the factory's read would otherwise take for the call they aim at.
    function createParams(uint256 buyA, uint256 buyD, bool supporter)
        internal
        view
        returns (DuelFactory.CreateParams memory)
    {
        return DuelFactory.CreateParams({
            nameA: "Cats",
            symbolA: "CATS",
            nameD: "Dogs",
            symbolD: "DOGS",
            metadataURI: "ipfs://duel-metadata",
            buyA: buyA,
            buyD: buyD,
            supporter: supporter,
            category: 5,
            config: factory.configHash()
        });
    }

    /// @dev Creates a pair as `creator` with optional launch buys.
    function _createPair(uint256 buyA, uint256 buyD, bool supporter) internal returns (PairInfo memory info) {
        DuelFactory.CreateParams memory params = createParams(buyA, buyD, supporter);
        vm.prank(creator);
        uint256 id = factory.createPair{value: LAUNCH_FEE + buyA + buyD}(params);
        info = _info(id);
    }

    function _info(uint256 id) internal view returns (PairInfo memory info) {
        DuelHook.Pair memory p = hook.getPair(id);
        info.id = id;
        info.a = DuelToken(p.tokenA);
        info.d = DuelToken(p.tokenD);
        (info.keyA, info.keyD, info.keyX) = hook.poolKeys(id);
    }

    /// @dev Creates pairs until one has the requested token ordering in its cross pool.
    function _createPairOriented(bool aIsCurrency0) internal returns (PairInfo memory info) {
        for (uint256 i = 0; i < 20; ++i) {
            info = _createPair(0, 0, false);
            if (hook.getPair(info.id).aIsCurrency0 == aIsCurrency0) return info;
        }
        revert("orientation not found");
    }

    /// @dev Exact-input or exact-output swap through v4-core's test router, as `user`.
    function _swap(address user, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta delta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swapTo(user, key, zeroForOne, amountSpecified, value, limit);
    }

    /// @dev A swap that stops at the price `sqrtPriceLimitX96`, filled or not.
    function _swapTo(
        address user,
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 value,
        uint160 sqrtPriceLimitX96
    ) internal returns (BalanceDelta delta) {
        _approve(user, key);
        vm.startPrank(user);
        delta = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Lets the test router pull `user`'s tokens for `key`; a no-op once approved, so it can run before an
    ///      `expectEmit` without consuming it.
    function _approve(address user, PoolKey memory key) internal {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        vm.startPrank(user);
        if (token0 != address(0) && IERC20(token0).allowance(user, address(swapRouter)) == 0) {
            IERC20(token0).approve(address(swapRouter), type(uint256).max);
        }
        if (IERC20(token1).allowance(user, address(swapRouter)) == 0) {
            IERC20(token1).approve(address(swapRouter), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @dev Buys a side with an exact amount of ETH.
    function _buy(address user, PoolKey memory ethKey, uint256 ethIn) internal returns (uint256 bought) {
        BalanceDelta delta = _swap(user, ethKey, true, -int256(ethIn), ethIn);
        bought = uint256(int256(delta.amount1()));
    }

    /// @dev Sells an exact amount of a side's tokens for ETH.
    function _sell(address user, PoolKey memory ethKey, uint256 tokensIn) internal returns (uint256 ethOut) {
        BalanceDelta delta = _swap(user, ethKey, false, -int256(tokensIn), 0);
        ethOut = uint256(int256(delta.amount0()));
    }

    /// @dev Switches an exact amount of `from` into the other side through the cross pool.
    function _switch(address user, PairInfo memory info, address from, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        bool zeroForOne = Currency.unwrap(info.keyX.currency0) == from;
        BalanceDelta delta = _swap(user, info.keyX, zeroForOne, -int256(amountIn), 0);
        out = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    /// @dev The revert data the PoolManager produces when a hook callback reverts with `reason`.
    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Warps to the end of the pair's current round.
    function _warpToRoundEnd(uint256 pairId) internal {
        vm.warp(hook.getPair(pairId).roundEnd);
    }

    // ------------------------------------------------------------------
    // Rounds
    // ------------------------------------------------------------------

    bytes32 internal constant ROUND_SETTLED = keccak256("RoundSettled(uint256,uint32,int24,address,uint256,uint256)");
    bytes32 internal constant ARBITRAGE_CAPTURED = keccak256("ArbitrageCaptured(uint256,uint256)");

    /// @dev A settlement as the hook reported it, with the arbitrage that followed the buyback.
    struct Settlement {
        bool found;
        uint32 round;
        int24 averageTick;
        address winner;
        uint256 spent;
        uint256 burned;
        uint256 captured; // arbitrage profit after the buyback
    }

    function _settlementIn(Vm.Log[] memory logs) internal view returns (Settlement memory s) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == ROUND_SETTLED) {
                s.found = true;
                s.round = uint32(uint256(logs[i].topics[2]));
                (s.averageTick, s.winner, s.spent, s.burned) =
                    abi.decode(logs[i].data, (int24, address, uint256, uint256));
            } else if (logs[i].topics[0] == ARBITRAGE_CAPTURED) {
                s.captured += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    /// @dev How many of `logs` the hook emitted with `topic`.
    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) ++n;
        }
    }

    function _settleNow(uint256 pairId) internal returns (Settlement memory) {
        vm.recordLogs();
        hook.settle(pairId);
        return _settlementIn(vm.getRecordedLogs());
    }

    /// @dev A pair with both sides bought, `aLeads` deciding which side received more ETH.
    function _pairWithLeader(bool aLeads, bool aIsCurrency0) internal returns (PairInfo memory info) {
        info = _createPairOriented(aIsCurrency0);
        vm.warp(block.timestamp + 10);
        _buy(alice, aLeads ? info.keyA : info.keyD, 1 ether);
        _buy(bob, aLeads ? info.keyD : info.keyA, 0.3 ether);
    }
}
