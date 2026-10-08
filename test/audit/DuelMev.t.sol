// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @dev A creator that tries to be paid twice: it claims again, settles and trades from the payment itself.
contract GreedyCreator {
    DuelFactory internal immutable factory;
    DuelHook internal immutable hook;
    uint256 public pairId;
    uint256 public paid;
    uint256 public reentries;

    constructor(DuelFactory _factory, DuelHook _hook) {
        factory = _factory;
        hook = _hook;
    }

    function launch(DuelFactory.CreateParams calldata params) external payable {
        pairId = factory.createPair{value: msg.value}(params);
    }

    function claim() external {
        hook.claimCreatorFees(pairId);
    }

    receive() external payable {
        // the factory's refund at launch is not a payment of fees
        if (msg.sender != address(hook.poolManager())) return;
        paid += msg.value;
        ++reentries;
        try hook.claimCreatorFees(pairId) {} catch {}
        try hook.settle(pairId) {} catch {}
        try hook.claimProtocolFees() {} catch {}
    }
}

/// @dev A treasury that claims again from the protocol's payment.
contract GreedyTreasury {
    DuelHook internal hook;
    uint256 public paid;

    function watch(DuelHook _hook) external {
        hook = _hook;
    }

    receive() external payable {
        paid += msg.value;
        try hook.claimProtocolFees() {} catch {}
    }
}

/// @notice What searchers and attackers try around Duel's pools, fuzzed over sizes and states: sandwiches within a
///         trader's slippage, round trips in one block, a late pump against a banked round, the buyback's band, the
///         anti-snipe tax on every route, reentrant claims and whales. Each test states the bound the defence holds.
contract DuelMevTest is DuelTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");
    /// @dev The app's slippage when the trader picks none (Auto).
    uint256 internal constant SLIPPAGE_BPS = 200;

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 10_000_000 ether);
        vm.deal(victim, 10_000 ether);
    }

    /// @dev A duel past its anti-snipe window, A bought with `a` ETH and D with `d`.
    function _liveDuel(uint256 a, uint256 d) internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        if (a != 0) _buy(alice, info.keyA, a);
        if (d != 0) _buy(bob, info.keyD, d);
    }

    /// @dev What a buy of `ethIn` would give now: the same swap, undone, as the app quotes it.
    function _quoteBuy(PoolKey memory key, uint256 ethIn) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        out = _buy(victim, key, ethIn);
        vm.revertToState(snapshot);
    }

    /// @dev A buy through the Duel router with a minimum: whether it went through, and what it gave.
    function _routerBuy(address user, PoolKey memory key, uint256 ethIn, uint256 minOut)
        internal
        returns (bool ok, uint256 out)
    {
        vm.prank(user);
        try router.swapExactIn{value: ethIn}(key, true, ethIn, minOut, user, block.timestamp) returns (uint256 got) {
            return (true, got);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The ETH the hook holds against everything it owes, for the pairs given.
    function _assertBooksExact(uint256[] memory ids) internal view {
        uint256 owed = hook.protocolFees();
        for (uint256 i = 0; i < ids.length; ++i) {
            DuelHook.Pair memory p = hook.getPair(ids[i]);
            owed += p.pot + p.creatorFees;
        }
        assertEq(manager.balanceOf(address(hook), 0), owed);
    }

    // ------------------------------------------------------------------
    // Sandwiches
    // ------------------------------------------------------------------

    /// @dev The price impact of a buy of `ethIn` on its quote `quoted`, in basis points: how many fewer tokens than the
    ///      spot price after the fee would give (the lens's price: the launch price for a pool sold out of ETH).
    function _impactBps(uint256 pairId, bool sideA, uint256 ethIn, uint256 quoted) internal view returns (uint256) {
        uint256 priceWad = sideA ? lens.getPair(pairId).a.priceWad : lens.getPair(pairId).d.priceWad;
        uint256 ideal = (ethIn * 9880 * 1e18) / (10_000 * priceWad);
        return quoted >= ideal ? 0 : ((ideal - quoted) * 10_000) / ideal;
    }

    /// @dev A searcher buys the side a trader is about to buy, lets the trade run, and sells. The trader's minimum,
    ///      quoted at the app's slippage, holds whatever the front-run: its trade fills at no less, or not at all. And
    ///      around a trade whose price impact is under 1% the sandwich never pays: such a trade lifts the marginal price
    ///      by under 2% (on a constant-product curve the average impact is about half the move), less than the
    ///      searcher's two fees. A larger trade can be sandwiched for up to its own lift less those fees, as on any AMM:
    ///      the app warns from 5%, and a sequencer that orders transactions as they come leaves no mempool to watch.
    function testFuzz_sandwich_ofABuy_neverPaysUnderOnePercent(uint256 a, uint256 d, uint256 front, uint256 size)
        public
    {
        a = bound(a, 0.01 ether, 20 ether);
        d = bound(d, 0.01 ether, 20 ether);
        front = bound(front, 0.0001 ether, 50 ether);
        size = bound(size, 0.0001 ether, 20 ether);
        PairInfo memory info = _liveDuel(a, d);
        uint256 quoted = _quoteBuy(info.keyA, size);
        uint256 minOut = (quoted * (10_000 - SLIPPAGE_BPS)) / 10_000;
        uint256 impact = _impactBps(info.id, true, size, quoted);

        uint256 before = attacker.balance;
        uint256 tokens = _buy(attacker, info.keyA, front);
        (bool ok, uint256 got) = _routerBuy(victim, info.keyA, size, minOut);
        _sell(attacker, info.keyA, tokens);

        if (ok) assertGe(got, minOut, "below the trader's minimum");
        if (impact < 100) assertLt(attacker.balance, before, "a sandwich paid around a small trade");
    }

    /// @dev The same, drawing only trades under a two-hundredth of the pool's ETH (under about 1% of impact): every
    ///      sandwich around them loses, whatever the front-run.
    function testFuzz_sandwich_ofASmallBuy_alwaysLoses(uint256 a, uint256 d, uint256 front, uint256 size) public {
        a = bound(a, 0.01 ether, 20 ether);
        d = bound(d, 0.01 ether, 20 ether);
        front = bound(front, 0.0001 ether, 50 ether);
        PairInfo memory info = _liveDuel(a, d);
        // the pool trades as if it held its virtual reserve (1.68 ETH at launch) and what was paid into it
        size = bound(size, 0.0001 ether, (a + 1.68 ether) / 200);
        uint256 minOut = (_quoteBuy(info.keyA, size) * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 before = attacker.balance;
        uint256 tokens = _buy(attacker, info.keyA, front);
        (bool ok, uint256 got) = _routerBuy(victim, info.keyA, size, minOut);
        _sell(attacker, info.keyA, tokens);
        if (ok) assertGe(got, minOut);
        assertLt(attacker.balance, before);
    }

    /// @dev The same around a sale: the searcher sells first, the trader's sale fills lower, the searcher buys back
    ///      what it sold. The trader's minimum holds; and around a sale under a two-hundredth of the pool's ETH, the
    ///      searcher pays more to buy its tokens back than its sale gave.
    function testFuzz_sandwich_ofASale_neverPaysForSmallSales(uint256 held, uint256 front, uint256 share) public {
        held = bound(held, 0.05 ether, 5 ether);
        front = bound(front, 0.001 ether, 5 ether);
        PairInfo memory info = _liveDuel(1 ether, 1 ether);
        uint256 victimTokens = _buy(victim, info.keyA, held);
        uint256 attackerTokens = _buy(attacker, info.keyA, front);
        vm.warp(block.timestamp + 1 hours);
        // a sale worth at most a two-hundredth of the ETH in the pool
        uint256 pool = lens.getPair(info.id).a.ethReserve;
        uint256 perToken = lens.getPair(info.id).a.priceWad;
        uint256 most = (pool * 1e18) / (200 * perToken);
        uint256 selling = bound(share, 1e15, most < victimTokens ? most : victimTokens);

        uint256 snapshot = vm.snapshotState();
        uint256 quoted = _sell(victim, info.keyA, selling);
        vm.revertToState(snapshot);
        uint256 minOut = (quoted * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 eth = _sell(attacker, info.keyA, attackerTokens);
        _approve(victim, info.keyA);
        vm.startPrank(victim);
        info.a.approve(address(router), type(uint256).max);
        try router.swapExactIn(info.keyA, false, selling, minOut, victim, block.timestamp) returns (uint256 got) {
            assertGe(got, minOut);
        } catch {}
        vm.stopPrank();
        // buying back exactly the tokens sold costs more than the sale gave
        uint256 before = attacker.balance;
        _swap(attacker, info.keyA, true, int256(attackerTokens), eth * 2 + 1 ether);
        assertGt(before - attacker.balance, eth);
    }

    // ------------------------------------------------------------------
    // Round trips
    // ------------------------------------------------------------------

    /// @dev Whatever the route and the size, a round trip in one block gives back less than it took: buying and
    ///      selling a side, switching through the A/D pool and back, switching through ETH and back.
    function testFuzz_roundTrip_inOneBlock_neverPays(uint256 a, uint256 d, uint256 amount, uint8 route) public {
        a = bound(a, 0.01 ether, 5 ether);
        d = bound(d, 0.01 ether, 5 ether);
        amount = bound(amount, 1e9, 100 ether);
        route = uint8(bound(route, 0, 3));
        PairInfo memory info = _liveDuel(a, d);

        if (route < 2) {
            PoolKey memory key = route == 0 ? info.keyA : info.keyD;
            uint256 before = attacker.balance;
            _sell(attacker, key, _buy(attacker, key, amount));
            assertLt(attacker.balance, before);
            return;
        }
        // a switch starts from tokens of A
        uint256 cats = _buy(attacker, info.keyA, amount);
        if (route == 2) {
            uint256 dogs = _switch(attacker, info, address(info.a), cats);
            if (dogs == 0) return;
            uint256 back = _switch(attacker, info, address(info.d), dogs);
            assertLt(back, cats);
        } else {
            _approve(attacker, info.keyA);
            _approve(attacker, info.keyD);
            vm.startPrank(attacker);
            info.a.approve(address(router), type(uint256).max);
            info.d.approve(address(router), type(uint256).max);
            uint256 dogs = router.swapThroughEth(info.keyA, info.keyD, cats, 0, attacker, block.timestamp);
            uint256 back = router.swapThroughEth(info.keyD, info.keyA, dogs, 0, attacker, block.timestamp);
            vm.stopPrank();
            assertLt(back, cats);
        }
    }

    // ------------------------------------------------------------------
    // The triangle
    // ------------------------------------------------------------------

    /// @dev The real ETH of a side's ETH pool: what its holders can be paid with.
    function _ethReserve(uint256 pairId, bool sideA) internal view returns (uint256) {
        return sideA ? lens.getPair(pairId).a.ethReserve : lens.getPair(pairId).d.ethReserve;
    }

    /// @dev What `holder` would get now for all its tokens of `key`'s side, sold through the router.
    function _exitValue(address holder, PoolKey memory key) internal returns (uint256 out) {
        DuelToken token = DuelToken(Currency.unwrap(key.currency1));
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(holder);
        token.approve(address(router), type(uint256).max);
        out = router.swapExactIn(key, false, token.balanceOf(holder), 0, holder, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    /// @dev A triangle's sides, and what the other side's pool and holder had before it.
    struct Triangle {
        PoolKey buyKey;
        PoolKey sellKey;
        address bought;
        address holder;
        uint256 reserve;
        uint256 exit;
        uint256 attackerEth;
        uint256 slack;
    }

    /// @dev An ETH pool's depth: its real ETH and its virtual ETH (the liquidity's, from the launch price), at the
    ///      price it trades from (its launch price once sold out).
    function _depth(uint256 pairId, PoolKey memory key) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint160 launch = TickMath.getSqrtPriceAtTick(hook.getPair(pairId).startTick);
        if (sqrtPrice > launch) sqrtPrice = launch;
        return FullMath.mulDiv(manager.getLiquidity(key.toId()), DuelMath.Q96, sqrtPrice);
    }

    function _triangle(PairInfo memory info, bool fromA) internal returns (Triangle memory t) {
        // alice holds A, bob holds D: the holder is the one of the side sold
        (t.buyKey, t.sellKey, t.bought, t.holder) =
            fromA ? (info.keyA, info.keyD, address(info.a), bob) : (info.keyD, info.keyA, address(info.d), alice);
        t.reserve = _ethReserve(info.id, !fromA);
        t.exit = _exitValue(t.holder, t.sellKey);
        t.attackerEth = attacker.balance;
        // the realignment leaves the three prices out of line by up to its threshold, which one pool's price can take
        // whole: half as much of its depth in ETH. Twice that, as the margin
        t.slack = (_depth(info.id, t.sellKey) * hook.ARB_THRESHOLD_BPS()) / 10_000;
        vm.prank(attacker);
        DuelToken(Currency.unwrap(t.sellKey.currency1)).approve(address(router), type(uint256).max);
    }

    function _runTriangle(PairInfo memory info, Triangle memory t, uint256 amount, uint256 loops) internal {
        for (uint256 i; i < loops; ++i) {
            uint256 other = _switch(attacker, info, t.bought, _buy(attacker, t.buyKey, amount));
            vm.prank(attacker);
            router.swapExactIn(t.sellKey, false, other, 0, attacker, block.timestamp);
        }
    }

    /// @dev The triangle, as many times as asked: a side bought with ETH, switched whole through the A/D pool, and
    ///      the other side sold whole into its ETH pool through the router, pass after pass. Each step moves ETH into
    ///      one ETH pool and out of the other; the realignment after it buys back from the pool what the sale took
    ///      and sends the gap to the pot. It never pays, and it drains nothing: the other side's pool keeps its ETH,
    ///      and that side's holders leave with as much, but for what the realignment leaves out of line under its
    ///      threshold (0.1%): a loop too small to cross it moves a little ETH from one pool to the other, at the
    ///      price of its fees, and the next one that crosses it is realigned.
    function testFuzz_triangle_neverPaysNorDrainsTheOtherSide(
        uint256 a,
        uint256 d,
        uint256 amount,
        uint256 loops,
        bool fromA
    ) public {
        PairInfo memory info = _liveDuel(bound(a, 0.01 ether, 5 ether), bound(d, 0.01 ether, 5 ether));
        Triangle memory t = _triangle(info, fromA);
        _runTriangle(info, t, bound(amount, 1e12, 50 ether), bound(loops, 1, 5));

        assertLt(attacker.balance, t.attackerEth, "the triangle paid");
        assertGe(_ethReserve(info.id, !fromA) + t.slack, t.reserve, "the other side's pool lost ETH");
        assertGe(_exitValue(t.holder, t.sellKey) + t.slack, t.exit, "the other side's holders leave with less");
        uint256[] memory ids = new uint256[](1);
        ids[0] = info.id;
        _assertBooksExact(ids);
    }

    // ------------------------------------------------------------------
    // Rounds
    // ------------------------------------------------------------------

    /// @dev A leader that led all round cannot be overturned in the last quarter hour, at any price: the round counts
    ///      the time-weighted average, and past a few ETH the realignment sends a pump's ETH to the pot.
    function testFuzz_lastMinutePump_cannotOverturnABankedRound(uint256 pump, uint256 secondsLeft) public {
        pump = bound(pump, 0.01 ether, 100_000 ether);
        secondsLeft = bound(secondsLeft, 1, 15 minutes);
        PairInfo memory info = _liveDuel(3 ether, 1 ether);
        vm.warp(hook.getPair(info.id).roundEnd - secondsLeft);
        _buy(attacker, info.keyD, pump);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        assertEq(s.winner, address(info.a));
    }

    /// @dev Moving the prices in the block that settles a round changes nothing: the round is decided by the ticks
    ///      that held until its close, before the swap that settles it runs.
    function test_attack_pumpInTheSettlingBlock_changesNothing() public {
        PairInfo memory info = _liveDuel(3 ether, 1 ether);
        _warpToRoundEnd(info.id);
        vm.recordLogs();
        // the pump itself settles the round, before it moves any price
        uint256 dogs = _buy(attacker, info.keyD, 1000 ether);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertTrue(s.found);
        assertEq(s.winner, address(info.a));
        uint256 before = attacker.balance;
        _sell(attacker, info.keyD, dogs);
        assertLt(attacker.balance - before, 1000 ether);
    }

    /// @dev However the prices moved before the close, the buyback stops at its band: the winner's price ends no more
    ///      than BUYBACK_MAX_IMPACT_TICKS above its EMA, the realignment after it only bringing it back.
    function testFuzz_buyback_neverPastItsBand(uint256 a, uint256 d, uint256 churn, uint256 late, uint256 lead) public {
        a = bound(a, 0.05 ether, 5 ether);
        d = bound(d, 0.05 ether, 5 ether);
        churn = bound(churn, 0, 8);
        late = bound(late, 0, 20 ether);
        lead = bound(lead, 1, 4 hours - 20);
        PairInfo memory info = _liveDuel(a, d);
        // trading fills the pot
        for (uint256 i = 0; i < churn; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            _sell(alice, info.keyA, _buy(alice, info.keyA, 1 ether));
        }
        // a late buy of the leader lifts its price above its EMA
        PoolKey memory leader = a >= d ? info.keyA : info.keyD;
        vm.warp(hook.getPair(info.id).roundEnd - lead);
        if (late != 0) _buy(attacker, leader, late);
        _warpToRoundEnd(info.id);
        Settlement memory s = _settleNow(info.id);
        if (s.spent == 0) return;

        DuelHook.Pair memory p = hook.getPair(info.id);
        bool aWon = s.winner == address(info.a);
        int24 limit = DuelMath.emaToTick(aWon ? p.emaA : p.emaD) - hook.BUYBACK_MAX_IMPACT_TICKS();
        assertGe(_tick(aWon ? info.keyA : info.keyD), limit - 1);
    }

    /// @dev A holder of the winner who settles the round by selling into the buyback takes, above what the same sale
    ///      gave a moment before the close, no more than the pot the buyback spent.
    function testFuzz_sellingIntoTheBuyback_takesNoMoreThanThePot(uint256 held, uint256 share) public {
        held = bound(held, 0.05 ether, 10 ether);
        share = bound(share, 1, 100);
        PairInfo memory info = _liveDuel(3 ether, 1 ether);
        for (uint256 i = 0; i < 6; ++i) {
            vm.warp(block.timestamp + 20 minutes);
            _sell(alice, info.keyA, _buy(alice, info.keyA, 2 ether));
        }
        uint256 tokens = (_buy(attacker, info.keyA, held) * share) / 100;
        vm.warp(hook.getPair(info.id).roundEnd - 1);

        uint256 snapshot = vm.snapshotState();
        uint256 before = attacker.balance;
        _sell(attacker, info.keyA, tokens);
        uint256 beforeClose = attacker.balance - before;
        vm.revertToState(snapshot);

        _warpToRoundEnd(info.id);
        before = attacker.balance;
        vm.recordLogs();
        _sell(attacker, info.keyA, tokens);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        uint256 afterClose = attacker.balance - before;
        assertEq(s.winner, address(info.a));
        if (afterClose > beforeClose) assertLe(afterClose - beforeClose, s.spent);
    }

    /// @dev The first swap after a round's close settles it on its way: the buyback and a realignment. A wallet that
    ///      estimated the swap before the close counts none of that, so the app sends swaps with 500,000 gas of room
    ///      (its settlement headroom): what a settlement adds to a purchase stays well under it,
    ///      for any pot. A sale that finds its side's pool sold out adds the most (test/audit/DuelSaleRoute.t.sol).
    function testFuzz_settlingSwap_staysUnderTheAppsHeadroom(uint256 churn, uint256 idle) public {
        churn = bound(churn, 0, 12);
        idle = bound(idle, 0, 400 days);
        PairInfo memory info = _liveDuel(3 ether, 1 ether);
        for (uint256 i = 0; i < churn; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            _sell(alice, info.keyA, _buy(alice, info.keyA, 2 ether));
        }
        uint256 snapshot = vm.snapshotState();
        uint256 start = gasleft();
        _buy(bob, info.keyA, 0.05 ether);
        uint256 plain = start - gasleft();
        vm.revertToState(snapshot);

        vm.warp(hook.getPair(info.id).roundEnd + idle);
        vm.recordLogs();
        start = gasleft();
        _buy(bob, info.keyA, 0.05 ether);
        uint256 settling = start - gasleft();
        assertTrue(_settlementIn(vm.getRecordedLogs()).found);
        assertLt(settling - plain, 300_000);
    }

    /// @dev A duel left alone for a year settles in one call, in bounded gas: skipped rounds are counted, not walked.
    function test_attack_aYearOfIdleRounds_settlesInBoundedGas() public {
        PairInfo memory info = _liveDuel(1 ether, 1 ether);
        vm.warp(block.timestamp + 365 days);
        uint256 start = gasleft();
        hook.settle(info.id);
        assertLt(start - gasleft(), 700_000);
        assertEq(hook.getPair(info.id).roundIndex, 2190);
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------

    /// @dev In the launch window the anti-snipe tax is the same share of what a buyer pays on every route: an
    ///      exact-input or exact-output swap, the Duel router; past it, nothing.
    function testFuzz_snipeTax_sameOnEveryRoute(uint256 secondsIn, uint256 eth, uint8 route) public {
        secondsIn = bound(secondsIn, 0, 12);
        eth = bound(eth, 0.001 ether, 5 ether);
        route = uint8(bound(route, 0, 2));
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + secondsIn);
        uint256 bps = hook.snipeTaxBps(info.id);

        uint256 before = attacker.balance;
        vm.recordLogs();
        if (route == 0) {
            _buy(attacker, info.keyA, eth);
        } else if (route == 1) {
            vm.prank(attacker);
            router.swapExactIn{value: eth}(info.keyA, true, eth, 0, attacker, block.timestamp);
        } else {
            // tokens worth about `eth` at the launch price, bought exactly; the swap pays what they cost
            _swap(attacker, info.keyA, true, int256(eth * 100_000_000), 1000 * eth + 1 ether);
        }
        uint256 paid = before - attacker.balance;
        (uint256 fee, uint256 tax) = _feeTaken(vm.getRecordedLogs());
        assertApproxEqAbs(tax, (paid * bps) / 10_000, 2 + paid / 1e15);
        assertApproxEqAbs(fee, (paid * 120) / 10_000, 2 + paid / 1e15);
        if (secondsIn >= 10) assertEq(tax, 0);
    }

    function _feeTaken(Vm.Log[] memory logs) internal view returns (uint256 fee, uint256 tax) {
        bytes32 topic = keccak256("FeeTaken(uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) {
                (fee, tax) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    // ------------------------------------------------------------------
    // Router and factory
    // ------------------------------------------------------------------

    /// @dev Whatever a launcher sends, the factory keeps none of it: the fee to the treasury, the launch buys to the
    ///      pools, the rest back to the launcher.
    function testFuzz_launch_keepsNothingAndRefundsTheRest(uint256 extra, uint256 buyA, uint256 buyD) public {
        extra = bound(extra, 0, 100 ether);
        buyA = bound(buyA, 0, 0.05 ether);
        buyD = bound(buyD, 0, 0.05 ether);
        uint256 cost = LAUNCH_FEE + buyA + buyD;
        vm.deal(creator, cost + extra);
        uint256 treasuryBefore = treasury.balance;
        DuelFactory.CreateParams memory params = createParams(buyA, buyD, false);
        vm.prank(creator);
        factory.createPair{value: cost + extra}(params);
        assertEq(creator.balance, extra);
        assertEq(address(factory).balance, 0);
        assertEq(treasury.balance - treasuryBefore, LAUNCH_FEE);
    }

    /// @dev The router keeps nothing, whatever it is sent: a buy paid over its amount gets the rest back, one paid
    ///      under it or past its deadline is refused, a sale sent with ETH gets that ETH back beside its proceeds.
    function testFuzz_router_keepsNothing(uint256 amount, uint256 value, bool sell, bool late) public {
        PairInfo memory info = _liveDuel(1 ether, 1 ether);
        amount = bound(amount, 1e9, 5 ether);
        value = bound(value, 0, 10 ether);
        uint256 cats = _buy(attacker, info.keyA, 1 ether);
        uint256 deadline = late ? block.timestamp - 1 : block.timestamp;
        vm.startPrank(attacker);
        info.a.approve(address(router), type(uint256).max);
        uint256 before = attacker.balance;
        if (late) vm.expectRevert(DuelRouter.Expired.selector);
        else if (!sell && value < amount) vm.expectRevert(DuelRouter.InsufficientValue.selector);
        uint256 got = router.swapExactIn{value: value}(info.keyA, !sell, sell ? cats : amount, 0, attacker, deadline);
        vm.stopPrank();
        assertEq(address(router).balance, 0);
        assertEq(info.a.balanceOf(address(router)), 0);
        if (late || (!sell && value < amount)) {
            assertEq(attacker.balance, before);
        } else if (sell) {
            // the ETH sent comes back with what the sale gave
            assertEq(attacker.balance, before + got);
        } else {
            assertEq(before - attacker.balance, amount);
        }
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @dev A creator contract that claims again, settles and claims the protocol's fees from its own payment is paid
    ///      its fees once: the claim zeroes them first, and the PoolManager is locked while it pays.
    function test_attack_reentrantCreatorClaim_isPaidOnce() public {
        GreedyCreator greedy = new GreedyCreator(factory, hook);
        vm.deal(address(greedy), 1 ether);
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(address(greedy));
        greedy.launch{value: LAUNCH_FEE}(params);
        uint256 id = greedy.pairId();
        vm.warp(block.timestamp + 10);
        PairInfo memory info = _info(id);
        for (uint256 i = 0; i < 5; ++i) {
            _sell(alice, info.keyA, _buy(alice, info.keyA, 1 ether));
        }
        uint256 owed = hook.getPair(id).creatorFees;
        uint256 protocol = hook.protocolFees();
        assertGt(owed, 0);

        greedy.claim();
        assertEq(greedy.paid(), owed);
        assertEq(greedy.reentries(), 1);
        assertEq(hook.getPair(id).creatorFees, 0);
        // the protocol's fees stay the treasury's
        assertEq(hook.protocolFees(), protocol);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _assertBooksExact(ids);
    }

    /// @dev A treasury that claims again from its payment is paid once.
    function test_attack_reentrantTreasury_isPaidOnce() public {
        GreedyTreasury greedy = new GreedyTreasury();
        greedy.watch(hook);
        DuelFactory.Config memory c = defaultConfig();
        c.treasury = address(greedy);
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(block.timestamp + 48 hours);
        factory.applyConfig();

        PairInfo memory info = _liveDuel(1 ether, 1 ether);
        _sell(alice, info.keyA, _buy(alice, info.keyA, 1 ether));
        uint256 owed = hook.protocolFees();
        assertGt(owed, 0);
        // the launch fee reached it already
        uint256 before = greedy.paid();
        hook.claimProtocolFees();
        assertEq(greedy.paid() - before, owed);
        assertEq(hook.protocolFees(), 0);
    }

    // ------------------------------------------------------------------
    // Whales
    // ------------------------------------------------------------------

    /// @dev Trades far larger than the pools, on both sides and through the A/D pool, leave the hook's books exact
    ///      and the whale poorer (nobody trades between its own trades: another's trade can make anyone richer).
    function testFuzz_whales_keepTheBooksExact(uint256 size, uint256 other) public {
        size = bound(size, 1 ether, 1_000_000 ether);
        other = bound(other, 1 ether, 1000 ether);
        PairInfo memory info = _liveDuel(1 ether, 1 ether);
        PairInfo memory quiet = _liveDuel(0.5 ether, 0.2 ether);
        _buy(victim, info.keyD, other);
        uint256 before = attacker.balance;
        uint256 cats = _buy(attacker, info.keyA, size);
        uint256 dogs = _switch(attacker, info, address(info.a), cats / 2);
        _sell(attacker, info.keyA, info.a.balanceOf(attacker));
        _sell(attacker, info.keyD, dogs);
        assertLt(attacker.balance, before);

        uint256[] memory ids = new uint256[](2);
        ids[0] = info.id;
        ids[1] = quiet.id;
        _assertBooksExact(ids);
    }
}
