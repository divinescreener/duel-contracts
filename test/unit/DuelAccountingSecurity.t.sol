// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @dev A controlled delivery failure, with no external calls or reentrancy.
contract AccountingPaymentReceiver {
    bool public rejects = true;

    function allowPayment() external {
        rejects = false;
    }

    receive() external payable {
        require(!rejects, "controlled payment refusal");
    }
}

/// @notice Defensive accounting checks for ordinary, locally deployed Duel pools.
/// @dev The ghost ledger consumes fees, settlements and payments from events, rather than seeding its balances from
///      the hook's accounting fields. Separate ERC-6909 movements and ERC-20 burns cross-check those events.
///      This proves reconciliation for the exercised Duel operations, not solvency of every asset/reserve of a shared
///      PoolManager, correctness of arbitrage economics, or universal coverage of every reachable EVM state.
contract DuelAccountingSecurityTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256,uint256)");
    bytes32 private constant SWITCH_BURNED = keccak256("SwitchFeeBurned(uint256,address,uint256)");
    bytes32 private constant CREATOR_PAID = keccak256("CreatorFeesClaimed(uint256,address,uint256)");
    bytes32 private constant PROTOCOL_PAID = keccak256("ProtocolFeesClaimed(address,uint256)");
    bytes32 private constant CREATOR_CHANGED = keccak256("CreatorChanged(uint256,address,address)");
    bytes32 private constant CLAIM_TRANSFER = keccak256("Transfer(address,address,address,uint256,uint256)");
    bytes32 private constant TOKEN_TRANSFER = keccak256("Transfer(address,address,uint256)");

    struct Ledger {
        uint256 pot;
        uint256 creatorOwed;
        uint256 spent;
        address creator;
        uint16 protocolShare;
        uint16 potShare;
        bool supporter;
    }

    mapping(uint256 => Ledger) private ledger;
    mapping(address => uint256) private burned;
    mapping(address => uint256) private burnTransfers;
    mapping(address => uint256) private seedDustBurned;
    uint256[] private tracked;
    uint256 private protocolOwed;
    uint256 private claimReceipts;
    uint256 private claimPayments;
    uint256 private unsolicitedClaims;
    uint256 private feeEvents;
    uint256 private switchEvents;
    uint256 private paidEvents;
    uint256 private positiveSettlements;

    function _trackedPair(uint256 buyA, uint256 buyD, bool supporter) private returns (PairInfo memory info) {
        DuelFactory.Config memory c = factory.config();
        vm.recordLogs();
        info = _createPair(buyA, buyD, supporter);
        tracked.push(info.id);
        ledger[info.id].creator = creator;
        ledger[info.id].protocolShare = c.protocolShareBps;
        ledger[info.id].potShare = c.potShareBps;
        ledger[info.id].supporter = supporter;
        _observe(vm.getRecordedLogs());
    }

    function _observe(Vm.Log[] memory logs) private {
        uint256 expectedMint;
        uint256 expectedBurn;
        uint256 actualMint;
        uint256 actualBurn;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(hook)) {
                if (log.topics[0] == FEE_TAKEN) {
                    Ledger storage l = ledger[uint256(log.topics[1])];
                    (uint256 fee, uint256 tax) = abi.decode(log.data, (uint256, uint256));
                    uint256 protocolCut = fee * l.protocolShare / 10_000;
                    uint256 potCut = fee * l.potShare / 10_000;
                    uint256 creatorCut = fee - protocolCut - potCut;
                    protocolOwed += protocolCut;
                    l.pot += potCut + tax + (l.supporter ? creatorCut : 0);
                    if (!l.supporter) l.creatorOwed += creatorCut;
                    expectedMint += fee + tax;
                    ++feeEvents;
                } else if (log.topics[0] == ARBITRAGE_CAPTURED) {
                    uint256 captured = abi.decode(log.data, (uint256));
                    ledger[uint256(log.topics[1])].pot += captured;
                    expectedMint += captured;
                } else if (log.topics[0] == ROUND_SETTLED) {
                    Ledger storage l = ledger[uint256(log.topics[1])];
                    (, address winner, uint256 spent, uint256 tokensBurned) =
                        abi.decode(log.data, (int24, address, uint256, uint256));
                    assertLe(spent, l.pot, "buyback cannot spend another obligation");
                    l.pot -= spent;
                    l.spent += spent;
                    expectedBurn += spent;
                    if (winner == address(0)) {
                        assertEq(spent, 0);
                        assertEq(tokensBurned, 0);
                    } else {
                        burned[winner] += tokensBurned;
                    }
                    if (spent != 0) ++positiveSettlements;
                } else if (log.topics[0] == SWITCH_BURNED) {
                    burned[address(uint160(uint256(log.topics[2])))] += abi.decode(log.data, (uint256));
                    ++switchEvents;
                } else if (log.topics[0] == CREATOR_PAID) {
                    Ledger storage l = ledger[uint256(log.topics[1])];
                    uint256 amount = abi.decode(log.data, (uint256));
                    assertEq(address(uint160(uint256(log.topics[2]))), l.creator);
                    assertEq(amount, l.creatorOwed, "creator payout differs from independent receipts");
                    l.creatorOwed = 0;
                    expectedBurn += amount;
                    ++paidEvents;
                } else if (log.topics[0] == PROTOCOL_PAID) {
                    uint256 amount = abi.decode(log.data, (uint256));
                    assertEq(amount, protocolOwed, "protocol payout differs from independent receipts");
                    protocolOwed = 0;
                    expectedBurn += amount;
                    ++paidEvents;
                } else if (log.topics[0] == CREATOR_CHANGED) {
                    Ledger storage l = ledger[uint256(log.topics[1])];
                    assertEq(address(uint160(uint256(log.topics[2]))), l.creator);
                    l.creator = address(uint160(uint256(log.topics[3])));
                }
            } else if (log.emitter == address(manager) && log.topics[0] == CLAIM_TRANSFER) {
                if (uint256(log.topics[3]) != 0) continue;
                address from = address(uint160(uint256(log.topics[1])));
                address to = address(uint160(uint256(log.topics[2])));
                (, uint256 amount) = abi.decode(log.data, (address, uint256));
                if (to == address(hook)) {
                    if (from == address(0)) actualMint += amount;
                    else unsolicitedClaims += amount;
                }
                if (from == address(hook)) {
                    assertEq(to, address(0), "ordinary operations only burn their own ETH claims");
                    actualBurn += amount;
                }
            } else if (log.topics[0] == TOKEN_TRANSFER && log.topics.length == 3 && log.topics[2] == bytes32(0)) {
                address from = address(uint160(uint256(log.topics[1])));
                uint256 amount = abi.decode(log.data, (uint256));
                if (from == address(factory)) {
                    seedDustBurned[log.emitter] += amount;
                } else {
                    assertEq(from, address(hook));
                    burnTransfers[log.emitter] += amount;
                }
            }
        }
        assertEq(actualMint, expectedMint, "fee/capture events must correspond to actual claims minted");
        assertEq(actualBurn, expectedBurn, "settlements/payments must correspond to actual claims burned");
        claimReceipts += actualMint;
        claimPayments += actualBurn;
        _reconcile();
    }

    function _reconcile() private view {
        uint256 obligations = protocolOwed;
        assertEq(hook.protocolFees(), protocolOwed);
        for (uint256 i; i < tracked.length; ++i) {
            PairInfo memory info = _info(tracked[i]);
            Ledger storage l = ledger[info.id];
            DuelHook.Pair memory p = hook.getPair(info.id);
            assertEq(p.pot, l.pot);
            assertEq(p.creatorFees, l.creatorOwed);
            assertEq(p.buybacks, l.spent);
            assertEq(p.creator, l.creator);
            obligations += l.pot + l.creatorOwed;
            _checkToken(info.a);
            _checkToken(info.d);
            _checkNoDelta(address(hook), info);
            _checkNoDelta(address(factory), info);
            _checkNoDelta(address(router), info);
            _checkNoDelta(address(swapRouter), info);
        }
        assertEq(
            claimReceipts - claimPayments, obligations, "independent revenues less payments must cover obligations"
        );
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertGe(claims, obligations);
        assertEq(claims - obligations, unsolicitedClaims, "unrequested claims are surplus, never fees or pots");
        assertGe(address(manager).balance, claims, "fixture's physical ETH must cover the hook's native claims");
        assertEq(manager.getNonzeroDeltaCount(), 0, "no unsettled currency debt at a closed boundary");
        assertFalse(manager.isUnlocked());
        assertEq(address(hook).balance, 0);
        assertEq(address(factory).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(address(swapRouter).balance, 0);
    }

    function _checkToken(DuelToken token) private view {
        assertEq(burned[address(token)], burnTransfers[address(token)], "reported burns must match ERC20 transfers");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY() - seedDustBurned[address(token)] - burned[address(token)]);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(swapRouter)), 0);
    }

    function _checkNoDelta(address target, PairInfo memory info) private view {
        assertEq(manager.currencyDelta(target, Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(target, Currency.wrap(address(info.a))), 0);
        assertEq(manager.currencyDelta(target, Currency.wrap(address(info.d))), 0);
    }

    function _buyObserved(PairInfo memory info, bool sideA, uint256 ethIn) private returns (uint256 bought) {
        vm.recordLogs();
        bought = _buy(alice, sideA ? info.keyA : info.keyD, ethIn);
        assertGt(bought, 0);
        _observe(vm.getRecordedLogs());
    }

    function _settleObserved(uint256 id) private returns (Settlement memory s) {
        vm.recordLogs();
        hook.settle(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        s = _settlementIn(logs);
        _observe(logs);
    }

    function _claimCreatorObserved(uint256 id) private {
        address recipient = ledger[id].creator;
        uint256 beforeBalance = recipient.balance;
        vm.recordLogs();
        uint256 amount = hook.claimCreatorFees(id);
        assertGt(amount, 0);
        assertEq(recipient.balance - beforeBalance, amount);
        _observe(vm.getRecordedLogs());
    }

    function _claimProtocolObserved() private {
        address recipient = factory.treasury();
        uint256 beforeBalance = recipient.balance;
        vm.recordLogs();
        uint256 amount = hook.claimProtocolFees();
        assertGt(amount, 0);
        assertEq(recipient.balance - beforeBalance, amount);
        _observe(vm.getRecordedLogs());
    }

    function _handoverObserved(uint256 id, address next) private {
        vm.recordLogs();
        vm.prank(ledger[id].creator);
        factory.transferCreator(id, next);
        vm.prank(next);
        factory.acceptCreator(id);
        _observe(vm.getRecordedLogs());
    }

    function _approveRouter(PairInfo memory info) private {
        vm.startPrank(alice);
        info.a.approve(address(router), type(uint256).max);
        info.d.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Buys, sells, direct switches and ETH-routed switches, in both directions, with positive execution.
    function _ordinaryRouterRoute(PairInfo memory info, uint256 route) private {
        vm.recordLogs();
        vm.startPrank(alice);
        uint256 out;
        if (route < 2) {
            out = router.swapExactIn{value: 0.03 ether}(
                route == 0 ? info.keyA : info.keyD, true, 0.03 ether, 1, alice, block.timestamp
            );
        } else if (route < 4) {
            bool sideA = route == 2;
            out = router.swapExactIn(
                sideA ? info.keyA : info.keyD,
                false,
                (sideA ? info.a : info.d).balanceOf(alice) / 10,
                1,
                alice,
                block.timestamp
            );
        } else if (route < 6) {
            bool fromA = route == 4;
            bool zeroForOne = Currency.unwrap(info.keyX.currency0) == address(fromA ? info.a : info.d);
            out = router.swapExactIn(
                info.keyX, zeroForOne, (fromA ? info.a : info.d).balanceOf(alice) / 10, 1, alice, block.timestamp
            );
        } else {
            bool fromA = route == 6;
            out = router.swapThroughEth(
                fromA ? info.keyA : info.keyD,
                fromA ? info.keyD : info.keyA,
                (fromA ? info.a : info.d).balanceOf(alice) / 10,
                1,
                alice,
                block.timestamp
            );
        }
        vm.stopPrank();
        assertGt(out, 0, "a route that did not execute cannot verify accounting");
        _observe(vm.getRecordedLogs());
    }

    /// @dev Compute input parameters before installing expectRevert so read-only token queries cannot consume it.
    function _refusedRouterRoute(PairInfo memory info, uint256 route) private {
        bool sideA = route % 2 == 0;
        uint256 amount = route < 2 ? 0.03 ether : (sideA ? info.a : info.d).balanceOf(alice) / 10;
        bool zeroForOne =
            route < 2 || (route >= 4 && Currency.unwrap(info.keyX.currency0) == address(sideA ? info.a : info.d));
        PoolKey memory key = route < 4 ? (sideA ? info.keyA : info.keyD) : info.keyX;
        vm.prank(alice);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        if (route < 6) {
            router.swapExactIn{value: route < 2 ? amount : 0}(
                key, zeroForOne, amount, type(uint256).max, alice, block.timestamp
            );
        } else {
            router.swapThroughEth(
                sideA ? info.keyA : info.keyD,
                sideA ? info.keyD : info.keyA,
                amount,
                type(uint256).max,
                alice,
                block.timestamp
            );
        }
    }

    function testFuzz_independentLedgerReconcilesOrdinaryMultiPairOperations(uint64 amountSeed, uint8 timeSeed) public {
        PairInfo memory ordinary = _trackedPair(0.01 ether, 0, false);
        PairInfo memory supporter = _trackedPair(0, 0.01 ether, true);
        uint256 amount = bound(uint256(amountSeed), 0.01 ether, 2 ether);
        vm.warp(vm.getBlockTimestamp() + uint256(timeSeed % 11));
        _buyObserved(ordinary, true, amount);
        _buyObserved(supporter, false, amount / 2);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buyObserved(ordinary, false, amount / 3);
        _approveRouter(ordinary);
        for (uint256 route; route < 8; ++route) {
            _ordinaryRouterRoute(ordinary, route);
        }
        _handoverObserved(ordinary.id, bob);
        _claimCreatorObserved(ordinary.id);
        _claimProtocolObserved();
        _warpToRoundEnd(ordinary.id);
        _settleObserved(ordinary.id);
        _settleObserved(supporter.id);
        assertGt(feeEvents, 0);
        assertGt(switchEvents, 0);
        assertEq(paidEvents, 2);
        assertEq(ledger[supporter.id].creatorOwed, 0);
    }

    function test_unsolicitedNativeClaimsAreSurplusAndDoNotBlockNormalOperations() public {
        PairInfo memory info = _trackedPair(0, 0, false);
        bytes32 beforePair = _pairState(info);
        uint256 beforeProtocol = hook.protocolFees();
        PoolClaimsTest depositor = new PoolClaimsTest(manager);
        vm.prank(alice);
        depositor.deposit{value: 0.07 ether}(Currency.wrap(address(0)), alice, 0.07 ether);
        vm.recordLogs();
        vm.prank(alice);
        manager.transfer(address(hook), 0, 0.07 ether);
        _observe(vm.getRecordedLogs());
        assertEq(_pairState(info), beforePair);
        assertEq(hook.protocolFees(), beforeProtocol);
        assertEq(unsolicitedClaims, 0.07 ether);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buyObserved(info, true, 0.5 ether);
        _buyObserved(info, false, 0.2 ether);
        _approveRouter(info);
        for (uint256 route; route < 8; ++route) {
            _ordinaryRouterRoute(info, route);
        }
        _claimCreatorObserved(info.id);
        _claimProtocolObserved();
        _warpToRoundEnd(info.id);
        _settleObserved(info.id);
        assertEq(manager.balanceOf(address(hook), 0) - ledger[info.id].pot, unsolicitedClaims);
    }

    function test_creatorPaymentRefusalRestoresClaimsObligationsAndBalancesThenRetries() public {
        PairInfo memory info = _trackedPair(0.02 ether, 0.01 ether, false);
        AccountingPaymentReceiver recipient = new AccountingPaymentReceiver();
        _handoverObserved(info.id, address(recipient));
        uint256 owed = ledger[info.id].creatorOwed;
        assertGt(owed, 0);
        bytes32 beforeState = _allState();
        uint256 beforeRecipient = address(recipient).balance;
        vm.expectRevert();
        hook.claimCreatorFees(info.id);
        assertEq(_allState(), beforeState);
        assertEq(address(recipient).balance, beforeRecipient);
        _reconcile();
        recipient.allowPayment();
        _claimCreatorObserved(info.id);
        assertEq(address(recipient).balance - beforeRecipient, owed);
        assertEq(ledger[info.id].creatorOwed, 0);
    }

    function test_protocolPaymentRefusalRestoresClaimsObligationsAndBalancesThenRetries() public {
        PairInfo memory info = _trackedPair(0.02 ether, 0.01 ether, false);
        AccountingPaymentReceiver recipient = new AccountingPaymentReceiver();
        DuelFactory.Config memory c = factory.config();
        c.treasury = address(recipient);
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + factory.CONFIG_DELAY());
        factory.applyConfig();
        uint256 owed = protocolOwed;
        assertGt(owed, 0);
        bytes32 beforeState = _allState();
        uint256 beforeRecipient = address(recipient).balance;
        vm.expectRevert();
        hook.claimProtocolFees();
        assertEq(_allState(), beforeState);
        assertEq(address(recipient).balance, beforeRecipient);
        assertGt(hook.getPair(info.id).creatorFees, 0);
        _reconcile();
        recipient.allowPayment();
        _claimProtocolObserved();
        assertEq(address(recipient).balance - beforeRecipient, owed);
    }

    function test_otherPairIsIsolatedAcrossAllRouterRoutesClaimsHandoverSettlementAndRevert() public {
        PairInfo memory active = _trackedPair(0, 0, false);
        PairInfo memory foreignPair = _trackedPair(0.02 ether, 0.01 ether, false);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buyObserved(active, true, 0.5 ether);
        _buyObserved(active, false, 0.2 ether);
        _approveRouter(active);
        bytes32 foreignState = _pairState(foreignPair);
        for (uint256 route; route < 8; ++route) {
            _ordinaryRouterRoute(active, route);
            assertEq(_pairState(foreignPair), foreignState);
        }
        _handoverObserved(active.id, bob);
        assertEq(_pairState(foreignPair), foreignState);
        _claimCreatorObserved(active.id);
        assertEq(_pairState(foreignPair), foreignState);
        _claimProtocolObserved();
        assertEq(_pairState(foreignPair), foreignState);

        for (uint256 route; route < 8; ++route) {
            bytes32 beforeFailure = _allState();
            _refusedRouterRoute(active, route);
            assertEq(_allState(), beforeFailure);
            assertEq(_pairState(foreignPair), foreignState);
            _reconcile();
        }
        _warpToRoundEnd(active.id);
        _settleObserved(active.id);
        assertEq(_pairState(foreignPair), foreignState);
    }

    function test_buybackBudgetClaimsAndBurnIdentityForBothWinnersAndCrossOrientations() public {
        for (uint256 orientation; orientation < 2; ++orientation) {
            for (uint256 side; side < 2; ++side) {
                PairInfo memory info;
                for (uint256 attempt; attempt < 20; ++attempt) {
                    info = _trackedPair(0, 0, false);
                    if (hook.getPair(info.id).aIsCurrency0 == (orientation == 0)) break;
                }
                assertEq(hook.getPair(info.id).aIsCurrency0, orientation == 0);
                // Each loop advances time; reading via VM avoids the compiler reusing an earlier TIMESTAMP.
                vm.warp(vm.getBlockTimestamp() + 10);
                _buyObserved(info, side == 0, 1 ether);
                _buyObserved(info, side != 0, 0.3 ether);
                uint256 budget = ledger[info.id].pot;
                uint256 claimsBefore = manager.balanceOf(address(hook), 0);
                DuelToken winner = side == 0 ? info.a : info.d;
                DuelToken loser = side == 0 ? info.d : info.a;
                uint256 winnerSupply = winner.totalSupply();
                uint256 loserSupply = loser.totalSupply();
                _warpToRoundEnd(info.id);
                Settlement memory s = _settleObserved(info.id);
                assertEq(s.winner, address(winner));
                assertGt(s.spent, 0);
                assertGt(s.burned, 0);
                assertLe(s.spent, budget);
                assertEq(claimsBefore + s.captured - manager.balanceOf(address(hook), 0), s.spent);
                assertEq(winnerSupply - winner.totalSupply(), s.burned);
                assertEq(loser.totalSupply(), loserSupply);
                assertEq(ledger[info.id].pot, budget - s.spent + s.captured);
            }
        }
        assertEq(positiveSettlements, 4);
    }

    /// @dev The cross leg is unavailable only inside the internal cycle. A first internal ETH-pool swap occurs
    ///      before it fails; every observable effect must match a reference trade with realignment disabled.
    function test_realignmentMidCycleFailureRollsBackInternalEffectsWhileOuterBuyCommits() public {
        PairInfo memory info = _trackedPair(0, 0, false);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buyObserved(info, true, 0.5 ether);
        _buyObserved(info, false, 0.5 ether);
        uint256 snapshot = vm.snapshotState();
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector, info.id), "reference off");
        uint256 expectedOut = _buyObserved(info, true, 1 ether);
        bytes32 expectedState = _allState();
        assertTrue(vm.revertToState(snapshot));
        vm.clearMockedCalls();
        bytes memory crossCall = abi.encodeWithSelector(IPoolManager.swap.selector, info.keyX);
        vm.mockCallRevert(address(manager), crossCall, "controlled cross-leg failure");
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector, info.keyD));
        vm.expectCall(address(manager), crossCall);
        uint256 actualOut = _buyObserved(info, true, 1 ether);
        assertEq(actualOut, expectedOut);
        assertEq(_allState(), expectedState);
        vm.clearMockedCalls();
        _reconcile();
    }

    function test_realignmentMidCycleFailureAfterSettlementPreservesOnlyCommittedBuyback() public {
        PairInfo memory info = _trackedPair(0, 0, false);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buyObserved(info, true, 1 ether);
        _buyObserved(info, false, 0.3 ether);
        _warpToRoundEnd(info.id);
        uint256 snapshot = vm.snapshotState();
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector, info.id), "reference off");
        Settlement memory expected = _settleObserved(info.id);
        assertGt(expected.spent, 0);
        assertGt(expected.burned, 0);
        assertEq(expected.captured, 0);
        bytes32 expectedState = _allState();
        assertTrue(vm.revertToState(snapshot));
        vm.clearMockedCalls();
        bytes memory crossCall = abi.encodeWithSelector(IPoolManager.swap.selector, info.keyX);
        vm.mockCallRevert(address(manager), crossCall, "controlled cross-leg failure");
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector, info.keyD));
        vm.expectCall(address(manager), crossCall);
        Settlement memory actual = _settleObserved(info.id);
        assertEq(actual.spent, expected.spent);
        assertEq(actual.burned, expected.burned);
        assertEq(actual.captured, 0);
        assertEq(_allState(), expectedState);
        vm.clearMockedCalls();
        _reconcile();
    }

    /// @dev Includes all Pair fields, pending creator, pool prices/liquidity/fee growth, supplies, approvals and token
    ///      holdings of the fixture's participants. Native ETH and global claims are reconciled separately because
    ///      they are intentionally shared by multiple pairs in the same PoolManager.
    function _pairState(PairInfo memory info) private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                hook.getPair(info.id),
                factory.pendingCreator(info.id),
                _poolState(info.keyA),
                _poolState(info.keyD),
                _poolState(info.keyX),
                _tokenState(info.a),
                _tokenState(info.d)
            )
        );
    }

    function _poolState(PoolKey memory key) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return
            keccak256(abi.encode(price, tick, protocolFee, lpFee, manager.getLiquidity(key.toId()), growth0, growth1));
    }

    function _tokenState(DuelToken token) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(address(manager)),
                token.balanceOf(address(hook)),
                token.balanceOf(address(factory)),
                token.balanceOf(address(router)),
                token.balanceOf(address(swapRouter)),
                token.balanceOf(alice),
                token.balanceOf(bob),
                token.balanceOf(creator),
                token.allowance(alice, address(router)),
                token.allowance(alice, address(swapRouter))
            )
        );
    }

    function _allState() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                hook.protocolFees(),
                manager.balanceOf(address(hook), 0),
                address(manager).balance,
                address(hook).balance,
                address(factory).balance,
                address(router).balance,
                address(swapRouter).balance,
                alice.balance,
                bob.balance,
                creator.balance,
                treasury.balance
            )
        );
        for (uint256 i; i < tracked.length; ++i) {
            digest = keccak256(abi.encode(digest, _pairState(_info(tracked[i]))));
        }
    }
}
