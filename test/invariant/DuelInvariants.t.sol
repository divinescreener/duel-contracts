// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice Random traders on two pairs: buys and sells (exact input and output, through the test router and the Duel
///         router), switches, time passing, settlements and claims, with the realignment stopping and starting again,
///         and the factory's owner moving the protocol's rate.
contract DuelHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    DuelHook internal immutable hook;
    DuelRouter internal immutable router;
    PoolSwapTest internal immutable swapRouter;
    uint256[] public pairIds;
    address[] internal traders;
    /// @notice Swaps that went through, by kind: a run where nothing trades proves nothing.
    uint256 public swapsDone;
    uint256 public exactOutputsDone;
    uint256 public routerTradesDone;
    uint256 public switchesThroughEthDone;
    /// @notice Sales through the other side (the router's `sell`) that went through, those that reverted and those that
    ///         left tokens they were asked to sell: a holder must always be able to leave, with everything.
    uint256 public salesThroughTheOtherSideDone;
    uint256 public saleFailures;
    uint256 public saleShortfalls;
    uint256 public claimsDone;
    uint256 public creatorsHandedOver;
    /// @notice Pairs whose creator gave its share of the fees to come to the pots, the creator fees each owed then, and
    ///         the times one owed more afterwards or was no longer a supporter pair.
    uint256 public creatorFeesGivenUp;
    mapping(uint256 pairId => bool) public gaveUp;
    mapping(uint256 pairId => uint256) public owedWhenGivenUp;
    uint256 public givenUpMismatches;
    uint256 public creatorClaimsAttempted;
    uint256 public protocolClaimsAttempted;
    uint256 public protocolClaimsDone;
    uint256 public creatorEthPaid;
    uint256 public protocolEthPaid;
    uint256 public actionsWithoutEffect;
    uint256 public interceptedFailures;
    uint256 public payoutMismatches;
    uint256 public creatorHandoverMismatches;
    uint256 public supplyIncreases;
    uint256 public burnAccountingMismatches;
    uint256 public supplyTransitionsChecked;
    uint256 public positiveBurnsChecked;
    /// @notice Settlements checked against the ghost oracle below, and those that disagreed with it.
    uint256 public settlementsChecked;
    uint256 public settlementMismatches;
    /// @notice `settle` calls that reverted: a settlement must never fail, or every swap of the pair would.
    uint256 public settleFailures;
    /// @notice Times a pair's round index went backwards.
    uint256 public roundsBackwards;
    /// @notice Times the cross pool disagreed with the ETH price ratio used by the oracle.
    uint256 public crossDisagreements;
    /// @notice Rates the owner set, those the hook did not keep as asked, and actions whose fees gave the protocol
    ///         other than its rate of its terms' share.
    uint256 public ratesSet;
    uint256 public rateMismatches;
    uint256 public protocolTakeMismatches;

    bytes32 internal constant ROUND_SETTLED = keccak256("RoundSettled(uint256,uint32,int24,address,uint256,uint256)");
    bytes32 internal constant SWITCH_FEE_BURNED = keccak256("SwitchFeeBurned(uint256,address,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256,uint256)");

    /// @dev What the protocol was owed and paid before an action, and its rate then.
    struct Ledger {
        uint256 owed;
        uint256 paid;
        uint256 rate;
    }

    /// @dev The ETH price-ratio tick of each pair over time, kept apart from the hook's own accumulator: every tick change
    ///      happens inside a handler call, so the tick is known at every second.
    struct TickPoint {
        uint256 time;
        int24 tick;
    }

    mapping(uint256 pairId => TickPoint[]) internal history;
    mapping(uint256 pairId => uint32) internal lastRound;

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
        for (uint256 i = 0; i < ids.length; ++i) {
            (int24 tick,) = _ethRatioTick(ids[i]);
            history[ids[i]].push(TickPoint(block.timestamp, tick));
        }
    }

    /// @dev Checks every settlement an action caused against the ghost oracle, then records the ticks it left.
    modifier recorded() {
        uint256 n = pairIds.length;
        DuelHook.Pair[] memory before = new DuelHook.Pair[](n);
        uint256[2][] memory supplies = new uint256[2][](n);
        for (uint256 i = 0; i < n; ++i) {
            before[i] = hook.getPair(pairIds[i]);
            supplies[i][0] = IERC20(before[i].tokenA).totalSupply();
            supplies[i][1] = IERC20(before[i].tokenD).totalSupply();
        }
        Ledger memory ledger = Ledger(hook.protocolFees(), protocolEthPaid, hook.protocolRateBps());
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkProtocolTake(before, logs, ledger);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != ROUND_SETTLED) continue;
            uint256 pairId = uint256(logs[i].topics[1]);
            for (uint256 j = 0; j < n; ++j) {
                if (pairIds[j] == pairId) _check(pairId, before[j], logs[i]);
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            uint256 pairId = pairIds[i];
            _checkSupply(before[i].tokenA, supplies[i][0], logs);
            _checkSupply(before[i].tokenD, supplies[i][1], logs);
            TickPoint[] storage points = history[pairId];
            (int24 tick, bool differs) = _ethRatioTick(pairId);
            if (differs) ++crossDisagreements;
            if (points[points.length - 1].time == block.timestamp) points[points.length - 1].tick = tick;
            else if (points[points.length - 1].tick != tick) points.push(TickPoint(block.timestamp, tick));
            if (gaveUp[pairId]) {
                DuelHook.Pair memory given = hook.getPair(pairId);
                if (!given.supporter || given.creatorFees > owedWhenGivenUp[pairId]) ++givenUpMismatches;
                owedWhenGivenUp[pairId] = given.creatorFees;
            }
            uint32 round = hook.getPair(pairId).roundIndex;
            if (round < lastRound[pairId]) ++roundsBackwards;
            lastRound[pairId] = round;
        }
    }

    /// @dev Of each fee an action took, the protocol got its rate of the share its pair's terms give it, to the wei: no
    ///      more, whatever the rate, and the rest went elsewhere (the pot, which the hook's ETH invariant accounts for).
    function _checkProtocolTake(DuelHook.Pair[] memory before, Vm.Log[] memory logs, Ledger memory ledger) internal {
        uint256 expected;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FEE_TAKEN) continue;
            uint256 pairId = uint256(logs[i].topics[1]);
            (uint256 fee,) = abi.decode(logs[i].data, (uint256, uint256));
            for (uint256 j = 0; j < before.length; ++j) {
                if (pairIds[j] == pairId) {
                    expected += (fee * before[j].fees.protocolShareBps / 10_000) * ledger.rate / 10_000;
                }
            }
        }
        if (hook.protocolFees() + (protocolEthPaid - ledger.paid) != ledger.owed + expected) ++protocolTakeMismatches;
    }

    /// @dev Check each successive supply, then attribute its entire decrease to protocol operations. ERC20 burn
    ///      transfers are checked against both supply changes and separate hook reason events; no holder burn or
    ///      token deployment is an action of this closed handler. This is not merely a check against launch supply.
    function _checkSupply(address token, uint256 before, Vm.Log[] memory logs) internal {
        ++supplyTransitionsChecked;
        uint256 after_ = IERC20(token).totalSupply();
        if (after_ > before) {
            ++supplyIncreases;
            return;
        }
        uint256 transfersBurned;
        uint256 explainedBurned;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == token && log.topics.length == 3 && log.topics[0] == TRANSFER) {
                if (log.topics[2] == bytes32(0)) transfersBurned += abi.decode(log.data, (uint256));
            }
            if (log.emitter != address(hook) || log.topics.length == 0) continue;
            if (log.topics[0] == SWITCH_FEE_BURNED && address(uint160(uint256(log.topics[2]))) == token) {
                explainedBurned += abi.decode(log.data, (uint256));
            } else if (log.topics[0] == ROUND_SETTLED) {
                (, address winner,, uint256 burned) = abi.decode(log.data, (int24, address, uint256, uint256));
                if (winner == token) explainedBurned += burned;
            }
        }
        uint256 decrease = before - after_;
        if (decrease != transfersBurned || decrease != explainedBurned) ++burnAccountingMismatches;
        if (decrease != 0) ++positiveBurnsChecked;
    }

    /// @dev The settled round is the one that was running before the action: its average from the ghost's ticks, and
    ///      its winner from that average and whether anyone traded in it.
    function _check(uint256 pairId, DuelHook.Pair memory p, Vm.Log memory log) internal {
        ++settlementsChecked;
        (int24 averageTick, address winner,,) = abi.decode(log.data, (int24, address, uint256, uint256));
        int256 expected = _integral(pairId, p.roundStart, p.roundEnd) / int256(uint256(p.roundEnd - p.roundStart));
        address expectedWinner;
        if (p.roundTraded && expected != 0) {
            expectedWinner = (expected > 0) == p.aIsCurrency0 ? p.tokenA : p.tokenD;
        }
        if (uint32(uint256(log.topics[2])) != p.roundIndex || averageTick != expected || winner != expectedWinner) {
            ++settlementMismatches;
        }
    }

    /// @dev The ETH price-ratio tick integrated over [from, to], from the recorded history.
    function _integral(uint256 pairId, uint256 from, uint256 to) internal view returns (int256 sum) {
        TickPoint[] storage points = history[pairId];
        for (uint256 i = 0; i < points.length; ++i) {
            uint256 start = points[i].time > from ? points[i].time : from;
            uint256 end = i + 1 < points.length && points[i + 1].time < to ? points[i + 1].time : to;
            if (end > start) sum += int256(points[i].tick) * int256(end - start);
        }
    }

    /// @dev Independent ETH oracle: the effective ETH pool ticks subtract, with the cross pool used only to count
    ///      observed disagreements. Its price never enters the history or expected settlement.
    function _ethRatioTick(uint256 pairId) internal view returns (int24 tick, bool differs) {
        (PoolKey memory keyA, PoolKey memory keyD, PoolKey memory keyX) = hook.poolKeys(pairId);
        DuelHook.Pair memory p = hook.getPair(pairId);
        (, int24 tickX,,) = manager.getSlot0(keyX.toId());
        (, int24 tickA,,) = manager.getSlot0(keyA.toId());
        (, int24 tickD,,) = manager.getSlot0(keyD.toId());
        int256 priceA = tickA > p.startTick ? p.startTick : tickA;
        int256 priceD = tickD > p.startTick ? p.startTick : tickD;
        int256 ratio = p.aIsCurrency0 ? priceD - priceA : priceA - priceD;
        return (int24(ratio), ratio != tickX);
    }

    function pairCount() external view returns (uint256) {
        return pairIds.length;
    }

    function _pick(uint256 seed) internal view returns (uint256 pairId, address trader, PoolKey[3] memory keys) {
        pairId = pairIds[seed % pairIds.length];
        trader = traders[(seed / 7) % traders.length];
        (keys[0], keys[1], keys[2]) = hook.poolKeys(pairId);
    }

    function _approveAll(address trader, PoolKey memory key) internal {
        vm.startPrank(trader);
        for (uint256 i = 0; i < 2; ++i) {
            address token = Currency.unwrap(i == 0 ? key.currency0 : key.currency1);
            if (token != address(0)) {
                IERC20(token).approve(address(swapRouter), type(uint256).max);
                IERC20(token).approve(address(router), type(uint256).max);
            }
        }
        vm.stopPrank();
    }

    function _testSwap(address trader, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
    {
        _approveAll(trader, key);
        vm.prank(trader);
        try swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ++swapsDone;
            if (amountSpecified > 0) ++exactOutputsDone;
        } catch {
            // Foundry records logs even from a call that reverted. The entire swap rolled back; its recorded
            // settlement/burn events must not enter the ghost oracle or the supply ledger.
            vm.getRecordedLogs();
            ++interceptedFailures;
        }
    }

    function buy(uint256 seed, uint256 eth, bool exactOutput) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        eth = bound(eth, 1000, 20 ether);
        if (!exactOutput) return _testSwap(trader, key, true, -int256(eth), eth);
        // tokens worth about `eth` at launch prices: at most a fifth of the pool, paying up to 100x
        uint256 tokens = bound(eth * 500_000_000, 1e9, 150_000_000 ether);
        _testSwap(trader, key, true, int256(tokens), 100 * eth + 1 ether);
    }

    function sell(uint256 seed, uint256 share, bool exactOutput) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        uint256 balance = IERC20(Currency.unwrap(key.currency1)).balanceOf(trader);
        uint256 amount = (balance * bound(share, 1, 100)) / 100;
        if (amount == 0) {
            ++actionsWithoutEffect;
            return;
        }
        if (!exactOutput) return _testSwap(trader, key, false, -int256(amount), 0);
        _testSwap(trader, key, false, int256(bound(share, 1, 100) * 0.001 ether), 0);
    }

    function switchSides(uint256 seed, uint256 share, bool exactOutput) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        bool zeroForOne = (seed / 11) % 2 == 0;
        address input = Currency.unwrap(zeroForOne ? keys[2].currency0 : keys[2].currency1);
        uint256 amount = (IERC20(input).balanceOf(trader) * bound(share, 1, 100)) / 100;
        if (amount == 0) {
            ++actionsWithoutEffect;
            return;
        }
        _testSwap(trader, keys[2], zeroForOne, exactOutput ? int256(amount / 2) : -int256(amount), 0);
    }

    function trade(uint256 seed, uint256 eth, bool sellIt) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        PoolKey memory key = keys[(seed / 3) % 2];
        _approveAll(trader, key);
        vm.startPrank(trader);
        if (sellIt) {
            uint256 amount = IERC20(Currency.unwrap(key.currency1)).balanceOf(trader) / 2;
            if (amount != 0) {
                try router.swapExactIn(key, false, amount, 0, trader, block.timestamp) {
                    ++routerTradesDone;
                } catch {
                    vm.getRecordedLogs();
                    ++interceptedFailures;
                }
            } else {
                ++actionsWithoutEffect;
            }
        } else {
            eth = bound(eth, 1000, 10 ether);
            try router.swapExactIn{value: eth}(key, true, eth, 0, trader, block.timestamp) {
                ++routerTradesDone;
            } catch {
                vm.getRecordedLogs();
                ++interceptedFailures;
            }
        }
        vm.stopPrank();
    }

    /// @notice A switch by the ETH pools, through the router: one side sold for ETH and all of it spent on the other.
    function switchThroughEth(uint256 seed, uint256 share) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        uint256 from = (seed / 3) % 2;
        _approveAll(trader, keys[from]);
        uint256 amount = (IERC20(Currency.unwrap(keys[from].currency1)).balanceOf(trader) * bound(share, 1, 100)) / 100;
        if (amount == 0) {
            ++actionsWithoutEffect;
            return;
        }
        vm.prank(trader);
        try router.swapThroughEth(keys[from], keys[1 - from], amount, 0, trader, block.timestamp) {
            ++switchesThroughEthDone;
        } catch {
            vm.getRecordedLogs();
            ++interceptedFailures;
        }
    }

    /// @notice A sale through the router's `sell`: into the side's own pool, then what that pool cannot buy back through
    ///         the pool between the sides into the other side's. Whatever the pools' state, it goes and takes it all.
    function sellOut(uint256 seed, uint256 share) external recorded {
        (, address trader, PoolKey[3] memory keys) = _pick(seed);
        uint256 from = (seed / 3) % 2;
        _approveAll(trader, keys[from]);
        IERC20 token = IERC20(Currency.unwrap(keys[from].currency1));
        uint256 balance = token.balanceOf(trader);
        uint256 amount = (balance * bound(share, 1, 100)) / 100;
        if (amount == 0) {
            ++actionsWithoutEffect;
            return;
        }
        vm.prank(trader);
        try router.sell(keys[from], keys[2], keys[1 - from], amount, 0, trader, block.timestamp) {
            ++salesThroughTheOtherSideDone;
            if (balance - token.balanceOf(trader) != amount) ++saleShortfalls;
        } catch {
            vm.getRecordedLogs();
            ++saleFailures;
        }
    }

    /// @notice The realignment stops, or runs again: stopped, a switch leaves the cross pool apart from the ETH prices.
    function realignment(bool on) external recorded {
        if (on) vm.clearMockedCalls();
        else vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
    }

    function wait(uint256 seconds_) external recorded {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    /// @notice A duel nobody touches for days or weeks: idle rounds, then a late settlement.
    function sleep(uint256 days_, uint256 seconds_) external recorded {
        vm.warp(block.timestamp + bound(days_, 2, 30) * 1 days + bound(seconds_, 0, 1 days - 1));
    }

    function settle(uint256 seed) external recorded {
        uint256 pairId = pairIds[seed % pairIds.length];
        uint32 before = hook.getPair(pairId).roundIndex;
        try hook.settle(pairId) {
            if (hook.getPair(pairId).roundIndex == before) ++actionsWithoutEffect;
        } catch {
            ++settleFailures;
            ++interceptedFailures;
        }
    }

    function claimCreatorFees(uint256 seed) external recorded {
        ++creatorClaimsAttempted;
        uint256 pairId = pairIds[seed % pairIds.length];
        DuelHook.Pair memory before = hook.getPair(pairId);
        uint256 balance = before.creator.balance;
        try hook.claimCreatorFees(pairId) returns (uint256 amount) {
            ++claimsDone;
            creatorEthPaid += amount;
            if (
                amount == 0 || amount != before.creatorFees || before.creator.balance != balance + amount
                    || hook.getPair(pairId).creatorFees != 0
            ) ++payoutMismatches;
        } catch {
            ++interceptedFailures;
        }
    }

    function claimProtocolFees() external recorded {
        ++protocolClaimsAttempted;
        address to = DuelFactory(hook.factory()).treasury();
        uint256 before = hook.protocolFees();
        uint256 balance = to.balance;
        try hook.claimProtocolFees() returns (uint256 amount) {
            ++protocolClaimsDone;
            protocolEthPaid += amount;
            if (amount == 0 || amount != before || to.balance != balance + amount || hook.protocolFees() != 0) {
                ++payoutMismatches;
            }
        } catch {
            ++interceptedFailures;
        }
    }

    /// @dev The factory's owner moves the protocol's rate, at once, for both pairs: up to the whole share of their terms,
    ///      and a rate above it is refused.
    function protocolRate(uint256 rate) external recorded {
        DuelFactory factory = DuelFactory(hook.factory());
        rate = bound(rate, 0, 12_000);
        vm.prank(factory.owner());
        try factory.setProtocolRate(uint16(rate)) {
            if (rate > 10_000 || hook.protocolRateBps() != rate) ++rateMismatches;
            else ++ratesSet;
        } catch {
            vm.getRecordedLogs();
            if (rate <= 10_000) ++rateMismatches;
            else ++interceptedFailures;
        }
    }

    /// @notice A pair's creator gives its share of the fees to come to the pots, for good: once a creator has claimed,
    ///         so that a run still pays one. The creator fees it owes can only fall from then on, claim after claim.
    function giveUpCreatorFees(uint256 seed) external recorded {
        uint256 pairId = pairIds[seed % pairIds.length];
        DuelHook.Pair memory before = hook.getPair(pairId);
        if (claimsDone == 0 || before.supporter) {
            ++actionsWithoutEffect;
            return;
        }
        vm.prank(before.creator);
        hook.giveUpCreatorFees(pairId);
        gaveUp[pairId] = true;
        owedWhenGivenUp[pairId] = before.creatorFees;
        ++creatorFeesGivenUp;
    }

    /// @dev The creator role handed to a trader, who accepts it: the fees not yet claimed go with it, and the hook still
    ///      owes exactly what it did.
    function handOverCreator(uint256 seed, uint256 to) external recorded {
        uint256 pairId = pairIds[seed % pairIds.length];
        DuelFactory factory = DuelFactory(hook.factory());
        DuelHook.Pair memory before = hook.getPair(pairId);
        uint256 index = to % traders.length;
        address next = traders[index];
        // Reaccepting one's own role is a permitted no-op, but must not stand in for an actual role transfer.
        if (next == before.creator) next = traders[(index + 1) % traders.length];
        vm.prank(before.creator);
        factory.transferCreator(pairId, next);
        vm.prank(next);
        factory.acceptCreator(pairId);
        DuelHook.Pair memory after_ = hook.getPair(pairId);
        if (
            after_.creator != next || after_.creator == before.creator || after_.creatorFees != before.creatorFees
                || factory.pendingCreator(pairId) != address(0)
        ) ++creatorHandoverMismatches;
        else ++creatorsHandedOver;
    }
}

/// @notice What must hold whatever traders do: the hook's ETH covers exactly what it owes, nothing is left behind in
///         the hook, the factory or the router, and supplies only shrink.
contract DuelInvariantsTest is DuelTestBase {
    DuelHandler internal handler;
    uint256[] internal ids;

    function setUp() public override {
        super.setUp();
        ids.push(_createPair(0.02 ether, 0, false).id);
        ids.push(_createPair(0.01 ether, 0.01 ether, true).id);
        handler = new DuelHandler(manager, hook, router, swapRouter, ids);
        targetContract(address(handler));
    }

    /// @dev Each run must have traded, both ways of specifying a swap, and claimed.
    function afterInvariant() public view {
        assertGt(handler.swapsDone(), 0);
        assertGt(handler.exactOutputsDone(), 0);
        assertGt(handler.routerTradesDone(), 0);
        assertGt(handler.switchesThroughEthDone(), 0);
        assertGt(handler.salesThroughTheOtherSideDone(), 0);
        assertGt(handler.settlementsChecked(), 0);
        assertGt(handler.claimsDone(), 0);
        assertGt(handler.creatorEthPaid(), 0);
        assertGt(handler.protocolClaimsDone(), 0);
        assertGt(handler.protocolEthPaid(), 0);
        assertGt(handler.creatorsHandedOver(), 0);
        assertGt(handler.positiveBurnsChecked(), 0);
        assertGt(handler.ratesSet(), 0);
        console2.log("successful creator claims:", handler.claimsDone());
        console2.log("successful protocol claims:", handler.protocolClaimsDone());
        console2.log("completed creator handovers:", handler.creatorsHandedOver());
        console2.log("actions with no effect:", handler.actionsWithoutEffect());
        console2.log("intercepted failures:", handler.interceptedFailures());
        console2.log("cross pool disagreed with the ETH oracle, times:", handler.crossDisagreements());
    }

    function invariant_hookEthCoversExactlyWhatItOwes() public view {
        uint256 owed = hook.protocolFees();
        for (uint256 i = 0; i < ids.length; ++i) {
            DuelHook.Pair memory p = hook.getPair(ids[i]);
            owed += p.pot + p.creatorFees;
        }
        assertEq(manager.balanceOf(address(hook), 0), owed);
    }

    function invariant_theProtocolTakesItsRateOfItsTermsAndNoMore() public view {
        assertEq(handler.protocolTakeMismatches(), 0);
        assertEq(handler.rateMismatches(), 0);
        assertLe(hook.protocolRateBps(), 10_000);
    }

    function invariant_nothingIsLeftBehind() public view {
        assertEq(address(hook).balance, 0);
        assertEq(address(factory).balance, 0);
        assertEq(address(router).balance, 0);
        for (uint256 i = 0; i < ids.length; ++i) {
            DuelHook.Pair memory p = hook.getPair(ids[i]);
            for (uint256 j = 0; j < 2; ++j) {
                IERC20 token = IERC20(j == 0 ? p.tokenA : p.tokenD);
                assertEq(token.balanceOf(address(hook)), 0);
                assertEq(token.balanceOf(address(factory)), 0);
                assertEq(token.balanceOf(address(router)), 0);
                assertLe(token.totalSupply(), 1_000_000_000 ether);
            }
        }
    }

    function invariant_roundsAndOracleStayInOrder() public view {
        for (uint256 i = 0; i < ids.length; ++i) {
            DuelHook.Pair memory p = hook.getPair(ids[i]);
            assertLe(p.lastAccrual, block.timestamp);
            assertLt(p.roundStart, p.roundEnd);
            assertLe(p.emaA, int40(p.startTick) * 65_536);
            assertLe(p.emaD, int40(p.startTick) * 65_536);
            // the oracle never runs past a close without settling the round
            assertLt(p.lastAccrual, p.roundEnd);
            assertLe(p.roundStart, p.lastAccrual);
            // rounds end on the four-hour boundaries, one round apart, counted from the first one
            uint256 round = hook.ROUND_LENGTH();
            assertEq(p.roundEnd % round, 0);
            assertEq(p.roundEnd, hook.firstRoundEnd(p.launchTime) + uint256(p.roundIndex) * round);
            assertEq(p.roundStart, p.roundIndex == 0 ? p.launchTime : p.roundEnd - round);
        }
        assertEq(handler.roundsBackwards(), 0);
    }

    /// @dev Every settlement matches a tick average computed apart from the hook, and none ever fails.
    function invariant_settlementsMatchTheGhostOracle() public view {
        assertEq(handler.settlementMismatches(), 0);
        assertEq(handler.settleFailures(), 0);
    }

    function invariant_eachSupplyDecreaseHasAnAttributedBurn() public view {
        assertEq(handler.supplyIncreases(), 0);
        assertEq(handler.burnAccountingMismatches(), 0);
    }

    function invariant_aSaleThroughTheOtherSideAlwaysGoesAndTakesItAll() public view {
        assertEq(handler.saleFailures(), 0);
        assertEq(handler.saleShortfalls(), 0);
    }

    function invariant_aCreatorsShareGivenUpNeverComesBack() public view {
        assertEq(handler.givenUpMismatches(), 0);
    }

    function invariant_paymentsAndCreatorHandoversActuallyMatch() public view {
        assertEq(handler.payoutMismatches(), 0);
        assertEq(handler.creatorHandoverMismatches(), 0);
    }
}
