// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice Defensive properties of normal price histories, views and validated configuration boundaries.
/// @dev No fork, borrowing, external callback, artificial storage mutation or profit-search handler is used.
contract DuelOracleSecurityTest is DuelTestBase {
    uint256 internal constant DECIMAL_ONE = 1e18;
    int256 internal constant TICK_ONE = 65_536;

    /// @dev Independent decimal reference: a positive Taylor series for exp(x), reciprocal, then repeated
    ///      multiplication. Production instead uses precomputed binary decay factors in Q128. The reduction keeps
    ///      x <= 1/2; 24 terms and decimal truncation contribute far less than one Q16 unit for admissible ticks.
    function _referenceDecay(uint256 elapsed) internal pure returns (uint256 decay) {
        if (elapsed == 0) return DECIMAL_ONE;
        // exp(-65536/1800) times the entire admissible tick span is below 1/65536 of a tick.
        if (elapsed >= 65_536) return 0;
        uint256 spans = (elapsed + 899) / 900;
        uint256 x = elapsed * DECIMAL_ONE / (1800 * spans);
        uint256 term = DECIMAL_ONE;
        uint256 exponential = term;
        for (uint256 n = 1; n <= 24; ++n) {
            term = term * x / (DECIMAL_ONE * n);
            exponential += term;
        }
        uint256 step = DECIMAL_ONE * DECIMAL_ONE / exponential;
        decay = DECIMAL_ONE;
        for (uint256 n = 0; n < spans; ++n) {
            decay = decay * step / DECIMAL_ONE;
        }
    }

    /// @dev The buyback's reference as the hook keeps it: the EMA, floored at the tick held (a higher tick is a lower
    ///      price): the reference follows a price down at once, up at the EMA's pace.
    function _referenceEma(int256 previous, int24 tick, uint256 elapsed) internal pure returns (int256 ema) {
        int256 target = int256(tick) * TICK_ONE;
        ema = target + (previous - target) * int256(_referenceDecay(elapsed)) / int256(DECIMAL_ONE);
        if (ema < target) ema = target;
    }

    function _effectiveTick(PoolKey memory key, int24 startTick) internal view returns (int24) {
        int24 tick = _tick(key);
        return tick < startTick ? tick : startTick;
    }

    /// @dev Eight ordinary buys/sells exercise both ETH-pool histories without closing the four-hour first round.
    ///      The independent model retains its own prior expected EMA rather than resetting to production each step.
    function testFuzz_bothEmasMatchIndependentHistories(uint256 seed) public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelHook.Pair memory initial = hook.getPair(info.id);
        int256 expectedA = int256(initial.startTick) * TICK_ONE;
        int256 expectedD = expectedA;
        uint256 last = block.timestamp;
        for (uint256 i = 0; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 elapsed = seed % 901;
            int24 tickA = _effectiveTick(info.keyA, initial.startTick);
            int24 tickD = _effectiveTick(info.keyD, initial.startTick);
            // a swap in the second of the one before it accrues nothing: the hook's references move when time does,
            // a price that fell in that second included (they follow it down at the next accrual)
            if (elapsed != 0) {
                expectedA = _referenceEma(expectedA, tickA, elapsed);
                expectedD = _referenceEma(expectedD, tickD, elapsed);
            }
            vm.warp(last + elapsed);
            if (i == 2) {
                _sell(alice, info.keyA, info.a.balanceOf(alice) / 3);
            } else if (i == 5) {
                _sell(bob, info.keyD, info.d.balanceOf(bob) / 3);
            } else {
                _buy(i % 2 == 0 ? alice : bob, i % 2 == 0 ? info.keyA : info.keyD, 0.001 ether + seed % 0.02 ether);
            }
            DuelHook.Pair memory current = hook.getPair(info.id);
            // At most one Q16 rounding unit per production accrual, accumulated over the history.
            assertApproxEqAbs(int256(current.emaA), expectedA, i + 1);
            assertApproxEqAbs(int256(current.emaD), expectedD, i + 1);
            assertEq(current.lastAccrual, block.timestamp);
            assertEq(current.roundIndex, 0);
            last = block.timestamp;
        }
    }

    function test_referenceDecayHasKnownAnalyticAnchors() public pure {
        assertEq(_referenceDecay(0), DECIMAL_ONE);
        assertApproxEqAbs(_referenceDecay(1800), 367_879_441_171_442_321, 100);
        assertApproxEqAbs(_referenceDecay(3600), 135_335_283_236_612_691, 100);
        assertEq(_referenceDecay(65_536), 0);
    }

    /// @dev The reference predicts accrual across the close and multiple skipped rounds before any buyback moves
    ///      the prices. Each split adds at most one Q16 unit; the public settlement uses at most three accruals.
    function testFuzz_emaCatchupMatchesIndependentReference(uint32 delaySeed, bool aIsCurrency0) public {
        PairInfo memory info = _pairWithLeader(true, aIsCurrency0);
        DuelHook.Pair memory before = hook.getPair(info.id);
        int24 tickA = _effectiveTick(info.keyA, before.startTick);
        int24 tickD = _effectiveTick(info.keyD, before.startTick);
        uint256 when = uint256(before.roundEnd) + bound(delaySeed, 0, 30 days);
        int256 expectedA = _referenceEma(before.emaA, tickA, when - before.lastAccrual);
        int256 expectedD = _referenceEma(before.emaD, tickD, when - before.lastAccrual);
        vm.warp(when);
        hook.settle(info.id);
        DuelHook.Pair memory after_ = hook.getPair(info.id);
        assertApproxEqAbs(int256(after_.emaA), expectedA, 3);
        assertApproxEqAbs(int256(after_.emaD), expectedD, 3);
        assertEq(after_.lastAccrual, when);
        assertGt(after_.roundEnd, when);
    }

    /// @dev The view must predict the decision that actually settles, for both token orientations, either leader,
    ///      all delays in the range and both first and subsequent inactive rounds. A read is checked for mutations.
    function testFuzz_lensPredictsSettlementForBothOrientations(bool aLeads, bool aIsCurrency0, uint32 delaySeed)
        public
    {
        PairInfo memory info = _pairWithLeader(aLeads, aIsCurrency0);
        uint256 end = hook.getPair(info.id).roundEnd;
        vm.warp(end);
        uint256 atClose = lens.getPair(info.id).roundGaugeBps;
        vm.warp(end + bound(delaySeed, 0, 30 days));
        bytes32 stateBeforeRead = _stateDigest(info);
        DuelLens.PairView memory prediction = lens.getPair(info.id);
        lens.getPairs(info.id - 1, 1);
        assertEq(_stateDigest(info), stateBeforeRead);
        assertEq(prediction.roundGaugeBps, atClose);
        Settlement memory result = _settleNow(info.id);
        assertTrue(result.found);
        assertEq(result.round, prediction.roundIndex);
        _assertWinnerMatchesView(prediction, result);

        // A silent round may have a non-neutral gauge, but cannot name a winner or spend the pot.
        vm.warp(hook.getPair(info.id).roundEnd + 1 days);
        prediction = lens.getPair(info.id);
        assertFalse(prediction.roundTraded);
        result = _settleNow(info.id);
        _assertWinnerMatchesView(prediction, result);
        assertEq(result.winner, address(0));
        assertEq(result.spent, 0);
        assertEq(result.burned, 0);
    }

    function test_lensPredictsNeutralAndOneTickRounds() public {
        for (uint256 i = 0; i < 2; ++i) {
            PairInfo memory info = _createPairOriented(i == 0);
            vm.warp(hook.getPair(info.id).roundEnd);
            DuelLens.PairView memory neutral = lens.getPair(info.id);
            assertEq(neutral.roundGaugeBps, 5000);
            _assertWinnerMatchesView(neutral, _settleNow(info.id));

            // One wei is an admissible, successfully filled buy. It leaves a one-tick A lead even though a
            // naive basis-point conversion could round it to 5000.
            _buy(alice, info.keyA, 1);
            assertEq(_tick(info.keyD) - _tick(info.keyA), 1);
            vm.warp(hook.getPair(info.id).roundEnd);
            DuelLens.PairView memory tinyLead = lens.getPair(info.id);
            assertTrue(tinyLead.roundTraded);
            assertGt(tinyLead.roundGaugeBps, 5000);
            _assertWinnerMatchesView(tinyLead, _settleNow(info.id));
        }
    }

    function _assertWinnerMatchesView(DuelLens.PairView memory prediction, Settlement memory result) internal pure {
        assertTrue(result.found);
        address expected;
        if (prediction.roundTraded && prediction.roundGaugeBps != 5000) {
            expected = prediction.roundGaugeBps > 5000 ? prediction.a.token : prediction.d.token;
        }
        assertEq(result.winner, expected);
        if (result.averageTick == 0) assertEq(prediction.roundGaugeBps, 5000);
    }

    function _stateDigest(PairInfo memory info) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.getPair(info.id),
                hook.protocolFees(),
                manager.balanceOf(address(hook), 0),
                info.a.totalSupply(),
                info.d.totalSupply(),
                _sqrtPrice(info.keyA),
                _sqrtPrice(info.keyD),
                _sqrtPrice(info.keyX)
            )
        );
    }

    function _applyConfig(DuelFactory.Config memory cfg) internal {
        vm.prank(owner);
        factory.proposeConfig(cfg);
        vm.warp(factory.pendingConfigEta());
        factory.applyConfig();
    }

    /// @dev Configuration extremes are exercised through creation, trading, readings and settlement together,
    ///      instead of checking only the isolated price calculation. All state is reached through public methods.
    function testFuzz_validatedNumericalBoundariesCompose(bool highFdv, bool largeCrossShare, bool maximumFees) public {
        DuelFactory.Config memory cfg = defaultConfig();
        cfg.startFdv = highFdv ? uint96(1000 ether) : uint96(0.1 ether);
        cfg.crossShareBps = largeCrossShare ? 2000 : 200;
        cfg.swapFeeBps = maximumFees ? 200 : 25;
        cfg.switchFeeBps = maximumFees ? 100 : 0;
        cfg.protocolShareBps = 5000;
        cfg.potShareBps = 5000;
        cfg.snipeStartBps = maximumFees ? 9799 : 0;
        cfg.snipeWindow = maximumFees ? 60 : 0;
        _applyConfig(cfg);
        PairInfo memory info = _createPair(0, 0, false);
        // At launch the non-creator pays the full configured anti-snipe tax. The maximum accepted combined rate
        // is 200 + 9799 = 9999 bps: a positive ordinary buy must still fill and leave solvent claims.
        assertEq(hook.snipeTaxBps(info.id), cfg.snipeStartBps);
        uint256 earlyInput = 0.001 ether;
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 balanceBefore = alice.balance;
        uint256 received = _buy(alice, info.keyA, earlyInput);
        assertGt(received, 0);
        assertEq(info.a.balanceOf(alice), received);
        assertEq(balanceBefore - alice.balance, earlyInput);
        DuelHook.Pair memory afterEarlyBuy = hook.getPair(info.id);
        uint256 totalCut = earlyInput * (uint256(cfg.swapFeeBps) + cfg.snipeStartBps) / 10_000;
        assertEq(afterEarlyBuy.volume, earlyInput);
        assertGe(manager.balanceOf(address(hook), 0) - claimsBefore, totalCut);
        assertEq(
            manager.balanceOf(address(hook), 0), hook.protocolFees() + afterEarlyBuy.pot + afterEarlyBuy.creatorFees
        );
        vm.warp(block.timestamp + 61);
        _buy(alice, info.keyA, 0.01 ether);
        _buy(bob, info.keyD, 0.005 ether);
        _sell(alice, info.keyA, info.a.balanceOf(alice) / 10);
        _switch(bob, info, address(info.d), info.d.balanceOf(bob) / 10);
        vm.warp(hook.getPair(info.id).roundEnd);
        DuelLens.PairView memory prediction = lens.getPair(info.id);
        _assertWinnerMatchesView(prediction, _settleNow(info.id));
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + p.pot + p.creatorFees);
        assertLe(p.emaA, int40(p.startTick) * 65_536);
        assertLe(p.emaD, int40(p.startTick) * 65_536);
        assertGt(p.roundEnd, p.lastAccrual);
        assertLe(info.a.totalSupply(), info.a.TOTAL_SUPPLY());
        assertLe(info.d.totalSupply(), info.d.TOTAL_SUPPLY());
    }

    /// @dev Near the documented storage type's upper bound, while leaving four full rounds of representable time.
    ///      The late settlement must retain the actual round count and accrual timestamp, without storage edits.
    function test_numericTimeBoundaryRemainsRepresentable() public {
        PairInfo memory info = _pairWithLeader(false, false);
        DuelHook.Pair memory before = hook.getPair(info.id);
        uint256 when = uint256(type(uint40).max) - 4 * hook.ROUND_LENGTH();
        vm.warp(when);
        hook.settle(info.id);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 expectedRound = (when - before.roundEnd) / hook.ROUND_LENGTH() + 1;
        assertEq(uint256(p.roundIndex), expectedRound);
        assertEq(uint256(p.lastAccrual), when);
        assertLe(p.roundEnd, type(uint40).max);
        assertLt(p.roundStart, p.roundEnd);
        assertLe(p.roundStart, p.lastAccrual);
        assertLt(p.lastAccrual, p.roundEnd);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + p.pot + p.creatorFees);
        assertLe(lens.getPair(info.id).roundGaugeBps, 10_000);
    }

    function test_rejectedNumericalConfigurationIsAtomic() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelFactory.Config memory valid = defaultConfig();
        _applyConfig(valid);
        valid.startFdv = 1 ether;
        vm.prank(owner);
        factory.proposeConfig(valid);
        DuelFactory.Config memory bad = valid;
        bad.startFdv = uint96(1000 ether + 1);
        bytes32 before = keccak256(
            abi.encode(factory.config(), factory.pendingConfig(), factory.pendingConfigEta(), _stateDigest(info))
        );
        vm.prank(owner);
        vm.expectRevert(DuelFactory.InvalidConfig.selector);
        factory.proposeConfig(bad);
        assertEq(
            keccak256(
                abi.encode(factory.config(), factory.pendingConfig(), factory.pendingConfigEta(), _stateDigest(info))
            ),
            before
        );
    }
}
