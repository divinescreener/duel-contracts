// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice A searcher buys the round's winner a second before the close and sells it right after, into the buyback,
///         sized for the most it can take, at every close: two transactions, since a single one settles the round
///         before it buys (DuelSearcher covers those). Measured on the hook itself, with its fees, its pot and the
///         realignment that follows a buyback. With the ceiling at 953 ticks (about 10%), the best-sized searcher
///         takes about 2.3% of what each buyback spends; its buy uses part of the room under the ceiling, so the pot
///         lasts more rounds, but it still runs dry, and searchers competing for that margin earn nothing.
contract DuelBuybackBotTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal searcher = makeAddr("searcher");

    struct Trial {
        uint256 x; // ETH the searcher buys before the close
        int256 profit; // ETH it ends with, less what it put in
        uint256 spent; // ETH the buyback spent
        uint256 pot; // the pot after the settlement
    }

    struct Run {
        uint256 rounds; // closes until the pot holds less than 0.001 ETH
        uint256 spent; // all the buybacks spent
        int256 taken; // what the searcher made in all
        uint256 price; // A's ETH price at the end, 18 decimals
    }

    enum Searcher {
        None,
        BestSized, // the size that pays the most
        Competing // as much as still breaks even: where searchers competing for the margin stop
    }

    function setUp() public override {
        super.setUp();
        vm.deal(searcher, 10_000 ether);
    }

    /// @dev A duel whose pot holds most of a sniper's taxed buy of D at launch, side A leading with `aBuys` ETH, its
    ///      launch round settled.
    function _duel(uint256 sniped, uint256 aBuys) internal returns (PairInfo memory info) {
        info = _launch(sniped, aBuys);
        vm.warp(hook.getPair(info.id).roundEnd);
        hook.settle(info.id);
    }

    /// @dev The same duel in its launch round, which lasts long enough for the EMA to settle on A's price.
    function _launch(uint256 sniped, uint256 aBuys) internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        _buy(bob, info.keyD, sniped);
        // the clock as the chain sees it: via-IR may reuse a block.timestamp read earlier in the same test
        vm.warp(vm.getBlockTimestamp() + 10);
        _buy(alice, info.keyA, aBuys);
        _buy(alice, info.keyD, 0.05 ether);
    }

    /// @dev The ETH side of A's pool, virtual: what moves its price.
    function _reserveA(PairInfo memory info) internal view returns (uint256 eth) {
        (eth,) = DuelMath.virtualReserves(manager.getLiquidity(info.keyA.toId()), _sqrtPrice(info.keyA));
    }

    /// @dev One round: a dust trade at its start makes it count and leaves the 30-minute EMA four hours to settle on
    ///      the price; the searcher buys `x` of A a second before the close and sells it all right after, which
    ///      settles the round first. With `x` zero, anyone settles it.
    function _round(PairInfo memory info, uint256 x) internal returns (Trial memory t) {
        _buy(alice, info.keyA, 0.0001 ether);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 boughtBack = p.buybacks;
        uint256 supply = info.a.totalSupply();
        vm.warp(p.roundEnd - 1);
        uint256 before = searcher.balance;
        uint256 tokens = x == 0 ? 0 : _buy(searcher, info.keyA, x);
        vm.warp(p.roundEnd);
        if (tokens == 0) hook.settle(info.id);
        else _sell(searcher, info.keyA, tokens);
        p = hook.getPair(info.id);
        t = Trial(x, int256(searcher.balance) - int256(before), p.buybacks - boughtBack, p.pot);
        // a buyback burns what it buys: A's supply falling says A won
        assertTrue(t.spent == 0 || info.a.totalSupply() < supply, "A wins every round");
    }

    /// @dev The size that pays the most this round, from 0.1% to 10% of A's ETH (the best is near 2%, breaking even
    ///      near 4%), then finer around it; and the largest size that still breaks even.
    function _sizes(PairInfo memory info) internal returns (Trial memory best, Trial memory edge) {
        uint256 reserve = _reserveA(info);
        for (uint256 x = reserve / 1000; x <= reserve / 10; x = x * 11 / 10) {
            uint256 snapshot = vm.snapshotState();
            Trial memory t = _round(info, x);
            vm.revertToState(snapshot);
            if (t.profit > best.profit) best = t;
            if (t.profit >= 0) edge = t;
        }
        if (best.x == 0) return (best, edge);
        for (uint256 x = best.x * 9 / 10; x <= best.x * 11 / 10; x += best.x / 100) {
            uint256 snapshot = vm.snapshotState();
            Trial memory t = _round(info, x);
            vm.revertToState(snapshot);
            if (t.profit > best.profit) best = t;
        }
    }

    /// @dev Closes until the pot runs dry, with `kind` of searcher at every one; the pot never grows across a buyback.
    function _drain(PairInfo memory info, Searcher kind) internal returns (Run memory r) {
        uint256 potBefore = hook.getPair(info.id).pot;
        while (potBefore >= 0.001 ether && r.rounds < 80) {
            uint256 x;
            if (kind != Searcher.None) {
                (Trial memory best, Trial memory edge) = _sizes(info);
                x = kind == Searcher.BestSized ? best.x : edge.x;
            }
            Trial memory t = _round(info, x);
            assertGt(t.spent, 0, "every close buys back");
            assertLt(t.pot, potBefore, "the pot shrinks at every buyback");
            potBefore = t.pot;
            ++r.rounds;
            r.spent += t.spent;
            r.taken += t.profit;
        }
        r.price = lens.getPair(info.id).a.priceWad;
    }

    /// @dev One close at three depths of A's pool, the pot larger than the ceiling lets a buyback spend: the best-sized
    ///      searcher takes the same small share at every depth, and even competing searchers leave the buyback part of
    ///      its room.
    function test_searcher_takesAFewPercentOfABuyback_atAnyDepth() public {
        vm.pauseGasMetering();
        uint256[3] memory buys = [uint256(0.3 ether), 3.5 ether, 15 ether];
        for (uint256 i = 0; i < buys.length; ++i) {
            PairInfo memory info = _duel(10 ether, buys[i]);
            uint256 reserve = _reserveA(info);
            uint256 snapshot = vm.snapshotState();
            Trial memory alone = _round(info, 0);
            vm.revertToState(snapshot);
            (Trial memory best, Trial memory edge) = _sizes(info);
            console2.log("A's pool ETH, buyback alone, then with the best-sized searcher: its buy, profit, buyback");
            console2.log(reserve, alone.spent);
            console2.log(best.x, uint256(best.profit), best.spent);
            console2.log("competing searchers: their buy, what the buyback spends", edge.x, edge.spent);

            assertLe(uint256(best.profit), best.spent * 25 / 1000, "at most 2.5% of what the buyback spends");
            assertLe(uint256(best.profit), reserve * 8 / 10_000, "at most 0.08% of the pool's ETH");
            assertGt(best.spent, alone.spent / 2, "the buyback keeps most of its room");
            assertGt(edge.spent, alone.spent / 5, "competing searchers leave the buyback a fifth of it");
        }
    }

    /// @dev A holder sells a share of the winner ten minutes before the close: its price sits under its 30-minute EMA.
    ///      Anchored to the EMA alone, the buyback climbed from the lower price all the way up to the band above the
    ///      average, and a searcher buying a second before the close kept 6 to 21% of what it spent (a 10 to 50% dip).
    ///      The reference follows a price down at once: the buyback keeps to its band above the price it finds, and
    ///      the searcher's take stays the few percent it is at an unmoved price.
    function test_searcher_takesNoMore_whenThePriceFellUnderItsAverage() public {
        vm.pauseGasMetering();
        uint256[4] memory sold = [uint256(0), 20, 40, 60];
        for (uint256 i = 0; i < sold.length; ++i) {
            PairInfo memory info = _duel(10 ether, 15 ether);
            uint256 reserve = _reserveA(info);
            Trial memory best;
            for (uint256 x = reserve / 1000; x <= reserve; x = x * 12 / 10) {
                uint256 state = vm.snapshotState();
                Trial memory t = _roundAfterASale(info, x, sold[i]);
                vm.revertToState(state);
                if (t.profit > best.profit) best = t;
            }
            uint256 snapshot = vm.snapshotState();
            Trial memory alone = _roundAfterASale(info, 0, sold[i]);
            vm.revertToState(snapshot);
            console2.log("share of A sold before the close (%), buyback alone, best searcher: buy, profit, buyback");
            console2.log(sold[i], alone.spent);
            console2.log(best.x, uint256(best.profit), best.spent);
            assertLe(uint256(best.profit), best.spent * 25 / 1000, "at most 2.5% of what the buyback spends");
            assertLe(uint256(best.profit), reserve * 8 / 10_000, "at most 0.08% of the pool's ETH");
        }
    }

    /// @dev A round with a sale of `soldShare` percent of alice's A ten minutes before its close, then the searcher's
    ///      buy of `x` a second before it, sold right after; the buyback stays within its band of the price it finds.
    function _roundAfterASale(PairInfo memory info, uint256 x, uint256 soldShare) internal returns (Trial memory t) {
        _buy(alice, info.keyA, 0.0001 ether);
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 boughtBack = p.buybacks;
        vm.warp(p.roundEnd - 10 minutes);
        if (soldShare != 0) _sell(alice, info.keyA, info.a.balanceOf(alice) * soldShare / 100);
        vm.warp(p.roundEnd - 1);
        uint256 before = searcher.balance;
        uint256 tokens = x == 0 ? 0 : _buy(searcher, info.keyA, x);
        int24 found = _tick(info.keyA);
        vm.warp(p.roundEnd);
        if (tokens == 0) hook.settle(info.id);
        else _sell(searcher, info.keyA, tokens);
        p = hook.getPair(info.id);
        t = Trial(x, int256(searcher.balance) - int256(before), p.buybacks - boughtBack, p.pot);
        // the reference is never above the price (a higher tick is a lower price): the buyback climbed at most its
        // band from the price the close found, whatever the average was
        assertGe(DuelMath.emaToTick(p.emaA), found, "the reference sits above the price");
        if (x == 0 && t.spent != 0) assertGe(_tick(info.keyA), found - hook.BUYBACK_MAX_IMPACT_TICKS() - 1);
    }

    /// @dev One wallet with no position buys the leader early in a round, holds while the 30-minute EMA follows its
    ///      price up, sells most of it a second before the close and the rest right after, into the buyback. Anchored
    ///      to the EMA alone, the buyback then climbed back from the dumped price to the band above the pumped
    ///      average: a 10 ETH pump held three hours made 2.4 ETH and spent 6.6 ETH of an 11.5 ETH pot in one round.
    ///      The price pumped and dumped is the reference the buyback finds: it spends about its usual band (0.76 to
    ///      1.14 ETH here), and the pump's two fees eat most of what the held tokens sell into it for: 0.04 to 0.28
    ///      ETH, for 2 to 10 ETH held up to three hours.
    function test_searcher_gainsLittle_fromPumpingHoldingAndDumping() public {
        vm.pauseGasMetering();
        PairInfo memory info = _duel(10 ether, 15 ether);
        uint256 snapshot = vm.snapshotState();
        Trial memory alone = _round(info, 0);
        vm.revertToState(snapshot);
        uint256[3] memory pumps = [uint256(2 ether), 5 ether, 10 ether];
        uint256[3] memory holds = [uint256(30 minutes), 1 hours, 3 hours];
        for (uint256 i = 0; i < pumps.length; ++i) {
            for (uint256 j = 0; j < holds.length; ++j) {
                int256 best;
                uint256 spentAtBest;
                for (uint256 keep = 5; keep <= 95; keep += 5) {
                    snapshot = vm.snapshotState();
                    (int256 profit, uint256 spent) = _pumpHoldDump(info, pumps[i], holds[j], keep);
                    vm.revertToState(snapshot);
                    if (profit > best) (best, spentAtBest) = (profit, spent);
                }
                console2.log("pump, hold (s), best profit, buyback spent", pumps[i], holds[j]);
                console2.log(uint256(best), spentAtBest);
                // what is left: the pump's two fees against a band-sized buyback at a higher price (its ETH side grew
                // with the pump): a quarter of what the buyback spends at most, where it was more than a third of
                // nine times as much
                assertLe(uint256(best) * 10, spentAtBest * 3, "more than three tenths of the buyback");
                assertLe(spentAtBest, alone.spent * 2, "the buyback spent more than twice its usual band");
            }
        }
    }

    function _pumpHoldDump(PairInfo memory info, uint256 pump, uint256 hold, uint256 keepPct)
        internal
        returns (int256 profit, uint256 spent)
    {
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 boughtBack = p.buybacks;
        uint256 before = searcher.balance;
        vm.warp(p.roundEnd - 1 - hold);
        uint256 tokens = _buy(searcher, info.keyA, pump);
        vm.warp(p.roundEnd - 1);
        uint256 kept = tokens * keepPct / 100;
        _sell(searcher, info.keyA, tokens - kept);
        vm.warp(p.roundEnd);
        _sell(searcher, info.keyA, kept);
        profit = int256(searcher.balance) - int256(before);
        spent = hook.getPair(info.id).buybacks - boughtBack;
    }

    /// @dev Once the launch tax is spent the pot fills with a fifth of the swap fees, and its buyback moves the winner's
    ///      price less than a round trip's two fees: no size of buy before the close pays, and the whole pot is spent.
    function test_searcher_earnsNothing_whenTheBuybackMovesLessThanTwoFees() public {
        vm.pauseGasMetering();
        uint256[2] memory sniped = [uint256(0.005 ether), 0.01 ether];
        for (uint256 i = 0; i < sniped.length; ++i) {
            PairInfo memory info = _launch(sniped[i], 0.3 ether);
            uint256 pot = hook.getPair(info.id).pot;
            (Trial memory best,) = _sizes(info);
            console2.log("pot, best searcher profit", pot, uint256(best.profit));
            assertEq(best.profit, 0, "no size pays");
            Trial memory alone = _round(info, 0);
            assertGe(alone.spent, pot, "the buyback spends the whole pot");
        }
    }

    /// @dev Round after round, a searcher at every close slows the pot down but cannot keep it: every close buys back
    ///      and the pot runs dry. The best-sized searcher takes under 2.5% of it in all, however long it carries over,
    ///      in fewer than twice the closes, and A's price ends within 3% of where the buybacks alone leave it.
    ///      Searchers competing for the margin buy more before each close: the buybacks spend less each time (the pot
    ///      lasts up to five times the closes), they keep about 0.5% of it, and their fees go to the creator, the
    ///      protocol and the pot.
    function _everyClose(uint256 aBuys) internal {
        vm.pauseGasMetering();
        PairInfo memory info = _duel(1 ether, aBuys);
        uint256 pot = hook.getPair(info.id).pot;
        uint256 start = vm.snapshotState();
        Run memory alone = _drain(info, Searcher.None);
        vm.revertToState(start);
        start = vm.snapshotState();
        Run memory best = _drain(info, Searcher.BestSized);
        vm.revertToState(start);
        Run memory competing = _drain(info, Searcher.Competing);
        console2.log("A's pool ETH, pot", _reserveA(info), pot);
        console2.log("closes to spend it: alone, best-sized searcher, competing searchers");
        console2.log(alone.rounds, best.rounds, competing.rounds);
        console2.log("searcher took: best-sized, competing", uint256(best.taken), uint256(competing.taken));
        console2.log("A's price at the end: alone, best-sized, competing");
        console2.log(alone.price, best.price, competing.price);

        assertLe(best.rounds, alone.rounds * 2, "the pot runs dry in fewer than twice the closes");
        assertLe(uint256(best.taken), pot * 25 / 1000, "under 2.5% of the pot in all");
        assertLe(uint256(competing.taken), pot / 100, "competing searchers keep under 1% of it");
        assertLe(competing.rounds, alone.rounds * 5, "they make it last at most five times the closes");
        assertGe(competing.price, alone.price * 96 / 100, "A ends within 4% of the buybacks alone");
        assertGe(best.price, alone.price * 97 / 100, "A ends within 3% of the buybacks alone");
        assertGe(best.spent, pot * 99 / 100, "the whole pot is spent");
        assertGe(competing.spent, pot * 99 / 100, "the whole pot is spent");
    }

    function test_searcherAtEveryClose_slowsThePotButCannotKeepIt_youngDuel() public {
        _everyClose(0.3 ether);
    }

    function test_searcherAtEveryClose_slowsThePotButCannotKeepIt_deeperPool() public {
        _everyClose(3.5 ether);
    }
}
