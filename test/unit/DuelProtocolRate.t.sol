// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";

/// @notice The protocol's rate: the factory's owner lowers the protocol's part of every pair's swap fee at once, down to
///         nothing, and raises it back, never above the pair's terms. What the protocol leaves goes to the round's pot,
///         the creator's share never changes, and traders pay the same fee.
contract DuelProtocolRateTest is DuelTestBase {
    /// @dev Turns the internal arbitrage off, so that the pot only holds fees.
    function _withoutArbitrage() internal {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
    }

    function _setRate(uint16 rateBps) internal {
        vm.prank(owner);
        factory.setProtocolRate(rateBps);
    }

    function test_protocolRate_startsAtTheWholeShare() public view {
        assertEq(hook.protocolRateBps(), 10_000);
    }

    function test_setProtocolRate_isTheOwnersAlone_andNeverAboveTheTerms() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setProtocolRate(0);
        // the hook takes it from its factory only
        vm.prank(owner);
        vm.expectRevert(DuelHook.NotFactory.selector);
        hook.setProtocolRate(0);
        vm.prank(owner);
        vm.expectRevert(DuelHook.InvalidRate.selector);
        factory.setProtocolRate(10_001);
        assertEq(hook.protocolRateBps(), 10_000);

        vm.expectEmit(address(hook));
        emit DuelHook.ProtocolRateSet(0);
        _setRate(0);
        assertEq(hook.protocolRateBps(), 0);
    }

    function test_aLowerRate_leavesTheRestToThePot_ofPairsLaunchedBeforeAndAfter() public {
        PairInfo memory before = _createPair(0, 0, false);
        _setRate(2500);
        PairInfo memory after_ = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        _buy(alice, before.keyA, 1 ether);
        _buy(alice, after_.keyD, 1 ether);

        // of each 0.012 ETH fee: a quarter of the protocol's 0.00396, the pot its 0.00408 and the rest, the creator its
        // 0.00396
        assertEq(hook.protocolFees(), 2 * 0.000_99 ether);
        for (uint256 i = 0; i < 2; ++i) {
            DuelHook.Pair memory p = hook.getPair(i == 0 ? before.id : after_.id);
            assertEq(p.pot, 0.007_05 ether);
            assertEq(p.creatorFees, 0.003_96 ether);
        }
    }

    function test_noProtocolFee_thenTheTermsAgain_atOnce() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        _setRate(0);
        uint256 bought = _buy(alice, info.keyA, 1 ether);
        assertEq(hook.protocolFees(), 0);
        assertEq(hook.getPair(info.id).pot, 0.008_04 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0.003_96 ether);

        // a sale pays its fee on the ETH out, shared the same way
        uint256 ethOut = _sell(alice, info.keyA, bought / 2);
        uint256 saleFee = hook.getPair(info.id).creatorFees - 0.003_96 ether;
        assertApproxEqAbs(saleFee, ((ethOut * 120) / 9880) * 33 / 100, 10);
        assertEq(hook.protocolFees(), 0);

        // back to the pair's terms: the protocol's 0.00396 of the next 0.012 ETH fee, no more
        _setRate(10_000);
        uint256 potBefore = hook.getPair(info.id).pot;
        _buy(alice, info.keyA, 1 ether);
        assertEq(hook.protocolFees(), 0.003_96 ether);
        assertEq(hook.getPair(info.id).pot - potBefore, 0.004_08 ether);
    }

    function test_aSupporterPair_getsItsCreatorsShare_andWhatTheProtocolLeaves() public {
        PairInfo memory info = _createPair(0, 0, true);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        _setRate(0);
        _buy(alice, info.keyA, 1 ether);
        assertEq(hook.protocolFees(), 0);
        assertEq(hook.getPair(info.id).creatorFees, 0);
        assertEq(hook.getPair(info.id).pot, 0.012 ether);
    }

    function test_theSnipeTax_goesWholeToThePot_whateverTheRate() public {
        PairInfo memory info = _createPair(0, 0, false);
        _withoutArbitrage();
        _setRate(5000);
        _buy(alice, info.keyA, 1 ether);
        // the launch window's 98% tax, and the pot's 0.00408 with half of the protocol's 0.00396
        assertEq(hook.protocolFees(), 0.001_98 ether);
        assertEq(hook.getPair(info.id).pot, 0.98 ether + 0.006_06 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0.003_96 ether);
    }

    /// @dev Whatever the rate and the trade: the fee is shared out to the wei, the protocol never takes more than its
    ///      terms give it, and the creator always gets its share.
    function testFuzz_theFeeIsSharedOut_andTheProtocolNeverTakesMoreThanItsTerms(uint256 rate, uint256 ethIn) public {
        rate = bound(rate, 0, 10_000);
        ethIn = bound(ethIn, 1e12, 20 ether);
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        _setRate(uint16(rate));
        _buy(alice, info.keyA, ethIn);

        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 fee = (ethIn * 120) / 10_000;
        uint256 share = (fee * 3300) / 10_000;
        assertEq(hook.protocolFees(), (share * rate) / 10_000);
        assertLe(hook.protocolFees(), share);
        assertEq(p.creatorFees, fee - share - (fee * 3400) / 10_000);
        assertEq(hook.protocolFees() + p.pot + p.creatorFees, fee);
    }
}
