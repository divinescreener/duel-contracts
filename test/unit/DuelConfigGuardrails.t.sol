// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";

/// @dev Configuration lifecycle and accepted boundaries, independent of the default launch terms.
contract DuelConfigGuardrailsTest is DuelTestBase {
    function _apply(DuelFactory.Config memory c) internal {
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(factory.pendingConfigEta());
        factory.applyConfig();
    }

    function _withoutArbitrage() internal {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
    }

    function _assertClaims(uint256 pairId) internal view {
        DuelHook.Pair memory p = hook.getPair(pairId);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + p.creatorFees + p.pot);
        assertEq(address(factory).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_configReplacementStartsAFreshDelay() public {
        DuelFactory.Config memory c = defaultConfig();
        c.swapFeeBps = 125;
        vm.prank(owner);
        factory.proposeConfig(c);
        uint256 firstEta = factory.pendingConfigEta();
        vm.warp(firstEta - 1);

        c.swapFeeBps = 150;
        vm.prank(owner);
        factory.proposeConfig(c);
        uint256 replacementEta = factory.pendingConfigEta();
        assertEq(replacementEta, firstEta - 1 + factory.CONFIG_DELAY());
        vm.warp(firstEta);
        vm.expectRevert(DuelFactory.ConfigNotReady.selector);
        factory.applyConfig();
        assertEq(factory.config().swapFeeBps, 120);

        vm.warp(replacementEta - 1);
        vm.expectRevert(DuelFactory.ConfigNotReady.selector);
        factory.applyConfig();
        vm.warp(replacementEta);
        vm.prank(alice); // applying an elapsed proposal is permissionless
        factory.applyConfig();
        assertEq(factory.config().swapFeeBps, 150);
        assertEq(factory.pendingConfigEta(), 0);
        assertEq(factory.pendingConfig().treasury, address(0));
        vm.expectRevert(DuelFactory.NoPendingConfig.selector);
        factory.applyConfig();
    }

    function test_existingPairKeepsAllFeeTermsAndAccruedProtocolFeesFollowTheTreasury() public {
        PairInfo memory oldPair = _createPair(0, 0, false);
        int24 originalStartTick = hook.getPair(oldPair.id).startTick;
        _withoutArbitrage();
        vm.warp(block.timestamp + 10);
        _buy(alice, oldPair.keyA, 1 ether);
        uint256 previouslyAccrued = hook.protocolFees();
        assertEq(previouslyAccrued, 0.003_96 ether);

        DuelFactory.Config memory c = defaultConfig();
        c.treasury = bob;
        c.startFdv = 2 ether;
        c.crossShareBps = 500;
        c.swapFeeBps = 150;
        c.switchFeeBps = 100;
        c.protocolShareBps = 4000;
        c.potShareBps = 5000;
        c.snipeStartBps = 0;
        c.snipeWindow = 0;
        _apply(c);

        DuelHook.Pair memory oldState = hook.getPair(oldPair.id);
        assertEq(abi.encode(oldState.fees), abi.encode(DuelHook.FeeConfig(120, 50, 3300, 3400, 9800, 10)));
        assertEq(oldState.startTick, originalStartTick);
        uint256 oldTreasuryBefore = treasury.balance;
        uint256 newTreasuryBefore = bob.balance;
        assertEq(hook.claimProtocolFees(), previouslyAccrued);
        assertEq(treasury.balance, oldTreasuryBefore);
        assertEq(bob.balance - newTreasuryBefore, previouslyAccrued);

        _buy(alice, oldPair.keyD, 1 ether);
        assertEq(hook.protocolFees(), 0.003_96 ether); // old terms still govern later swaps
        PairInfo memory newPair = _createPair(0, 0, false);
        DuelHook.Pair memory newState = hook.getPair(newPair.id);
        assertEq(abi.encode(newState.fees), abi.encode(DuelHook.FeeConfig(150, 100, 4000, 5000, 0, 0)));
        assertTrue(newState.startTick != oldState.startTick);
        _buy(alice, newPair.keyA, 1 ether);
        assertEq(hook.protocolFees(), 0.003_96 ether + 0.006 ether);
        assertEq(hook.getPair(newPair.id).creatorFees, 0.0015 ether);
    }

    function test_pausedCreationLeavesTradingSettlementAndClaimsAvailable() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        vm.prank(owner);
        factory.setPaused(true);
        _buy(alice, info.keyA, 1 ether);
        assertGt(info.a.balanceOf(alice), 0);
        assertEq(hook.claimCreatorFees(info.id), 0.003_96 ether);
        assertEq(hook.claimProtocolFees(), 0.003_96 ether);
        _warpToRoundEnd(info.id);
        Settlement memory result = _settleNow(info.id);
        assertTrue(result.found);
        assertEq(result.winner, address(info.a));
        assertTrue(factory.paused());
        _assertClaims(info.id);
    }

    function test_ownerTransferDoesNotGiveThePendingOwnerConfigAuthority() public {
        vm.prank(owner);
        factory.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setPaused(true);
        vm.prank(owner);
        factory.setPaused(true);

        vm.prank(bob);
        factory.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        factory.setPaused(false);
        vm.prank(bob);
        factory.setPaused(false);
        assertFalse(factory.paused());
        assertEq(factory.owner(), bob);
        assertEq(factory.pendingOwner(), address(0));
    }

    function test_allowedMinimumConfigTradesWithNoSnipeOrSwitchFee() public {
        DuelFactory.Config memory c = defaultConfig();
        c.startFdv = 0.1 ether;
        c.swapFeeBps = 25;
        c.switchFeeBps = 0;
        c.protocolShareBps = 0;
        c.potShareBps = 0;
        c.snipeWindow = 0;
        _apply(c);
        PairInfo memory info = _createPair(0, 0, false);
        _withoutArbitrage();
        assertEq(hook.snipeTaxBps(info.id), 0);
        uint256 bought = _buy(alice, info.keyA, 0.1 ether);
        uint256 supplyBefore = info.a.totalSupply();
        _switch(alice, info, address(info.a), bought / 10);
        assertEq(info.a.totalSupply(), supplyBefore);
        assertEq(hook.protocolFees(), 0);
        assertEq(hook.getPair(info.id).pot, 0);
        assertEq(hook.getPair(info.id).creatorFees, 0.000_25 ether);
        _assertClaims(info.id);
    }

    function test_allowedMaximumConfigAssignsTheWholeFeeWithoutACreatorRemainder() public {
        DuelFactory.Config memory c = defaultConfig();
        c.startFdv = 1000 ether;
        c.crossShareBps = 2000;
        c.swapFeeBps = 200;
        c.switchFeeBps = 100;
        c.protocolShareBps = 5000;
        c.potShareBps = 5000;
        c.snipeStartBps = 0;
        c.snipeWindow = 60;
        _apply(c);
        PairInfo memory info = _createPair(0, 0, false);
        _withoutArbitrage();
        uint256 bought = _buy(alice, info.keyA, 1 ether);
        assertEq(hook.protocolFees(), 0.01 ether);
        assertEq(hook.getPair(info.id).pot, 0.01 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0);
        uint256 supplyBefore = info.a.totalSupply();
        uint256 switched = bought / 2;
        _switch(alice, info, address(info.a), switched);
        assertEq(supplyBefore - info.a.totalSupply(), switched / 100);
        _assertClaims(info.id);
    }

    function test_allowedCombinedRateJustBelowOneHundredPercentWorksForBothBuyModes() public {
        DuelFactory.Config memory c = defaultConfig();
        c.swapFeeBps = 25;
        c.snipeStartBps = 9974;
        c.snipeWindow = 60;
        _apply(c);
        PairInfo memory exactIn = _createPair(0, 0, false);
        PairInfo memory exactOut = _createPair(0, 0, false);
        _withoutArbitrage();
        uint256 bought = _buy(alice, exactIn.keyA, 1 ether);
        assertGt(bought, 0);
        uint256 before = bob.balance;
        _swap(bob, exactOut.keyA, true, int256(bought), 2 ether);
        uint256 paid = before - bob.balance;
        assertApproxEqAbs(paid, 1 ether, 10_000); // one wei net grossed up at the smallest permitted remainder
        assertEq(exactOut.a.balanceOf(bob), bought);
        DuelHook.Pair memory pIn = hook.getPair(exactIn.id);
        DuelHook.Pair memory pOut = hook.getPair(exactOut.id);
        assertEq(pIn.volume, 1 ether);
        assertEq(pOut.volume, paid);
        assertEq(
            manager.balanceOf(address(hook), 0),
            hook.protocolFees() + pIn.creatorFees + pIn.pot + pOut.creatorFees + pOut.pot
        );
    }

    function testFuzz_firstRoundEndPreservesItsMinimumAndUtcBoundary(uint40 launch) public view {
        uint256 duration = hook.ROUND_LENGTH();
        launch = uint40(bound(launch, 0, type(uint40).max - duration * 2));
        uint256 end = hook.firstRoundEnd(launch);
        assertEq(end % duration, 0);
        assertGe(end - launch, hook.MIN_FIRST_ROUND());
        assertLt(end - launch, hook.MIN_FIRST_ROUND() + duration);
        assertLe(end, type(uint40).max);
    }
}
