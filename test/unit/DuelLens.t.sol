// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelLens} from "../../src/DuelLens.sol";

contract DuelLensTest is DuelTestBase {
    function test_constructor_readsThePoolManager() public view {
        assertEq(address(lens.hook()), address(hook));
        assertEq(address(lens.poolManager()), address(manager));
    }

    function test_getPair_atLaunch() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelLens.PairView memory v = lens.getPair(info.id);
        assertEq(v.pairId, info.id);
        assertEq(v.creator, creator);
        assertEq(v.metadataURI, "ipfs://duel-metadata");
        assertEq(v.a.token, address(info.a));
        assertEq(v.a.name, "Cats");
        assertEq(v.d.symbol, "DOGS");
        // rounding dust of the seeding is burned
        assertApproxEqAbs(v.a.totalSupply, 1_000_000_000 ether, 1e6);
        assertLe(v.a.totalSupply, 1_000_000_000 ether);
        // nothing bought yet: the ETH pools hold no ETH, the price is the launch price (1.68e-9 ETH per token)
        assertEq(v.a.ethReserve, 0);
        assertApproxEqRel(v.a.priceWad, 1.68e9, 0.021e18);
        assertEq(v.gaugeBps, 5000);
        assertEq(v.roundGaugeBps, 5000);
        assertEq(v.volume, 0);
        assertEq(v.buybacks, 0);
        assertEq(v.snipeTaxBps, 9800);
        assertEq(v.roundEnd, START_TIME + 4 hours);
        assertEq(v.fees.swapFeeBps, 120);
        assertEq(v.keyA.tickSpacing, 200);
        // the launch tick, which the app's charts keep a price from going past once a pool is sold out
        assertEq(v.startTick, hook.getPair(v.pairId).startTick);
        assertEq(v.startTick, v.a.tick);
        // what the duel is about, and the protocol's whole fee share
        assertEq(v.category, 5);
        assertEq(v.protocolRateBps, 10_000);
    }

    function test_getPair_readsTheProtocolRate_everyPairsAlike() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.prank(owner);
        factory.setProtocolRate(4000);
        assertEq(lens.getPair(info.id).protocolRateBps, 4000);
    }

    function test_getPair_afterTrading() public {
        PairInfo memory aFirst = _createPairOriented(true);
        PairInfo memory dFirst = _createPairOriented(false);
        vm.warp(block.timestamp + 10);
        _buy(alice, aFirst.keyA, 1 ether);
        _buy(bob, aFirst.keyD, 0.3 ether);
        _buy(alice, dFirst.keyA, 1 ether);
        _buy(bob, dFirst.keyD, 0.3 ether);
        vm.warp(block.timestamp + 1 hours);

        DuelLens.PairView memory v = lens.getPair(aFirst.id);
        // 1 ETH in, minus the 1.2% fee, minus what the internal arbitrage moved to side D
        assertGt(v.a.ethReserve, 0.8 ether);
        assertLt(v.a.ethReserve, 0.988 ether);
        assertGt(v.d.ethReserve, 0);
        assertGt(v.a.priceWad, v.d.priceWad);
        assertGt(v.gaugeBps, 5000);
        assertEq(v.gaugeBps, hook.gaugeBps(aFirst.id));
        assertGt(v.roundGaugeBps, 5000);
        assertGt(v.pot, 0);
        assertEq(v.volume, 1.3 ether);

        DuelLens.PairView memory w = lens.getPair(dFirst.id);
        assertGt(w.gaugeBps, 5000);
        assertEq(w.gaugeBps, hook.gaugeBps(dFirst.id));
        assertGt(w.roundGaugeBps, 5000);
    }

    /// @dev The cross pool favours D after a switch the realignment could not follow, and no ETH backs D: the split
    ///      and the round's average both show the ETH-backed side A ahead.
    function test_getPair_roundAverageUsesOnlyTheEthPrices() public {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
        PairInfo memory info = _createPair(0.05 ether, 0, false);
        _switch(creator, info, address(info.a), info.a.balanceOf(creator));
        vm.warp(block.timestamp + 1 hours);
        DuelLens.PairView memory v = lens.getPair(info.id);
        assertGt(v.gaugeBps, 5000);
        assertEq(v.roundGaugeBps, v.gaugeBps);
    }

    function test_getPairs_paginates() public {
        assertEq(lens.getPairs(0, 10).length, 0);
        _createPair(0, 0, false);
        _createPair(0, 0, false);
        _createPair(0, 0, false);

        DuelLens.PairView[] memory all = lens.getPairs(0, 10);
        assertEq(all.length, 3);
        assertEq(all[2].pairId, 3);

        DuelLens.PairView[] memory page = lens.getPairs(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].pairId, 2);

        assertEq(lens.getPairs(3, 5).length, 0);
    }

    /// @dev Pagination accepts any uint256 limit and clamps it to what remains, including at the integer boundary.
    function test_getPairs_clampsAnOversizedLimitWithoutOverflow() public {
        _createPair(0, 0, false);
        _createPair(0, 0, false);
        DuelLens.PairView[] memory page = lens.getPairs(1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0].pairId, 2);
        assertEq(lens.getPairs(1, 0).length, 0);
        assertEq(lens.getPairs(type(uint256).max, type(uint256).max).length, 0);
    }

    /// @dev A one-tick ETH lead must not be presented as a draw by the basis-point views, in either token order.
    function test_getPair_aOneTickLeadKeepsItsDirectionInTheViews() public {
        for (uint256 i = 0; i < 2; ++i) {
            PairInfo memory info = _createPairOriented(i == 0);
            _buy(alice, info.keyA, 1);
            assertEq(_tick(info.keyD) - _tick(info.keyA), 1);
            vm.warp(block.timestamp + 1 hours);
            DuelLens.PairView memory v = lens.getPair(info.id);
            assertGt(v.gaugeBps, 5000);
            assertGt(v.roundGaugeBps, 5000);
        }
    }

    /// @dev A round past its close that nobody settled yet: the app is shown the average its settlement will decide
    ///      with, not one that keeps running on the time after the close.
    function test_getPair_pendingRoundAverageStopsAtTheClose() public {
        PairInfo memory info = _pairWithLeader(true, true);
        uint256 end = hook.getPair(info.id).roundEnd;
        // an hour before the close the leader sells out: the live split flips, the round's average does not
        vm.warp(end - 1 hours);
        _sell(alice, info.keyA, info.a.balanceOf(alice));
        assertLt(hook.gaugeBps(info.id), 5000);

        vm.warp(end);
        uint256 atClose = lens.getPair(info.id).roundGaugeBps;
        assertGt(atClose, 5000);
        // nobody settles for a day, six rounds
        vm.warp(end + 1 days);
        DuelLens.PairView memory v = lens.getPair(info.id);
        assertEq(v.roundGaugeBps, atClose);
        assertEq(v.roundEnd, end);
        assertTrue(v.roundTraded);
        assertEq(_settleNow(info.id).winner, address(info.a));

        // right after the settlement, the new round's average is the live split
        v = lens.getPair(info.id);
        assertEq(v.roundStart, end + 1 days);
        assertEq(v.roundGaugeBps, v.gaugeBps);
    }
}
