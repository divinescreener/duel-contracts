// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice Traders trade two duels at random while a searcher looks for a round trip that pays: in one call, a buy and
///         its sale, a switch through the A/D pool and back, a switch through ETH and back, the triangle (one side
///         bought, switched whole into the other, sold whole), in any duel, at any size, at any moment (a round's
///         close included, when its own trade settles the round). Settlements are checked against the buyback's band,
///         and a trader leaving a side whole through the Duel router against what its pool can still pay.
contract SearcherHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    DuelHook internal immutable hook;
    DuelRouter internal immutable router;
    PoolSwapTest internal immutable swapRouter;
    uint256[] public pairIds;
    address[] internal traders;
    address public immutable searcher = makeAddr("searcher");
    uint256 public immutable searcherStart;

    uint256 public tradesDone;
    uint256 public roundTripsDone;
    uint256 public trianglesDone;
    uint256 public settlementsDone;
    uint256 public buybacksChecked;
    /// @notice Buybacks that left the winner's price past its band.
    uint256 public bandBreaks;
    uint256 public exitsDone;
    /// @notice Whole exits that made every pass the router may make.
    uint256 public exitsAtTheBound;
    /// @notice Whole exits whose router stopped while the pool could still pay: tokens left, passes to spare, and the
    ///         pool's price not at the swaps' limit.
    uint256 public exitsStoppedEarly;
    /// @notice Whole exits that left more than dust (a thousandth and a token) with a pool not sold out.
    uint256 public exitsShort;

    constructor(
        IPoolManager _manager,
        DuelHook _hook,
        DuelRouter _router,
        PoolSwapTest _swapRouter,
        uint256[] memory ids
    ) {
        manager = _manager;
        hook = _hook;
        router = _router;
        swapRouter = _swapRouter;
        pairIds = ids;
        for (uint256 i = 0; i < 3; ++i) {
            address trader = makeAddr(string.concat("trader", vm.toString(i)));
            vm.deal(trader, 1_000_000 ether);
            traders.push(trader);
        }
        vm.deal(searcher, 1_000_000 ether);
        searcherStart = searcher.balance;
    }

    function _pick(uint256 seed) internal view returns (uint256 pairId, address trader, PoolKey[3] memory keys) {
        pairId = pairIds[seed % pairIds.length];
        trader = traders[(seed / 7) % traders.length];
        (keys[0], keys[1], keys[2]) = hook.poolKeys(pairId);
    }

    function _approveAll(address user, PoolKey memory key) internal {
        vm.startPrank(user);
        for (uint256 i = 0; i < 2; ++i) {
            address token = Currency.unwrap(i == 0 ? key.currency0 : key.currency1);
            if (token != address(0)) {
                IERC20(token).approve(address(swapRouter), type(uint256).max);
                IERC20(token).approve(address(router), type(uint256).max);
            }
        }
        vm.stopPrank();
    }

    /// @dev A swap as `user` through v4's test router; the delta, or nothing when it reverted.
    function _swap(address user, PoolKey memory key, bool zeroForOne, int256 amount, uint256 value)
        internal
        returns (bool ok, BalanceDelta delta)
    {
        _approveAll(user, key);
        vm.prank(user);
        try swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta d
        ) {
            return (true, d);
        } catch {
            return (false, delta);
        }
    }

    // ------------------------------------------------------------------
    // Traders
    // ------------------------------------------------------------------

    function buy(uint256 seed, uint256 eth, bool exactOutput) external {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        eth = bound(eth, 1000, 20 ether);
        bool ok;
        if (exactOutput) {
            (ok,) =
                _swap(trader, key, true, int256(bound(eth * 300_000_000, 1e9, 100_000_000 ether)), 100 * eth + 1 ether);
        } else {
            (ok,) = _swap(trader, key, true, -int256(eth), eth);
        }
        if (ok) ++tradesDone;
    }

    function sell(uint256 seed, uint256 share) external {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        uint256 amount = (IERC20(Currency.unwrap(key.currency1)).balanceOf(trader) * bound(share, 1, 100)) / 100;
        if (amount == 0) return;
        (bool ok,) = _swap(trader, key, false, -int256(amount), 0);
        if (ok) ++tradesDone;
    }

    function switchSides(uint256 seed, uint256 share) external {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        bool zeroForOne = (seed / 11) % 2 == 0;
        address input = Currency.unwrap(zeroForOne ? keys[2].currency0 : keys[2].currency1);
        uint256 amount = (IERC20(input).balanceOf(trader) * bound(share, 1, 100)) / 100;
        if (amount == 0) return;
        (bool ok,) = _swap(trader, keys[2], zeroForOne, -int256(amount), 0);
        if (ok) ++tradesDone;
    }

    /// @notice A trader leaves a side whole through the Duel router, pass after pass.
    function exit(uint256 seed) external {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 held = token.balanceOf(trader);
        if (held == 0) return;
        _approveAll(trader, key);
        vm.recordLogs();
        vm.prank(trader);
        try router.swapExactIn(key, false, held, 0, trader, block.timestamp) {}
        catch {
            return;
        }
        uint256 passes = _passes(vm.getRecordedLogs(), key);
        ++exitsDone;
        uint256 left = token.balanceOf(trader);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        bool soldOut = price >= TickMath.MAX_SQRT_PRICE - 1;
        if (passes == router.SALE_PASSES()) ++exitsAtTheBound;
        else if (left > 0 && !soldOut) ++exitsStoppedEarly;
        if (left > held / 1000 + 1 ether && !soldOut) ++exitsShort;
    }

    /// @dev The router's swaps in `key`'s pool, among `logs`.
    function _passes(Vm.Log[] memory logs, PoolKey memory key) internal view returns (uint256 n) {
        bytes32 swapped = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == swapped
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(router))))
            ) ++n;
        }
    }

    function wait(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 6 hours));
    }

    /// @notice A settlement on its own: the buyback, then the realignment, and no trade after them.
    function settle(uint256 seed) external {
        uint256 pairId = pairIds[seed % pairIds.length];
        vm.recordLogs();
        try hook.settle(pairId) {
            ++settlementsDone;
        } catch {
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(hook)
                    || logs[i].topics[0] != keccak256("RoundSettled(uint256,uint32,int24,address,uint256,uint256)")
            ) continue;
            (, address winner, uint256 spent,) = abi.decode(logs[i].data, (int24, address, uint256, uint256));
            if (spent == 0) continue;
            ++buybacksChecked;
            DuelHook.Pair memory p = hook.getPair(pairId);
            (PoolKey memory keyA, PoolKey memory keyD,) = hook.poolKeys(pairId);
            bool aWon = winner == p.tokenA;
            (, int24 tick,,) = manager.getSlot0((aWon ? keyA : keyD).toId());
            int24 limit = DuelMath.emaToTick(aWon ? p.emaA : p.emaD) - hook.BUYBACK_MAX_IMPACT_TICKS();
            if (tick < limit - 1) ++bandBreaks;
        }
    }

    // ------------------------------------------------------------------
    // The searcher: every round trip in one call
    // ------------------------------------------------------------------

    function roundTrip(uint256 seed, uint256 eth, uint8 route) external {
        (,, PoolKey[3] memory keys) = _pick(seed);
        eth = bound(eth, 1e12, 50 ether);
        route = uint8(bound(route, 0, 4));
        PoolKey memory key = keys[(seed / 3) % 2];
        (bool ok, BalanceDelta delta) = _swap(searcher, key, true, -int256(eth), eth);
        if (!ok) return;
        uint256 tokens = uint256(int256(delta.amount1()));
        if (route >= 3) {
            _triangle(key, keys, tokens, route == 4);
            ++roundTripsDone;
            return;
        }
        if (route == 0) {
            _swap(searcher, key, false, -int256(tokens), 0);
        } else if (route == 1) {
            // through the A/D pool and back, then out of the side it bought
            address token = Currency.unwrap(key.currency1);
            bool zeroForOne = Currency.unwrap(keys[2].currency0) == token;
            (bool there, BalanceDelta d1) = _swap(searcher, keys[2], zeroForOne, -int256(tokens), 0);
            if (there) {
                uint256 other = uint256(int256(zeroForOne ? d1.amount1() : d1.amount0()));
                (bool back, BalanceDelta d2) = _swap(searcher, keys[2], !zeroForOne, -int256(other), 0);
                if (back) tokens = uint256(int256(zeroForOne ? d2.amount0() : d2.amount1()));
            }
            _swap(searcher, key, false, -int256(tokens), 0);
        } else {
            // through ETH to the other side and back, with the Duel router
            PoolKey memory otherKey = keys[(seed / 3) % 2 == 0 ? 1 : 0];
            _approveAll(searcher, key);
            _approveAll(searcher, otherKey);
            vm.startPrank(searcher);
            try router.swapThroughEth(key, otherKey, tokens, 0, searcher, block.timestamp) returns (uint256 got) {
                try router.swapThroughEth(otherKey, key, got, 0, searcher, block.timestamp) returns (uint256 back) {
                    tokens = back;
                } catch {}
            } catch {}
            vm.stopPrank();
            _swap(searcher, key, false, -int256(tokens), 0);
        }
        ++roundTripsDone;
    }

    /// @dev The triangle's end: the `tokens` bought in `key`'s pool switched whole into the other side through the A/D
    ///      pool, and all of that sold into the other side's ETH pool, in one swap or with the Duel router's passes.
    function _triangle(PoolKey memory key, PoolKey[3] memory keys, uint256 tokens, bool passes) internal {
        PoolKey memory otherKey = keys[keys[0].currency1 == key.currency1 ? 1 : 0];
        bool zeroForOne = keys[2].currency0 == key.currency1;
        (bool there, BalanceDelta d1) = _swap(searcher, keys[2], zeroForOne, -int256(tokens), 0);
        if (!there) return;
        uint256 other = uint256(int256(zeroForOne ? d1.amount1() : d1.amount0()));
        if (!passes) {
            _swap(searcher, otherKey, false, -int256(other), 0);
        } else {
            _approveAll(searcher, otherKey);
            vm.prank(searcher);
            try router.swapExactIn(otherKey, false, other, 0, searcher, block.timestamp) {} catch {}
        }
        ++trianglesDone;
    }
}

/// @notice What must hold for the searcher: no round trip in one call pays, whatever the traders did before it, and
///         no buyback passes its band; the hook's books stay exact.
contract DuelSearcherInvariantsTest is DuelTestBase {
    SearcherHandler internal handler;
    uint256[] internal ids;

    function setUp() public override {
        super.setUp();
        ids.push(_createPair(0.02 ether, 0, false).id);
        ids.push(_createPair(0.01 ether, 0.01 ether, true).id);
        vm.warp(block.timestamp + 10);
        handler = new SearcherHandler(manager, hook, router, swapRouter, ids);
        targetContract(address(handler));
    }

    function afterInvariant() public view {
        assertGt(handler.tradesDone(), 0);
        assertGt(handler.roundTripsDone(), 0);
        console2.log(
            "round trips, settlements, buybacks checked:",
            handler.roundTripsDone(),
            handler.settlementsDone(),
            handler.buybacksChecked()
        );
        console2.log(
            "triangles, whole exits, exits at the bound:",
            handler.trianglesDone(),
            handler.exitsDone(),
            handler.exitsAtTheBound()
        );
    }

    function invariant_aRoundTripInOneCallNeverPays() public view {
        assertLe(handler.searcher().balance, handler.searcherStart());
    }

    /// @notice The router sells a whole exit until its pool can pay no more: it never stops with tokens left, passes to
    ///         spare and a pool that could still buy them.
    function invariant_aWholeExitStopsOnlyWhenThePoolCannotPay() public view {
        assertEq(handler.exitsStoppedEarly(), 0);
    }

    /// @notice A whole exit leaves at most dust, unless its pool sold out: what the realignment cannot route through
    ///         the pool between the sides.
    function invariant_aWholeExitLeavesOnlyDust() public view {
        assertEq(handler.exitsShort(), 0);
    }

    function invariant_buybacksStayInTheirBand() public view {
        assertEq(handler.bandBreaks(), 0);
    }

    function invariant_hookEthCoversExactlyWhatItOwes() public view {
        uint256 owed = hook.protocolFees();
        for (uint256 i = 0; i < ids.length; ++i) {
            DuelHook.Pair memory p = hook.getPair(ids[i]);
            owed += p.pot + p.creatorFees;
        }
        assertEq(manager.balanceOf(address(hook), 0), owed);
    }
}
