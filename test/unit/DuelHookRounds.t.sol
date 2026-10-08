// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";

contract DuelHookRoundsTest is DuelTestBase {
    function test_firstRoundEnd_rules() public view {
        // START_TIME is 12:00 UTC, a boundary: a plain four-hour round, to 16:00
        assertEq(hook.firstRoundEnd(START_TIME), START_TIME + 4 hours);
        // a second later, 16:00 leaves less than four hours of trading: the first round runs to 20:00
        assertEq(hook.firstRoundEnd(START_TIME + 1), START_TIME + 8 hours);
        assertEq(hook.firstRoundEnd(START_TIME + 4 hours - 1), START_TIME + 8 hours);
        assertEq(hook.firstRoundEnd(START_TIME + 4 hours), START_TIME + 8 hours);
        assertEq(hook.firstRoundEnd(START_TIME + 4 hours + 1), START_TIME + 12 hours);
        // boundaries fall every four hours from midnight UTC
        assertEq(hook.firstRoundEnd(START_TIME + 10 hours) % 1 days, 4 hours);
    }

    function test_registerPair_opensTheFirstRound() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(p.launchTime, START_TIME);
        assertEq(p.lastAccrual, START_TIME);
        assertEq(p.roundStart, START_TIME);
        assertEq(p.roundEnd, START_TIME + 4 hours);
        assertEq(p.roundIndex, 0);
        // both references start at the launch price, in 1/65536 of a tick
        assertEq(p.emaA, int40(p.startTick) * 65_536);
        assertEq(p.emaD, p.emaA);
    }

    function test_oracle_integratesTheEthPriceRatio() public {
        PairInfo memory info = _pairWithLeader(true, true);
        DuelHook.Pair memory before = hook.getPair(info.id);
        int24 ratio = _tick(info.keyD) - _tick(info.keyA);
        assertTrue(ratio != 0);

        vm.warp(block.timestamp + 1 hours);
        int24 tickA = _tick(info.keyA);
        _buy(bob, info.keyD, 0.0001 ether);
        DuelHook.Pair memory afterSwap = hook.getPair(info.id);
        assertEq(afterSwap.tickCumulative - before.tickCumulative, int64(ratio) * 3600);
        assertEq(afterSwap.lastAccrual, block.timestamp);
        // two time constants at the pool's price: the reference closed 1 - e^-2 of its distance to it
        assertEq(afterSwap.emaA, DuelMath.emaTick(before.emaA, tickA, 3600));
        int256 distance = int256(before.emaA) - int256(tickA) * 65_536;
        assertApproxEqRel(int256(afterSwap.emaA) - int256(tickA) * 65_536, distance * 135_335 / 1_000_000, 1e13);
    }

    function test_settle_buysBackAndBurnsTheWinner() public {
        _assertBuyback(true, true);
        _assertBuyback(true, false);
        _assertBuyback(false, true);
        _assertBuyback(false, false);
    }

    function _assertBuyback(bool aLeads, bool aIsCurrency0) internal {
        PairInfo memory info = _pairWithLeader(aLeads, aIsCurrency0);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 potBefore = p.pot;
        uint256 endBefore = p.roundEnd;
        address expected = aLeads ? address(info.a) : address(info.d);
        uint256 supplyBefore = aLeads ? info.a.totalSupply() : info.d.totalSupply();

        vm.warp(endBefore);
        Settlement memory s = _settleNow(info.id);

        assertTrue(s.found);
        assertEq(s.winner, expected);
        assertGt(s.spent, 0);
        assertGt(s.burned, 0);
        assertEq(supplyBefore - (aLeads ? info.a.totalSupply() : info.d.totalSupply()), s.burned);
        // the buyback moved the winner's price: the cross pool was realigned in the same settlement
        assertGt(s.captured, 0);
        p = hook.getPair(info.id);
        assertEq(p.pot, potBefore - s.spent + s.captured);
        assertEq(p.buybacks, s.spent);
        assertEq(p.roundIndex, 1);
        assertEq(p.roundStart, endBefore);
        assertEq(p.roundEnd, endBefore + hook.ROUND_LENGTH());
        assertFalse(p.roundTraded);
    }

    function test_settle_evenRoundKeepsThePot() public {
        // equal ETH buys at the same time keep the ETH price ratio exactly even
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 0.0001 ether);
        _buy(bob, info.keyD, 0.0001 ether);
        assertEq(_tick(info.keyA), _tick(info.keyD));
        uint256 potBefore = hook.getPair(info.id).pot;
        assertGt(potBefore, 0);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertTrue(s.found);
        assertEq(s.averageTick, 0);
        assertEq(s.winner, address(0));
        assertEq(hook.getPair(info.id).pot, potBefore);
    }

    function test_settle_buybackIsCappedAndQuietRoundsKeepThePot() public {
        PairInfo memory info = _createPair(0, 0, false);
        // a sniper pays the 98% launch tax: the first pot is huge compared to the pools
        _buy(alice, info.keyA, 10 ether);
        vm.warp(block.timestamp + 10);
        _buy(bob, info.keyD, 0.05 ether);
        uint256 potBefore = hook.getPair(info.id).pot;
        assertGt(potBefore, 9.8 ether);

        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);
        // at most a 10% price move above the winner's 30-minute average: the rest waits for later rounds
        assertLt(s.spent, potBefore / 10);
        uint256 potLeft = hook.getPair(info.id).pot;
        assertEq(potLeft, potBefore - s.spent + s.captured);
        uint256 spent = s.spent;

        // nobody trades during the next round: no winner, the pot waits
        _warpToRoundEnd(info.id);
        s = _settleNow(info.id);
        assertTrue(s.found);
        assertEq(s.winner, address(0));
        assertEq(hook.getPair(info.id).pot, potLeft);
        assertEq(hook.getPair(info.id).buybacks, spent);
    }

    function test_buybackCeiling_isAboutTenPercentAboveTheAverage() public view {
        // 953 ticks: a price 1.0001^953 times the 30-minute EMA's, about 1.10
        int24 ticks = hook.BUYBACK_MAX_IMPACT_TICKS();
        assertEq(ticks, 953);
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(ticks);
        assertApproxEqAbs(FullMath.mulDiv(sqrtPrice, sqrtPrice * 1e6, 1 << 192), 1_100_000, 100);
    }

    function test_settle_withAnEmptyPotBuysNothing() public {
        DuelFactory.Config memory c = defaultConfig();
        c.potShareBps = 0;
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(block.timestamp + 48 hours);
        factory.applyConfig();

        // no arbitrage either: nothing reaches the pot
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        PairInfo memory info = _createPair(0.05 ether, 0, false);
        assertEq(hook.getPair(info.id).pot, 0);
        // the creator's launch buy leads A, but the pot is empty
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertEq(s.spent, 0);
        assertEq(s.burned, 0);
    }

    function test_settle_skipsTheBuybackWhenThePriceJustRanAway() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 potBefore = hook.getPair(info.id).pot;
        // a late pump right before the deadline: the EMA barely moved, the price is out of the band
        vm.warp(hook.getPair(info.id).roundEnd - 60);
        _buy(alice, info.keyA, 5 ether);
        uint256 potAfterPump = hook.getPair(info.id).pot;
        assertGt(potAfterPump, potBefore);

        vm.warp(hook.getPair(info.id).roundEnd);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertEq(s.spent, 0);
        assertEq(hook.getPair(info.id).pot, potAfterPump);
    }

    function test_settle_skipsIdleRounds() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        uint256 round = hook.ROUND_LENGTH();
        vm.warp(end + 3 * round + 1 hours);
        hook.settle(info.id);
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(p.roundIndex, 4);
        assertEq(p.roundStart, end + 3 * round);
        assertEq(p.roundEnd, end + 4 * round);
        assertEq(p.lastAccrual, block.timestamp);
    }

    function test_settle_beforeTheDeadlineOnlyAccrues() public {
        PairInfo memory info = _pairWithLeader(true, true);
        vm.warp(block.timestamp + 1 hours);
        Settlement memory s = _settleNow(info.id);
        assertFalse(s.found);
        assertEq(hook.getPair(info.id).lastAccrual, block.timestamp);
        assertEq(hook.getPair(info.id).roundIndex, 0);
    }

    function test_settle_rejectsUnknownPairs() public {
        vm.expectRevert(DuelHook.UnknownPair.selector);
        hook.settle(0);
        vm.expectRevert(DuelHook.UnknownPair.selector);
        hook.settle(1);
    }

    function test_firstSwapAfterTheDeadlineSettles() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        vm.recordLogs();
        _buy(bob, info.keyD, 0.01 ether);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertTrue(s.found);
        assertEq(s.winner, address(info.a));
        // the swap that settled belongs to the new round
        assertTrue(hook.getPair(info.id).roundTraded);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    function test_settle_realignsThePoolsTheBuybackMoved() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertGt(s.spent, 0);
        assertGt(s.captured, 0);
        // the next trader finds the cross pool matching the ETH pools, not the buyback's gap
        uint256 sqrtA = _sqrtPrice(info.keyA);
        uint256 sqrtD = _sqrtPrice(info.keyD);
        uint256 implied = (sqrtD << 96) / sqrtA; // A is currency0 of the cross pool here
        assertApproxEqRel(_sqrtPrice(info.keyX), implied, 0.001e18);
    }

    function test_settle_failedRealignmentStillSettles() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);
        assertEq(s.captured, 0);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    function test_settle_oracleCatchesUpBeforeTheBuyback() public {
        PairInfo memory info = _pairWithLeader(true, true);
        // nobody trades for two hours after the close: A's EMA follows the price of those two hours
        DuelHook.Pair memory before = hook.getPair(info.id);
        vm.warp(before.roundEnd + 2 hours);
        int24 tickBefore = _tick(info.keyA);
        Settlement memory s = _settleNow(info.id);
        assertGt(s.spent, 0);
        assertTrue(_tick(info.keyA) < tickBefore);
        // accrued to the close, to the new round and to now: as one update over the whole time, to rounding
        uint256 elapsed = block.timestamp - before.lastAccrual;
        assertApproxEqAbs(hook.getPair(info.id).emaA, DuelMath.emaTick(before.emaA, tickBefore, elapsed), 2);
    }

    function test_oracle_soldOutPoolKeepsItsLaunchPriceAsReference() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 bought = _buy(alice, info.keyA, 0.1 ether);
        uint256 boughtD = _buy(bob, info.keyD, 0.1 ether);
        // oversized sells empty both pools of ETH and leave their prices at the swaps' limit; nothing realigns them
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        deal(address(info.a), alice, bought * 2);
        _sell(alice, info.keyA, bought * 2);
        deal(address(info.d), bob, boughtD * 2);
        _sell(bob, info.keyD, boughtD * 2);
        int24 start = hook.getPair(info.id).startTick;
        assertGt(_tick(info.keyA), start);
        assertGt(_tick(info.keyD), start);
        vm.warp(block.timestamp + 1 hours);
        _buy(bob, info.keyD, 0.001 ether);
        assertEq(hook.getPair(info.id).emaA, int40(start) * 65_536);
        assertEq(hook.getPair(info.id).emaD, int40(start) * 65_536);
        // and the app is shown the launch price, not the empty range's
        assertEq(lens.getPair(info.id).a.priceWad, lens.getPair(_createPair(0, 0, false).id).a.priceWad);
    }
}
