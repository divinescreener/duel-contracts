// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";

/// @notice Rounds at their edges: settled late or never, rounds nobody traded, the exact close, duels asleep for
///         years, launch buys, dust and sold-out pots, and several duels side by side.
contract DuelHookRoundEdgesTest is DuelTestBase {
    // ------------------------------------------------------------------
    // Pending rounds and idle rounds
    // ------------------------------------------------------------------

    /// @dev Round 0 traded but nobody settled it, round 1 passed without a single swap, and the settlement only comes
    ///      during round 2: it settles round 0 alone, skips round 1 and opens round 2.
    function test_pendingRoundThenIdleRound_settlesThePendingRoundOnly() public {
        PairInfo memory info = _pairWithLeader(true, true);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 end = p.roundEnd;
        uint256 potBefore = p.pot;
        uint256 round = hook.ROUND_LENGTH();

        vm.warp(end + round + 3 hours);
        vm.recordLogs();
        hook.settle(info.id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, ROUND_SETTLED), 1);
        Settlement memory s = _settlementIn(logs);
        assertEq(s.round, 0);
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);
        p = hook.getPair(info.id);
        assertEq(p.roundIndex, 2);
        assertEq(p.roundStart, end + round);
        assertEq(p.roundEnd, end + 2 * round);
        assertFalse(p.roundTraded);
        assertEq(p.pot, potBefore - s.spent + s.captured);
    }

    /// @dev The same scenario settled by a trade of the side that was behind: the pending round keeps its winner, and
    ///      the trade counts for the round now running.
    function test_pendingRoundThenIdleRound_settledByATradeOfTheOtherSide() public {
        PairInfo memory info = _pairWithLeader(true, false);
        uint256 end = hook.getPair(info.id).roundEnd;

        vm.warp(end + hook.ROUND_LENGTH() + 3 hours);
        vm.recordLogs();
        _buy(bob, info.keyD, 20 ether);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());

        assertEq(s.round, 0);
        assertEq(s.winner, address(info.a));
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(p.roundIndex, 2);
        assertTrue(p.roundTraded);
        // live, D now leads by far; the round it just entered is D's to win
        assertLt(hook.gaugeBps(info.id), 5000);
    }

    /// @dev A round settled on time, an hour late, the next day or a month later: the same average, the same winner.
    function test_lateSettlementGivesTheSameResult() public {
        PairInfo memory info = _pairWithLeader(false, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        uint256 snapshot = vm.snapshotState();
        vm.warp(end);
        Settlement memory onTime = _settleNow(info.id);
        assertEq(onTime.winner, address(info.d));

        uint256[3] memory delays = [uint256(1 hours), 1 days + 5 hours, 30 days];
        for (uint256 i = 0; i < delays.length; ++i) {
            vm.revertToState(snapshot);
            vm.warp(end + delays[i]);
            Settlement memory late = _settleNow(info.id);
            assertEq(late.round, 0);
            assertEq(late.averageTick, onTime.averageTick);
            assertEq(late.winner, onTime.winner);
            assertGt(late.spent, 0);
        }
    }

    /// @dev Nobody traded during a round: it has no winner, even with one side clearly ahead the whole time.
    function test_roundWithoutTrades_hasNoWinnerWhateverTheSplit() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        assertEq(_settleNow(info.id).winner, address(info.a));
        uint256 pot = hook.getPair(info.id).pot;
        assertGt(pot, 0);
        // the split carries over: A stays ahead through round 1, where nothing trades
        assertGt(hook.gaugeBps(info.id), 5000);

        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertTrue(s.found);
        assertEq(s.round, 1);
        assertGt(s.averageTick, 0);
        assertEq(s.winner, address(0));
        assertEq(s.spent, 0);
        assertEq(hook.getPair(info.id).pot, pot);
    }

    /// @dev The pot a capped buyback left, carried through rounds nobody traded, buys back the next winner, whichever
    ///      side it is.
    function test_potCarriedThroughIdleRounds_buysTheNextWinner() public {
        PairInfo memory info = _createPair(0, 0, false);
        // round 0: a sniper's 98% tax fills the pot far beyond what one buyback may spend
        _buy(alice, info.keyA, 10 ether);
        vm.warp(block.timestamp + 10);
        _buy(bob, info.keyD, 0.05 ether);
        _warpToRoundEnd(info.id);
        Settlement memory first = _settleNow(info.id);
        assertEq(first.winner, address(info.a));
        uint256 carried = hook.getPair(info.id).pot;
        assertGt(carried, 9 ether);

        // rounds 1 and 2 pass without a swap; the first trade comes during round 3 and closes round 1, without a winner
        uint256 end = hook.getPair(info.id).roundEnd;
        vm.warp(end + hook.ROUND_LENGTH() + 2 hours);
        vm.recordLogs();
        _buy(bob, info.keyD, 1 ether);
        Settlement memory quiet = _settlementIn(vm.getRecordedLogs());
        assertEq(quiet.round, 1);
        assertEq(quiet.winner, address(0));
        assertEq(hook.getPair(info.id).roundIndex, 3);

        // round 3 goes to D: the pot A's round left behind now buys D
        uint256 supplyD = info.d.totalSupply();
        _warpToRoundEnd(info.id);
        Settlement memory third = _settleNow(info.id);
        assertEq(third.round, 3);
        assertEq(third.winner, address(info.d));
        assertGt(third.spent, 0);
        assertEq(supplyD - info.d.totalSupply(), third.burned);
        assertEq(hook.getPair(info.id).buybacks, first.spent + third.spent);
    }

    /// @dev Idle rounds are skipped whole: settled a second before a full round after the close, only the pending
    ///      round closes; settled exactly a round after, the next round passed entirely and is skipped too.
    function test_skippedRounds_countWholeRounds() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        uint256 round = hook.ROUND_LENGTH();
        uint256 snapshot = vm.snapshotState();

        vm.warp(end + round - 1);
        hook.settle(info.id);
        assertEq(hook.getPair(info.id).roundIndex, 1);
        assertEq(hook.getPair(info.id).roundEnd, end + round);

        vm.revertToState(snapshot);
        vm.warp(end + round);
        hook.settle(info.id);
        assertEq(hook.getPair(info.id).roundIndex, 2);
        assertEq(hook.getPair(info.id).roundStart, end + round);
        assertEq(hook.getPair(info.id).roundEnd, end + 2 * round);
    }

    /// @dev A duel nobody touched for three years wakes up in the right round, its pending result intact.
    function test_aDuelAsleepForYears_wakesUpInTheRightRound() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        uint256 round = hook.ROUND_LENGTH();
        // the rounds in three years
        uint256 asleep = (3 * 365 days) / round;

        vm.warp(end + asleep * round + 3 hours);
        vm.recordLogs();
        _buy(bob, info.keyD, 0.01 ether);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertEq(s.round, 0);
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);

        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(p.roundIndex, asleep + 1);
        assertEq(p.roundStart, end + asleep * round);
        assertEq(p.roundEnd, end + (asleep + 1) * round);
        assertEq(p.lastAccrual, block.timestamp);
        assertEq(p.roundEnd, hook.firstRoundEnd(p.launchTime) + uint256(p.roundIndex) * round);
    }

    // ------------------------------------------------------------------
    // The close
    // ------------------------------------------------------------------

    /// @dev The close is exact: a swap one second before it trades in the round, a swap on it settles first.
    function test_theCloseIsExact() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;

        vm.warp(end - 1);
        vm.recordLogs();
        _buy(bob, info.keyD, 0.01 ether);
        assertFalse(_settlementIn(vm.getRecordedLogs()).found);
        assertEq(hook.getPair(info.id).roundIndex, 0);

        vm.warp(end);
        vm.recordLogs();
        _buy(bob, info.keyD, 0.01 ether);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertTrue(s.found);
        assertEq(s.round, 0);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    /// @dev Two swaps in the block that closes the round: the first one settles, the second one trades.
    function test_twoSwapsInTheClosingBlock_settleOnce() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        vm.recordLogs();
        _buy(bob, info.keyD, 0.01 ether);
        _buy(alice, info.keyA, 0.01 ether);
        assertEq(_count(vm.getRecordedLogs(), ROUND_SETTLED), 1);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    /// @dev Settling twice settles once: the second call only accrues the oracle of the new round.
    function test_settleTwice_settlesOnce() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        assertTrue(_settleNow(info.id).found);
        DuelHook.Pair memory p = hook.getPair(info.id);

        vm.warp(block.timestamp + 1 hours);
        assertFalse(_settleNow(info.id).found);
        DuelHook.Pair memory q = hook.getPair(info.id);
        assertEq(q.roundIndex, p.roundIndex);
        assertEq(q.roundEnd, p.roundEnd);
        assertEq(q.pot, p.pot);
        assertEq(q.buybacks, p.buybacks);
        assertEq(q.lastAccrual, block.timestamp);
    }

    /// @dev A whale buying the losing side one second before the close leads live, but that second barely counts: the
    ///      round stays with the side that led all along.
    function test_aLastSecondPump_weighsOneSecond() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        vm.warp(end - 1);
        _buy(bob, info.keyD, 30 ether);
        assertLt(hook.gaugeBps(info.id), 5000);
        assertGt(lens.getPair(info.id).roundGaugeBps, 5000);

        vm.warp(end);
        assertEq(_settleNow(info.id).winner, address(info.a));
    }

    /// @dev The only trade of a duel's first round comes an hour before the close: it decides the round, weighted by
    ///      the hour its side led out of the round's four.
    function test_aLoneLateTrade_decidesAnOtherwiseEmptyRound() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 length = p.roundEnd - p.roundStart;
        vm.warp(p.roundEnd - 1 hours);
        _buy(bob, info.keyD, 1 ether);
        int256 ratio = int256(_tick(info.keyD)) - _tick(info.keyA);
        if (!p.aIsCurrency0) ratio = -ratio;
        assertTrue(ratio != 0);

        vm.warp(p.roundEnd);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.d));
        assertEq(int256(s.averageTick), (ratio * 1 hours) / int256(length));
    }

    /// @dev An average of less than a tick either way is a draw: a small switch that moved the split for half an hour,
    ///      then came back, leaves a round without a winner even though it traded.
    function test_anAverageUnderOneTick_isADraw() public {
        // A is currency1 of the cross pool: A into the pool raises the price, and the fees of the way back leave it
        // just above 1:1, at tick 0
        PairInfo memory info = _createPairOriented(false);
        deal(address(info.a), alice, 5000 ether);
        uint256 dogs = _switch(alice, info, address(info.a), 5000 ether);
        int24 nudged = _tick(info.keyX);
        assertGt(nudged, 0);
        assertLt(nudged, 10); // under the realignment threshold, and no ETH pool to realign against anyway

        vm.warp(block.timestamp + 30 minutes);
        _switch(alice, info, address(info.d), dogs);
        assertEq(_tick(info.keyX), 0);

        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertTrue(s.found);
        assertEq(s.averageTick, 0);
        assertEq(s.winner, address(0));
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------

    /// @dev The creator's launch buys are swaps like any other: they make the first round a traded one.
    function test_launchBuys_countAsTradesOfTheFirstRound() public {
        PairInfo memory info = _createPair(0.05 ether, 0, false);
        assertTrue(hook.getPair(info.id).roundTraded);
        assertGt(hook.getPair(info.id).pot, 0);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);
    }

    /// @dev A duel launched without launch buys that nobody ever trades: its first round has no winner and no pot.
    function test_aDuelNobodyTraded_hasNoWinnerAndNoPot() public {
        PairInfo memory info = _createPair(0, 0, false);
        assertFalse(hook.getPair(info.id).roundTraded);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertTrue(s.found);
        assertEq(s.averageTick, 0);
        assertEq(s.winner, address(0));
        assertEq(hook.getPair(info.id).pot, 0);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    // ------------------------------------------------------------------
    // Buybacks
    // ------------------------------------------------------------------

    /// @dev Even a narrow ETH lead decides the round when the cross pool disagrees and realignment is unavailable.
    function test_aNarrowEthLead_isNotOverriddenByTheCrossPool() public {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        PairInfo memory info = _createPair(0.0005 ether, 0, false);
        uint256 gauge = hook.gaugeBps(info.id);
        _switch(creator, info, address(info.a), info.a.balanceOf(creator));
        assertEq(hook.gaugeBps(info.id), gauge);
        assertEq(lens.getPair(info.id).d.ethReserve, 0);
        _warpToRoundEnd(info.id);
        assertEq(_settleNow(info.id).winner, address(info.a));
    }

    function test_aSwitchNoEthFollows_doesNotChangeTheRoundSignal() public {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        PairInfo memory info = _createPair(0.05 ether, 0, false);
        DuelHook.Pair memory p = hook.getPair(info.id);
        int24 ratio = p.aIsCurrency0 ? _tick(info.keyD) - _tick(info.keyA) : _tick(info.keyA) - _tick(info.keyD);
        uint256 gauge = hook.gaugeBps(info.id);
        _switch(creator, info, address(info.a), info.a.balanceOf(creator));
        assertEq(hook.gaugeBps(info.id), gauge);
        assertGt(gauge, 5000);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertEq(s.averageTick, ratio);
    }

    /// @dev A cross-only trade also cannot enable a winner in an otherwise inactive round with an existing ETH lead.
    function test_aCrossOnlySwap_doesNotActivateAQuietRound_aFirst() public {
        _checkCrossOnlyQuietRound(true);
    }

    function test_aCrossOnlySwap_doesNotActivateAQuietRound_dFirst() public {
        _checkCrossOnlyQuietRound(false);
    }

    function _checkCrossOnlyQuietRound(bool aIsCurrency0) internal {
        PairInfo memory info = _pairWithLeader(true, aIsCurrency0);
        _warpToRoundEnd(info.id);
        _settleNow(info.id);
        assertFalse(hook.getPair(info.id).roundTraded);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        uint256 gauge = hook.gaugeBps(info.id);
        vm.warp(block.timestamp + 1 hours);
        _switch(alice, info, address(info.a), info.a.balanceOf(alice) / 10);
        assertEq(hook.gaugeBps(info.id), gauge);
        assertEq(lens.getPair(info.id).roundGaugeBps, gauge);
        assertFalse(hook.getPair(info.id).roundTraded);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(0));
        assertEq(s.spent, 0);
    }

    function test_aCrossTradeWhoseRealignmentChangesEth_activatesTheRound() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _warpToRoundEnd(info.id);
        _settleNow(info.id);
        assertFalse(hook.getPair(info.id).roundTraded);
        int24 beforeA = _tick(info.keyA);
        int24 beforeD = _tick(info.keyD);
        _switch(alice, info, address(info.a), info.a.balanceOf(alice) / 10);
        assertTrue(beforeA != _tick(info.keyA) || beforeD != _tick(info.keyD));
        assertTrue(hook.getPair(info.id).roundTraded);
    }

    /// @dev A pot of one wei buys what one wei buys: the settlement never fails on dust.
    function test_aDustPot_settlesWithoutFailing() public {
        PairInfo memory info = _pairWithLeader(true, true);
        _setPot(info.id, 1);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
        assertEq(s.spent, 1);
        assertEq(hook.getPair(info.id).roundIndex, 1);
    }

    // ------------------------------------------------------------------
    // Several duels
    // ------------------------------------------------------------------

    /// @dev Settling one duel leaves the others alone: their pots, their rounds and the ETH that backs them.
    function test_settlingOneDuel_leavesTheOthersAlone() public {
        PairInfo memory one = _pairWithLeader(true, true);
        PairInfo memory two = _pairWithLeader(false, true);
        DuelHook.Pair memory before = hook.getPair(two.id);

        _warpToRoundEnd(one.id);
        Settlement memory s = _settleNow(one.id);
        assertGt(s.spent, 0);

        DuelHook.Pair memory untouched = hook.getPair(two.id);
        assertEq(untouched.pot, before.pot);
        assertEq(untouched.roundIndex, 0);
        assertEq(untouched.lastAccrual, before.lastAccrual);
        DuelHook.Pair memory settled = hook.getPair(one.id);
        assertEq(
            manager.balanceOf(address(hook), 0),
            hook.protocolFees() + settled.pot + settled.creatorFees + untouched.pot + untouched.creatorFees
        );

        // and its own round waits for its own close and its own settlement: launched ten seconds later, its first
        // round runs to the next boundary
        assertGt(untouched.roundEnd, settled.roundStart);
        _warpToRoundEnd(two.id);
        assertEq(_settleNow(two.id).winner, address(two.d));
        assertEq(hook.getPair(two.id).roundIndex, 1);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Sets a pair's pot directly: slot 6 of its `Pair` struct holds the pot (low 128 bits) and the creator fees.
    ///      The pairs are the hook's slot 3, after `pairCount`, `protocolFees` and `protocolRateBps`.
    function _setPot(uint256 pairId, uint128 pot) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(pairId, uint256(3)))) + 6);
        uint256 word = uint256(vm.load(address(hook), slot));
        vm.store(address(hook), slot, bytes32((word >> 128) << 128 | pot));
        assertEq(hook.getPair(pairId).pot, pot);
    }
}
