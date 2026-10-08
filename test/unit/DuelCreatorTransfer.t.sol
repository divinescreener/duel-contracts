// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";

/// @dev A pair's creator hands its role, and the creator fees with it, to another address, which must accept it; or
///      gives its share of the fees to come to the pots, for good.
contract DuelCreatorTransferTest is DuelTestBase {
    event CreatorTransferStarted(uint256 indexed pairId, address indexed creator, address indexed newCreator);
    event CreatorChanged(uint256 indexed pairId, address indexed from, address indexed to);
    event CreatorFeesGivenUp(uint256 indexed pairId, address indexed creator);

    function test_transferCreator_offersTheRoleWhichTheNewCreatorAccepts() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 1 ether);
        uint256 owed = hook.getPair(info.id).creatorFees;
        assertGt(owed, 0);

        // offered: the creator keeps the role meanwhile
        vm.expectEmit(address(factory));
        emit CreatorTransferStarted(info.id, creator, bob);
        vm.prank(creator);
        factory.transferCreator(info.id, bob);
        assertEq(factory.pendingCreator(info.id), bob);
        assertEq(hook.getPair(info.id).creator, creator);

        // taken: the role, and the fees not yet claimed
        vm.expectEmit(address(hook));
        emit CreatorChanged(info.id, creator, bob);
        vm.prank(bob);
        factory.acceptCreator(info.id);
        assertEq(hook.getPair(info.id).creator, bob);
        assertEq(factory.pendingCreator(info.id), address(0));

        uint256 creatorBefore = creator.balance;
        uint256 bobBefore = bob.balance;
        hook.claimCreatorFees(info.id);
        assertEq(bob.balance - bobBefore, owed);
        assertEq(creator.balance, creatorBefore);

        // the fees to come are the new creator's too, and so is the role: the former creator offers it no more
        _buy(alice, info.keyD, 1 ether);
        bobBefore = bob.balance;
        hook.claimCreatorFees(info.id);
        assertGt(bob.balance, bobBefore);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.NotCreator.selector);
        factory.transferCreator(info.id, creator);
        vm.prank(bob);
        factory.transferCreator(info.id, creator);
        assertEq(factory.pendingCreator(info.id), creator);
    }

    function test_transferCreator_isTheCreatorsAlone_andAnOfferIsWithdrawn() public {
        PairInfo memory info = _createPair(0, 0, false);
        // another than its creator, or a pair that does not exist
        vm.prank(alice);
        vm.expectRevert(DuelFactory.NotCreator.selector);
        factory.transferCreator(info.id, alice);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.NotCreator.selector);
        factory.transferCreator(info.id + 1, alice);

        // offered, then withdrawn: the address it was offered to takes nothing
        vm.prank(creator);
        factory.transferCreator(info.id, bob);
        vm.prank(creator);
        factory.transferCreator(info.id, address(0));
        vm.prank(bob);
        vm.expectRevert(DuelFactory.NotPendingCreator.selector);
        factory.acceptCreator(info.id);

        // offered to one address, which another cannot take
        vm.prank(creator);
        factory.transferCreator(info.id, bob);
        vm.prank(alice);
        vm.expectRevert(DuelFactory.NotPendingCreator.selector);
        factory.acceptCreator(info.id);
        assertEq(hook.getPair(info.id).creator, creator);
    }

    function test_transferCreator_worksWhileLaunchesArePaused() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.prank(owner);
        factory.setPaused(true);
        vm.prank(creator);
        factory.transferCreator(info.id, bob);
        vm.prank(bob);
        factory.acceptCreator(info.id);
        assertEq(hook.getPair(info.id).creator, bob);
    }

    function test_setCreator_isTheFactorysAlone() public {
        PairInfo memory info = _createPair(0, 0, false);
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(i == 0 ? creator : owner);
            vm.expectRevert(DuelHook.NotFactory.selector);
            hook.setCreator(info.id, alice);
        }
        assertEq(hook.getPair(info.id).creator, creator);
    }

    function test_giveUpCreatorFees_sendsTheCreatorsShareToThePotsFromThenOn() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        // without the realignment, whose profit goes to the pot too: the fees alone
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        _buy(alice, info.keyA, 1 ether);
        DuelHook.Pair memory before = hook.getPair(info.id);
        assertFalse(before.supporter);
        assertEq(before.creatorFees, 0.003_96 ether);
        assertEq(before.pot, 0.004_08 ether);

        vm.expectEmit(address(hook));
        emit CreatorFeesGivenUp(info.id, creator);
        vm.prank(creator);
        hook.giveUpCreatorFees(info.id);
        DuelHook.Pair memory given = hook.getPair(info.id);
        assertTrue(given.supporter);
        // the role, and the fees taken until then, stay the creator's
        assertEq(given.creator, creator);
        assertEq(given.creatorFees, 0.003_96 ether);
        assertEq(given.pot, before.pot);

        // the next fee: 33% to the protocol as before, and the pot its 34% and the creator's 33%
        uint256 protocolBefore = hook.protocolFees();
        _buy(alice, info.keyD, 1 ether);
        DuelHook.Pair memory after_ = hook.getPair(info.id);
        assertEq(after_.creatorFees, 0.003_96 ether);
        assertEq(after_.pot - before.pot, 0.004_08 ether + 0.003_96 ether);
        assertEq(hook.protocolFees() - protocolBefore, 0.003_96 ether);
        // a sale too
        _sell(alice, info.keyA, info.a.balanceOf(alice) / 2);
        assertEq(hook.getPair(info.id).creatorFees, 0.003_96 ether);

        // what it had earned is paid as before, once
        uint256 balance = creator.balance;
        assertEq(hook.claimCreatorFees(info.id), 0.003_96 ether);
        assertEq(creator.balance - balance, 0.003_96 ether);
        vm.expectRevert(DuelHook.NothingToClaim.selector);
        hook.claimCreatorFees(info.id);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + hook.getPair(info.id).pot);
    }

    function test_giveUpCreatorFees_isTheCreatorsAlone() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.prank(creator);
        factory.transferCreator(info.id, bob);
        // another wallet, the factory's owner, the factory, the wallet the role is offered to
        address[4] memory others = [alice, owner, address(factory), bob];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(DuelHook.NotCreator.selector);
            hook.giveUpCreatorFees(info.id);
        }
        // a pair that does not exist
        vm.prank(creator);
        vm.expectRevert(DuelHook.NotCreator.selector);
        hook.giveUpCreatorFees(info.id + 1);
        assertFalse(hook.getPair(info.id).supporter);

        // the role taken over: its holder's to give up, no longer the former creator's
        vm.prank(bob);
        factory.acceptCreator(info.id);
        vm.prank(creator);
        vm.expectRevert(DuelHook.NotCreator.selector);
        hook.giveUpCreatorFees(info.id);
        assertFalse(hook.getPair(info.id).supporter);
        vm.expectEmit(address(hook));
        emit CreatorFeesGivenUp(info.id, bob);
        vm.prank(bob);
        hook.giveUpCreatorFees(info.id);
        assertTrue(hook.getPair(info.id).supporter);
    }

    function test_giveUpCreatorFees_isForGood() public {
        PairInfo memory info = _createPair(0, 0, false);
        PairInfo memory other = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        vm.startPrank(creator);
        hook.giveUpCreatorFees(info.id);
        // given up again, it stays given up
        hook.giveUpCreatorFees(info.id);
        // handed over, the role carries no fee to come
        factory.transferCreator(info.id, bob);
        vm.stopPrank();
        vm.prank(bob);
        factory.acceptCreator(info.id);
        assertTrue(hook.getPair(info.id).supporter);
        // nor does the factory's owner turn it back: the protocol's rate, the launches paused, a new configuration
        vm.startPrank(owner);
        factory.setProtocolRate(5000);
        factory.setPaused(true);
        DuelFactory.Config memory c = defaultConfig();
        c.potShareBps = 0;
        factory.proposeConfig(c);
        vm.stopPrank();
        vm.warp(factory.pendingConfigEta());
        factory.applyConfig();

        _buy(alice, info.keyA, 1 ether);
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertTrue(p.supporter);
        assertEq(p.creatorFees, 0);
        vm.expectRevert(DuelHook.NothingToClaim.selector);
        hook.claimCreatorFees(info.id);
        // the pair beside it, the same creator's, keeps paying its creator
        _buy(alice, other.keyA, 1 ether);
        assertFalse(hook.getPair(other.id).supporter);
        assertEq(hook.getPair(other.id).creatorFees, 0.003_96 ether);
    }

    function test_giveUpCreatorFees_ofAPairLaunchedForItsPots_changesNothing() public {
        PairInfo memory info = _createPair(0, 0, true);
        vm.warp(block.timestamp + 10);
        vm.prank(creator);
        hook.giveUpCreatorFees(info.id);
        assertTrue(hook.getPair(info.id).supporter);
        _buy(alice, info.keyA, 1 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0);
    }
}
