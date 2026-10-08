// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DuelSimulator} from "../../src/DuelSimulator.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice The simulator, run as the app runs it: its code on the trader's own address, for one call.
contract DuelSimulatorTest is DuelTestBase {
    DuelSimulator internal sim;

    function _asTrader(address trader) internal returns (DuelSimulator) {
        vm.etch(trader, type(DuelSimulator).runtimeCode);
        return DuelSimulator(payable(trader));
    }

    function test_simulate_answersWhatTheTradeWouldGiveAndTheSplitAfterIt() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 20);
        vm.deal(alice, 1 ether);

        // a buy of A: what the router gives, and the split once the hook realigned the pools, exactly as a real one
        uint256 snapshot = vm.snapshotState();
        (uint256 out, uint256 gauge, uint256 paid) =
            _asTrader(alice).simulate{value: 0.1 ether}(router, hook, info.id, info.keyA, true, 0.1 ether);
        vm.revertToState(snapshot);
        uint256 bought = _buy(alice, info.keyA, 0.1 ether);
        assertEq(out, bought);
        assertEq(gauge, hook.gaugeBps(info.id));
        assertGt(gauge, 5000);
        // all the ETH it was given, the router's refund counted
        assertEq(paid, 0.1 ether);

        // a sale of half of it: the simulator approves the router itself, the trader's allowance is not needed
        snapshot = vm.snapshotState();
        (out, gauge, paid) = _asTrader(alice).simulate(router, hook, info.id, info.keyA, false, bought / 2);
        vm.revertToState(snapshot);
        uint256 ethOut = _sell(alice, info.keyA, bought / 2);
        assertEq(out, ethOut);
        assertEq(gauge, hook.gaugeBps(info.id));
        assertEq(paid, bought / 2);

        // a switch of the rest into D, through the cross pool
        bool aFirst = info.keyX.currency0 == info.keyA.currency1;
        snapshot = vm.snapshotState();
        (out, gauge, paid) = _asTrader(alice).simulate(router, hook, info.id, info.keyX, aFirst, bought - bought / 2);
        vm.revertToState(snapshot);
        uint256 switched = _switch(alice, info, address(info.a), bought - bought / 2);
        assertEq(out, switched);
        assertEq(gauge, hook.gaugeBps(info.id));
        assertEq(paid, bought - bought / 2);
    }

    function test_simulateThroughEth_answersWhatTheSwitchWouldGive() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 20);
        vm.deal(alice, 1 ether);
        uint256 bought = _buy(alice, info.keyA, 0.2 ether);

        uint256 snapshot = vm.snapshotState();
        (uint256 out, uint256 gauge, uint256 paid) =
            _asTrader(alice).simulateThroughEth(router, hook, info.id, info.keyA, info.keyD, bought);
        vm.revertToState(snapshot);
        vm.startPrank(alice);
        info.a.approve(address(router), bought);
        uint256 switched = router.swapThroughEth(info.keyA, info.keyD, bought, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(out, switched);
        assertEq(gauge, hook.gaugeBps(info.id));
        assertLt(gauge, 5000);
        // what the router took: all of it but what the pools could not take even after their realignments
        assertEq(paid, bought - info.a.balanceOf(alice));
    }

    function test_simulate_aWholeExitAnswersWhatTheSaleTakes() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 20);
        vm.deal(alice, 1 ether);
        uint256 bought = _buy(alice, info.keyA, 1 ether);

        // every token back: more than the ETH pool can buy in one swap, which Uniswap's quoter refuses to quote, and
        // which the router sells in a few passes, the realignment refilling the pool between them
        uint256 snapshot = vm.snapshotState();
        (uint256 out,, uint256 paid) = _asTrader(alice).simulate(router, hook, info.id, info.keyA, false, bought);
        vm.revertToState(snapshot);
        vm.startPrank(alice);
        info.a.approve(address(router), bought);
        uint256 ethOut = router.swapExactIn(info.keyA, false, bought, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(out, ethOut);
        assertEq(paid, bought - info.a.balanceOf(alice));
        // all but dust: what the realignment leaves, under its threshold
        assertLt(bought - paid, bought / 10_000);
    }

    function test_simulateSale_answersAWholeExitThroughTheOtherSide() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 20);
        vm.deal(alice, 1 ether);
        // both sides bought, A sold off: D is left, more than its pool can buy back
        _buy(alice, info.keyA, 0.05 ether);
        uint256 bought = _buy(alice, info.keyD, 0.05 ether);
        vm.startPrank(alice);
        info.a.approve(address(router), type(uint256).max);
        router.swapExactIn(info.keyA, false, info.a.balanceOf(alice), 0, alice, block.timestamp);
        vm.stopPrank();

        uint256 snapshot = vm.snapshotState();
        (uint256 out, uint256 gauge, uint256 paid, uint256 other) =
            _asTrader(alice).simulateSale(router, hook, info.id, info.keyD, info.keyX, info.keyA, bought);
        vm.revertToState(snapshot);
        vm.startPrank(alice);
        info.d.approve(address(router), bought);
        uint256 ethOut = router.sell(info.keyD, info.keyX, info.keyA, bought, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(out, ethOut);
        assertEq(gauge, hook.gaugeBps(info.id));
        // all of it taken, nothing of A paid back: A's pool bought it all
        assertEq(paid, bought);
        assertEq(other, 0);
        assertEq(info.d.balanceOf(alice), 0);
    }

    function test_simulateSale_answersTheOtherSidePaidBack() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 20);
        // tokens no ETH pool pays for: the sale gives back the other side's
        deal(address(info.a), alice, 100 ether);
        (uint256 out,, uint256 paid, uint256 other) =
            _asTrader(alice).simulateSale(router, hook, info.id, info.keyA, info.keyX, info.keyD, 100 ether);
        assertEq(out, 0);
        assertEq(paid, 100 ether);
        assertGt(other, 0);
    }

    function test_simulate_withoutTheEthOfABuy_reverts() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelSimulator trader = _asTrader(bob);
        vm.expectRevert();
        trader.simulate(router, hook, info.id, info.keyA, true, 0.1 ether);
    }

    function test_theTraderCanReceiveEth() public {
        _asTrader(bob);
        uint256 before = bob.balance;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = bob.call{value: 1 wei}("");
        assertTrue(ok);
        assertEq(bob.balance, before + 1 wei);
    }
}
