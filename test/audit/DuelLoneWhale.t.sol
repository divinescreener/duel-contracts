// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice A lone whale against a crowd: the crowd holds side A, one wallet buys side B to take the lead and win the
///         pot, alone on its side, so that nobody can sell into it but the cross pool. Measured on the hook itself,
///         with its fees, its pot and its realignment. The cross pool decides most of it. While A rose, the realignment
///         sold the cross pool's A and stocked B in its place (29% of B's supply on the lopsided pair below); whoever
///         pumps B has that stock sold into its buy, and the ETH it brings buys A back.
///         - In one swap, a buy of the side behind mostly feeds the pot: on a lopsided pair it barely moves the
///           split, whatever its size.
///         - In small swaps the whale takes the lead, but from a dominant side for many times that side's ETH, most
///           of which lifts the leader.
///         - What it lifted, the leader's holders can sell into: if they do while the whale holds, it loses most of
///           it.
///         - On a small pair the window stays open: leading with three times the crowd's ETH, the whale wins every
///           round while the crowd trades, and the pot it collects was filled by the crowd's fees and realignment. It
///           ends ahead or behind by little, and selling crowds still cost it a quarter of its stake.
contract DuelLoneWhaleTest is DuelTestBase {
    /// @dev A lopsided pair, at an ETH of $2,750: A's market cap at $10M, B's at $50K.
    uint256 internal constant LOPSIDED_CAP_A = 3636 ether;
    uint256 internal constant LOPSIDED_CAP_D = 18.18 ether;

    address internal whale = makeAddr("whale");
    address[] internal crowd;
    uint256 internal crowdIn;

    function setUp() public override {
        super.setUp();
        vm.deal(whale, 1_000_000 ether);
    }

    function _cap(DuelLens.SideView memory s) internal pure returns (uint256) {
        return (s.priceWad * s.totalSupply) / 1e18;
    }

    function _crowdBuys(PairInfo memory info, uint256 eth) internal {
        address holder = address(uint160(0x100000 + crowd.length));
        vm.deal(holder, eth);
        _buy(holder, info.keyA, eth);
        crowd.push(holder);
        crowdIn += eth;
    }

    /// @dev The lopsided pair: the crowd buys A 2 ETH at a time, a few buy B 0.05 ETH at a time, a minute apart, until
    ///      both market caps are reached; the round A leads is then settled.
    function _lopsided() internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 11);
        uint256 small;
        while (true) {
            DuelLens.PairView memory v = lens.getPair(info.id);
            if (_cap(v.a) < LOPSIDED_CAP_A) {
                _crowdBuys(info, 2 ether);
            } else if (_cap(v.d) < LOPSIDED_CAP_D) {
                address buyer = address(uint160(0x200000 + small++));
                vm.deal(buyer, 0.05 ether);
                _buy(buyer, info.keyD, 0.05 ether);
            } else {
                break;
            }
            vm.warp(block.timestamp + 60);
        }
        vm.warp(hook.getPair(info.id).roundEnd);
        hook.settle(info.id);
    }

    /// @dev The small pair: 20 holders buy A for 0.5 ETH each, 10 ETH in all.
    function _small() internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 11);
        for (uint256 i = 0; i < 20; ++i) {
            _crowdBuys(info, 0.5 ether);
        }
    }

    /// @dev The whale buys B in steps of `step`, or of 2% of the ETH in B's pool when that is more, until B leads.
    function _takeTheLead(PairInfo memory info, uint256 step) internal returns (uint256 ethIn, uint256 tokens) {
        while (lens.getPair(info.id).gaugeBps >= 5000) {
            uint256 eth = lens.getPair(info.id).d.ethReserve / 50;
            if (eth < step) eth = step;
            tokens += _buy(whale, info.keyD, eth);
            ethIn += eth;
        }
    }

    /// @dev `who` sells its B back in steps of about 2% of the ETH left in B's pool.
    function _leave(PairInfo memory info, address who, uint256 tokens) internal returns (uint256 ethOut) {
        while (tokens > 0) {
            DuelLens.PairView memory v = lens.getPair(info.id);
            uint256 step = (v.d.ethReserve * 1e18) / 50 / v.d.priceWad;
            if (step == 0 || step > tokens) step = tokens;
            ethOut += _sell(who, info.keyD, step);
            tokens -= step;
        }
    }

    /// @dev Every holder of A sells all it holds, in one sale.
    function _crowdSells(PairInfo memory info) internal returns (uint256 ethOut) {
        for (uint256 i = 0; i < crowd.length; ++i) {
            ethOut += _sell(crowd[i], info.keyA, info.a.balanceOf(crowd[i]));
        }
    }

    /// @dev On the lopsided pair, a buy of B in one swap: the realignment sells the cross pool's B into it at the price
    ///      it just paid, and most of its ETH goes to the pot. The split hardly moves, whatever the size.
    function test_oneSwapOnTheSideBehind_mostlyFeedsThePot() public {
        vm.pauseGasMetering();
        PairInfo memory info = _lopsided();
        uint256[2] memory sizes = [uint256(100 ether), 1000 ether];
        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 pot = hook.getPair(info.id).pot;
            _buy(whale, info.keyD, sizes[i]);
            uint256 fed = hook.getPair(info.id).pot - pot;
            uint256 gauge = lens.getPair(info.id).gaugeBps;
            console2.log("one swap of B (ETH), A's share after (bps), ETH it fed the pot");
            console2.log(sizes[i] / 1 ether, gauge, fed / 1e15);
            assertGt(gauge, 9800, "A keeps more than 98%");
            assertGt(fed, sizes[i] * 85 / 100, "more than 85% of the buy goes to the pot");
            vm.revertToState(snapshot);
        }
    }

    /// @dev On the lopsided pair, B leads only once the cross pool's stock of B is sold back and A bought back with the
    ///      whale's ETH: more than twenty times the ETH that separates the two pools, and A's pool ends over ten times
    ///      bigger. Without the coupling, the gap alone would do.
    function test_takingTheLeadFromADominantSide_costsManyTimesItsEth() public {
        vm.pauseGasMetering();
        PairInfo memory info = _lopsided();
        DuelLens.PairView memory before = lens.getPair(info.id);
        uint256 gap = before.a.ethReserve - before.d.ethReserve;
        (uint256 ethIn,) = _takeTheLead(info, 1 ether);
        DuelLens.PairView memory ahead = lens.getPair(info.id);
        console2.log("ETH between the pools before, ETH the whale needed to lead");
        console2.log(gap / 1 ether, ethIn / 1 ether);
        console2.log("A's pool ETH before and after, A's market cap before and after (ETH)");
        console2.log(before.a.ethReserve / 1 ether, ahead.a.ethReserve / 1 ether);
        console2.log(_cap(before.a) / 1 ether, _cap(ahead.a) / 1 ether);
        assertLt(ahead.gaugeBps, 5000, "B leads");
        assertGt(ethIn, gap * 20, "more than twenty times the gap between the pools");
        assertGt(ahead.a.ethReserve, before.a.ethReserve * 10, "A's pool ends over ten times bigger");
    }

    /// @dev Once the whale leads the lopsided pair, A's holders sell everything: the realignment sells the cross
    ///      pool's B into B's pool, now short of tokens, and pays them with its ETH. They leave with over ten times
    ///      what they put in; less than a tenth of the whale's ETH stays in B's pool. Without their sales, the whale
    ///      gets back all but about 4%.
    function test_theLeadersHoldersSellIntoTheWhale() public {
        vm.pauseGasMetering();
        PairInfo memory info = _lopsided();
        (uint256 ethIn, uint256 tokens) = _takeTheLead(info, 1 ether);

        uint256 snapshot = vm.snapshotState();
        uint256 back = _leave(info, whale, tokens);
        console2.log("nobody sells: the whale's ETH in, then back", ethIn / 1 ether, back / 1 ether);
        assertGt(back, ethIn * 95 / 100, "all but about 4%");
        vm.revertToState(snapshot);

        uint256 crowdOut = _crowdSells(info);
        uint256 left = lens.getPair(info.id).d.ethReserve;
        console2.log("A's holders sell everything: their ETH in, then back", crowdIn / 1 ether, crowdOut / 1 ether);
        console2.log("ETH left in B's pool for the whale", left / 1 ether);
        assertGt(crowdOut, crowdIn * 10, "the crowd leaves with over ten times its ETH");
        assertLt(left, ethIn / 10, "less than a tenth of the whale's ETH stays in B's pool");
    }

    /// @dev On the small pair, `who` buys B 0.5 ETH at a time, 30 ETH in all: B leads by more than three to one.
    ///      Returns its tokens and what its trades put in the pot.
    function _leadsTheSmallPair(PairInfo memory info, address who) internal returns (uint256 tokens, uint256 own) {
        uint256 pot = hook.getPair(info.id).pot;
        for (uint256 i = 0; i < 60; ++i) {
            tokens += _buy(who, info.keyD, 0.5 ether);
        }
        own = hook.getPair(info.id).pot - pot;
        assertLt(lens.getPair(info.id).gaugeBps, 2500, "B leads by more than three to one");
    }

    /// @dev Six rounds while the crowd trades A, 10 ETH a round, bought and sold: the rounds whose buyback bought B,
    ///      and what they spent on it.
    function _aTradingDay(PairInfo memory info) internal returns (uint256 wins, uint256 collected) {
        for (uint256 round = 0; round < 6; ++round) {
            for (uint256 k = 0; k < 4; ++k) {
                vm.warp(block.timestamp + 50 minutes);
                _sell(alice, info.keyA, _buy(alice, info.keyA, 1.25 ether));
            }
            _warpToRoundEnd(info.id);
            uint256 supply = info.d.totalSupply();
            uint256 spent = hook.getPair(info.id).buybacks;
            hook.settle(info.id);
            if (info.d.totalSupply() < supply) {
                ++wins;
                collected += hook.getPair(info.id).buybacks - spent;
            }
        }
    }

    /// @dev On the small pair, the whale leads with three times the crowd's ETH and holds a day while the crowd trades
    ///      A: every round buys B back, for many times what the whale's own trades put in the pot. Leaving, it ends
    ///      within 1 ETH of its stake.
    function test_smallPair_theWhaleCollectsATradingCrowdsPot() public {
        vm.pauseGasMetering();
        PairInfo memory info = _small();
        uint256 balance = whale.balance;
        (uint256 tokens, uint256 own) = _leadsTheSmallPair(info, whale);
        (uint256 wins, uint256 collected) = _aTradingDay(info);
        _leave(info, whale, tokens);
        int256 pnl = int256(whale.balance) - int256(balance);
        console2.log("rounds that bought B back, what they spent and what the whale's trades put in the pot (mETH)");
        console2.log(wins, collected / 1e15, own / 1e15);
        console2.log("the whale's result after a day (mETH)");
        console2.logInt(pnl / 1e15);
        assertEq(wins, 6, "every round buys B back");
        assertGt(collected, own * 3, "the crowd filled most of the pot it collects");
        assertGt(pnl, -1 ether, "the whale ends within 1 ETH of its stake");
    }

    /// @dev On the small pair, once the whale leads, the crowd sells everything instead: the crowd gains, the whale
    ///      loses about a quarter of its stake.
    function test_smallPair_aSellingCrowdCostsTheWhale() public {
        vm.pauseGasMetering();
        PairInfo memory info = _small();
        uint256 balance = whale.balance;
        (uint256 tokens,) = _leadsTheSmallPair(info, whale);
        uint256 crowdOut = _crowdSells(info);
        _leave(info, whale, tokens);
        int256 pnl = int256(whale.balance) - int256(balance);
        console2.log("the crowd's result, then the whale's (mETH)");
        console2.logInt((int256(crowdOut) - int256(crowdIn)) / 1e15);
        console2.logInt(pnl / 1e15);
        assertGt(crowdOut, crowdIn, "the crowd gains");
        assertLt(pnl, -5 ether, "the whale loses more than a sixth of its 30 ETH");
    }

    /// @dev The same day, the whale being the duel's creator: a third of every fee comes back to it
    ///      (claimCreatorFees), the crowd's and its own. The crowd's third a creator earns whether it trades or not; its
    ///      own third is what being both adds, about 0.4% of what it trades each way.
    function test_smallPair_aCreatorWhaleGetsItsShareOfTheFeesBack() public {
        vm.pauseGasMetering();
        PairInfo memory info = _small();
        uint256 snapshot = vm.snapshotState();

        uint256 balance = whale.balance;
        (uint256 tokens,) = _leadsTheSmallPair(info, whale);
        _aTradingDay(info);
        _leave(info, whale, tokens);
        int256 plain = int256(whale.balance) - int256(balance);
        uint256 creatorFees = hook.getPair(info.id).creatorFees;
        vm.revertToState(snapshot);

        vm.deal(creator, 1_000_000 ether);
        balance = creator.balance;
        (tokens,) = _leadsTheSmallPair(info, creator);
        _aTradingDay(info);
        _leave(info, creator, tokens);
        vm.prank(creator);
        uint256 claimed = hook.claimCreatorFees(info.id);
        int256 both = int256(creator.balance) - int256(balance);

        console2.log("a day's result (mETH): the plain whale, then the creator as the whale, which claimed");
        console2.logInt(plain / 1e15);
        console2.logInt(both / 1e15);
        console2.log(claimed / 1e15);
        assertEq(claimed, creatorFees, "the same fees, claimed by the creator");
        assertApproxEqAbs(both - plain, int256(claimed), 0.01 ether, "better by what it claimed");
        assertLt(both - plain, 1 ether, "by less than 1 ETH a day on 30 ETH");
    }

    /// @dev `eth` of a side bought in one swap and sold straight back: what the round trip costs, in basis points.
    function _roundTripBps(PoolKey memory key, uint256 eth) internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();
        address trader = makeAddr("trader");
        vm.deal(trader, eth);
        _sell(trader, key, _buy(trader, key, eth));
        uint256 bps = ((eth - trader.balance) * 10_000) / eth;
        vm.revertToState(snapshot);
        return bps;
    }

    /// @dev The round trips the docs give (content/docs/duel/concepts/realignment.md), bought in one swap and sold
    ///      straight back, at 0.1, 1, 5 and 20 ETH: on a fresh pair, then on the small pair, where A holds 97% of the
    ///      split, buying the side ahead and the side behind. Behind, the realignment sells the cross pool's stock of B
    ///      into the buy; ahead, it has little of A left to sell.
    function test_roundTrips_freshAndLopsided() public {
        vm.pauseGasMetering();
        uint256[4] memory sizes = [uint256(0.1 ether), 1 ether, 5 ether, 20 ether];
        PairInfo memory fresh = _createPair(0, 0, false);
        vm.warp(block.timestamp + 11);
        PairInfo memory small = _small();
        console2.log("round trip (bps): size (0.01 ETH), fresh pair, then at 97/3 the side ahead and the side behind");
        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 freshBps = _roundTripBps(fresh.keyD, sizes[i]);
            uint256 ahead = _roundTripBps(small.keyA, sizes[i]);
            uint256 behind = _roundTripBps(small.keyD, sizes[i]);
            console2.log(sizes[i] / 1e16, freshBps, ahead, behind);
            if (sizes[i] >= 1 ether) assertGt(behind, ahead * 2, "behind costs more than twice the side ahead");
        }
        assertApproxEqAbs(_roundTripBps(fresh.keyD, 1 ether), 500, 100, "about 5% for 1 ETH on a fresh pair");
        assertApproxEqAbs(_roundTripBps(fresh.keyD, 20 ether), 2200, 300, "about 22% for 20 ETH on a fresh pair");
    }
}
