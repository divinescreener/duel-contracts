// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DuelHookArbitrageTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Cross pool sqrt price implied by the two ETH pools.
    function _impliedCrossSqrtPrice(PairInfo memory info) internal view returns (uint256) {
        uint256 sqrtA = _sqrtPrice(info.keyA);
        uint256 sqrtD = _sqrtPrice(info.keyD);
        return hook.getPair(info.id).aIsCurrency0
            ? FullMath.mulDiv(sqrtD, 1 << 96, sqrtA)
            : FullMath.mulDiv(sqrtA, 1 << 96, sqrtD);
    }

    function _capturedIn(Vm.Log[] memory logs) internal view returns (uint256 total, uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == ARBITRAGE_CAPTURED) {
                total += abi.decode(logs[i].data, (uint256));
                ++count;
            }
        }
    }

    /// @dev A pair past its anti-snipe window with both ETH pools active and aligned.
    function _activePair() internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 0.5 ether);
        _buy(alice, info.keyD, 0.5 ether);
    }

    function test_arbitrage_skippedWhileNoEthPoolHoldsEth() public {
        PairInfo memory info = _createPair(0, 0, false);
        // tokens from elsewhere, switched before anyone bought either side: no ETH to realign against
        deal(address(info.a), alice, 1_000_000 ether);
        vm.recordLogs();
        _switch(alice, info, address(info.a), 1_000_000 ether);
        (, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 0);
        assertEq(hook.getPair(info.id).pot, 0);
    }

    /// @dev The first buy of one side realigns the cross pool at once: the split follows it.
    function _assertFirstBuyRealigns(bool sideA) internal {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        int24 start = hook.getPair(info.id).startTick;
        vm.recordLogs();
        _buy(alice, sideA ? info.keyA : info.keyD, 1 ether);
        (uint256 captured, uint256 count) = _capturedIn(vm.getRecordedLogs());

        assertEq(count, 1);
        assertGt(captured, 0);
        // the other side was bought by the cycle: both ETH pools now hold ETH
        assertLt(_tick(info.keyA), start);
        assertLt(_tick(info.keyD), start);
        assertApproxEqRel(_sqrtPrice(info.keyX), _impliedCrossSqrtPrice(info), 0.001e18);
        uint256 gauge = hook.gaugeBps(info.id);
        if (sideA) assertGt(gauge, 5000);
        else assertLt(gauge, 5000);
    }

    function test_arbitrage_followsTheFirstBuyOfA() public {
        _assertFirstBuyRealigns(true);
    }

    function test_arbitrage_followsTheFirstBuyOfD() public {
        _assertFirstBuyRealigns(false);
    }

    function test_arbitrage_realignsAfterABuyOfA() public {
        PairInfo memory info = _activePair();
        uint256 priceDBefore = _sqrtPrice(info.keyD);
        uint256 potBefore = hook.getPair(info.id).pot;

        vm.recordLogs();
        _buy(bob, info.keyA, 1 ether);
        (uint256 captured, uint256 count) = _capturedIn(vm.getRecordedLogs());

        assertEq(count, 1);
        assertGt(captured, 0);
        assertEq(hook.getPair(info.id).pot - potBefore, captured + 0.004_08 ether);
        // cycle through D: D was bought, so its price in ETH went up (fewer D per wei)
        assertLt(_sqrtPrice(info.keyD), priceDBefore);
        // and the cross pool now matches the ETH pools
        assertApproxEqRel(_sqrtPrice(info.keyX), _impliedCrossSqrtPrice(info), 0.001e18);
    }

    function test_arbitrage_realignsAfterABuyOfD() public {
        PairInfo memory info = _activePair();
        uint256 priceABefore = _sqrtPrice(info.keyA);

        vm.recordLogs();
        _buy(bob, info.keyD, 1 ether);
        (uint256 captured, uint256 count) = _capturedIn(vm.getRecordedLogs());

        assertEq(count, 1);
        assertGt(captured, 0);
        assertLt(_sqrtPrice(info.keyA), priceABefore);
        assertApproxEqRel(_sqrtPrice(info.keyX), _impliedCrossSqrtPrice(info), 0.001e18);
    }

    function test_arbitrage_realignsAfterASwitch() public {
        PairInfo memory info = _activePair();
        vm.recordLogs();
        _switch(alice, info, address(info.a), info.a.balanceOf(alice) / 2);
        (uint256 captured, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 1);
        assertGt(captured, 0);
        assertApproxEqRel(_sqrtPrice(info.keyX), _impliedCrossSqrtPrice(info), 0.001e18);
    }

    function test_arbitrage_ignoresSmallMispricing() public {
        PairInfo memory info = _activePair();
        vm.recordLogs();
        _buy(bob, info.keyA, 0.0001 ether);
        (, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 0);
    }

    /// @dev What the cycle a buy of A opens pays per ETH, in WAD, as the hook reads the pools: ETH for D in its pool,
    ///      D for A in the cross pool, A for ETH in its pool.
    function _cycleThroughD(PairInfo memory info) internal view returns (uint256) {
        uint128 liquidity = manager.getLiquidity(info.keyA.toId());
        (uint256 ethA, uint256 tokA) = DuelMath.virtualReserves(liquidity, _sqrtPrice(info.keyA));
        (uint256 ethD, uint256 tokD) = DuelMath.virtualReserves(liquidity, _sqrtPrice(info.keyD));
        (uint256 cross0, uint256 cross1) =
            DuelMath.virtualReserves(manager.getLiquidity(info.keyX.toId()), _sqrtPrice(info.keyX));
        (uint256 crossA, uint256 crossD) = hook.getPair(info.id).aIsCurrency0 ? (cross0, cross1) : (cross1, cross0);
        return FullMath.mulDiv(FullMath.mulDiv(FullMath.mulDiv(1e18, tokD, ethD), crossA, crossD), ethA, tokA);
    }

    /// @dev The ETH a buy of A takes for that cycle to pay `ratio` after it: the buy, net of its 1.2% fee, grows A's ETH
    ///      reserve, and the cycle's last price with the square of it.
    function _buyForCycle(PairInfo memory info, uint256 ratio) internal view returns (uint256) {
        (uint256 ethA,) = DuelMath.virtualReserves(manager.getLiquidity(info.keyA.toId()), _sqrtPrice(info.keyA));
        uint256 growth = Math.sqrt(FullMath.mulDiv(ratio, 1e36, _cycleThroughD(info)));
        return FullMath.mulDiv(ethA, growth - 1e18, 1e18) * 10_000 / 9880;
    }

    /// @dev The arbitrage runs from a mispricing of 0.1% (ARB_THRESHOLD_BPS): a buy that leaves the cycle paying 1.00095
    ///      per ETH is let be, one that leaves it paying 1.00105 is realigned.
    function test_arbitrage_runsFromATenthOfAPercent() public {
        PairInfo memory info = _activePair();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        _buy(bob, info.keyA, _buyForCycle(info, 1.00095e18));
        (, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 0);
        // the buy left the cycle where it was aimed: the arbitrage passed it by
        assertApproxEqRel(_cycleThroughD(info), 1.00095e18, 0.000001e18);
        vm.revertToState(snapshot);

        vm.recordLogs();
        _buy(bob, info.keyA, _buyForCycle(info, 1.00105e18));
        (uint256 captured, uint256 realigned) = _capturedIn(vm.getRecordedLogs());
        assertEq(realigned, 1);
        assertGt(captured, 0);
        assertLt(_cycleThroughD(info), 1.0001e18);
    }

    function test_arbitrage_failureNeverBlocksTheSwap() public {
        PairInfo memory info = _activePair();
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector, info.id), "boom");
        vm.recordLogs();
        uint256 bought = _buy(bob, info.keyA, 1 ether);
        (, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertGt(bought, 0);
        assertEq(count, 0);
    }

    /// @dev Tokens from outside the Duel pools flood the cross pool while the arbitrage is off: realigning in full
    ///      would sell more of them into their ETH pool than its ETH pays for.
    function _floodedCrossPool(bool withA) internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector, info.id), "off");
        _buy(alice, info.keyA, 0.01 ether);
        _buy(bob, info.keyD, 0.01 ether);
        address token = withA ? address(info.a) : address(info.d);
        deal(token, alice, 500_000_000 ether);
        _switch(alice, info, token, 500_000_000 ether);
        vm.clearMockedCalls();
    }

    function _assertSellsNoMoreThanThePoolPays(bool withA) internal {
        PairInfo memory info = _floodedCrossPool(withA);
        int24 start = hook.getPair(info.id).startTick;
        vm.recordLogs();
        // any swap of the pair runs the arbitrage
        _buy(bob, info.keyA, 0.0001 ether);
        (uint256 captured, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 1);
        assertGt(captured, 0);
        // the pool it sold into kept a little ETH, just below its launch price
        int24 tick = _tick(withA ? info.keyA : info.keyD);
        assertLt(tick, start);
        assertGt(tick, start - 200);
    }

    uint256 internal _arbPair;

    /// @dev Runs the hook's arbitrage directly inside a PoolManager unlock, as the hook would from afterSwap.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        vm.expectRevert(DuelHook.PartialFill.selector);
        vm.prank(address(hook));
        hook.arbitrage(_arbPair);
        return "";
    }

    /// @dev If a pool ever held less than the math reads, the cycle reverts instead of leaving the hook with tokens,
    ///      which would fail the trader's whole transaction.
    function test_arbitrage_revertsRatherThanKeepTokens() public {
        PairInfo memory info = _floodedCrossPool(true);
        // the hook reads ten times the liquidity pool A has: it would size the cycle for ETH that is not there
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encodePacked(PoolId.unwrap(info.keyA.toId()), StateLibrary.POOLS_SLOT)))
                + StateLibrary.LIQUIDITY_OFFSET
        );
        uint128 liquidity = manager.getLiquidity(info.keyA.toId());
        vm.mockCall(
            address(manager), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(uint256(liquidity) * 10)
        );
        _arbPair = info.id;
        manager.unlock("");
    }

    function test_arbitrage_neverSellsMoreThanAPoolPaysFor() public {
        _assertSellsNoMoreThanThePoolPays(true);
        _assertSellsNoMoreThanThePoolPays(false);
    }

    /// @dev A cycle the pool's ETH caps sells a tenth of a percent less than the pool can buy back: rounding never takes
    ///      its last swap to the launch price, where it would stop short and the whole cycle fail.
    function test_arbitrage_leavesThePoolItSellsIntoAMargin() public {
        // D floods the cross pool: the realignment sells D into its ETH pool, which the buy of A that runs it leaves alone
        PairInfo memory info = _floodedCrossPool(false);
        uint160 launch = TickMath.getSqrtPriceAtTick(hook.getPair(info.id).startTick);
        uint128 liquidity = manager.getLiquidity(info.keyD.toId());
        uint256 sellable = SqrtPriceMath.getAmount1Delta(_sqrtPrice(info.keyD), launch, liquidity, false);
        vm.recordLogs();
        _buy(bob, info.keyA, 0.0001 ether);
        (, uint256 count) = _capturedIn(vm.getRecordedLogs());
        assertEq(count, 1);
        uint256 left = SqrtPriceMath.getAmount1Delta(_sqrtPrice(info.keyD), launch, liquidity, false);
        assertGe(left, sellable / 1000);
        assertLt(left, sellable / 500);
    }
}
