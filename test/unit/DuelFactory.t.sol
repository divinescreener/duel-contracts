// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";

contract RejectingReceiver {
    function create(DuelFactory factory, DuelFactory.CreateParams calldata params) external payable {
        factory.createPair{value: msg.value}(params);
    }
}

contract DuelFactoryTest is DuelTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_constructor_storesConfiguration() public view {
        DuelFactory.Config memory c = factory.config();
        assertEq(c.treasury, treasury);
        assertEq(c.launchFee, 0.01 ether);
        assertEq(c.launchFee, LAUNCH_FEE);
        assertEq(c.startFdv, 1.68 ether);
        assertEq(factory.treasury(), treasury);
        assertEq(address(factory.poolManager()), address(manager));
        assertEq(address(factory.hook()), address(hook));
        assertEq(factory.owner(), owner);
        assertFalse(factory.paused());
    }

    function test_constructor_rejectsInvalidConfig() public {
        DuelFactory.Config memory c = defaultConfig();
        c.treasury = address(0);
        vm.expectRevert(DuelFactory.InvalidConfig.selector);
        new DuelFactory(manager, hook, owner, c);
    }

    function test_validate_everyBound() public {
        DuelFactory.Config[] memory bad = new DuelFactory.Config[](14);
        for (uint256 i = 0; i < bad.length; ++i) {
            bad[i] = defaultConfig();
        }
        bad[0].treasury = address(0);
        bad[1].launchFee = 0.01 ether + 1;
        bad[2].startFdv = 0.1 ether - 1;
        bad[3].startFdv = 1000 ether + 1;
        bad[4].crossShareBps = 199;
        bad[5].crossShareBps = 2001;
        bad[6].swapFeeBps = 24;
        bad[7].swapFeeBps = 201;
        bad[8].switchFeeBps = 101;
        bad[9].protocolShareBps = 5001;
        bad[10].potShareBps = 5001;
        bad[11].snipeWindow = 61;
        bad[12].snipeStartBps = 9880; // 9880 + 120 >= 10000
        bad[13].snipeStartBps = 9881;
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(DuelFactory.InvalidConfig.selector);
            factory.proposeConfig(bad[i]);
        }
    }

    function test_createPair_seedsThreePools() public {
        uint256 treasuryBefore = treasury.balance;
        PairInfo memory info = _createPair(0, 0, false);
        DuelHook.Pair memory p = hook.getPair(info.id);

        assertEq(info.id, 1);
        assertEq(hook.pairCount(), 1);
        assertEq(p.creator, creator);
        assertEq(info.a.name(), "Cats");
        assertEq(info.d.symbol(), "DOGS");
        assertEq(info.a.metadataURI(), "ipfs://duel-metadata");
        assertEq(treasury.balance - treasuryBefore, LAUNCH_FEE);

        // the factory keeps nothing: every token sits in the PoolManager, rounding dust is burned
        assertEq(info.a.balanceOf(address(factory)), 0);
        assertEq(info.d.balanceOf(address(factory)), 0);
        assertApproxEqRel(info.a.balanceOf(address(manager)), 1_000_000_000 ether, 1e12);
        assertApproxEqRel(info.d.balanceOf(address(manager)), 1_000_000_000 ether, 1e12);

        // both ETH pools start at the same launch tick, the cross pool at 1:1
        assertEq(_tick(info.keyA), p.startTick);
        assertEq(_tick(info.keyD), p.startTick);
        assertEq(p.startTick % 200, 0);
        assertEq(_tick(info.keyX), 0);
        assertGt(manager.getLiquidity(info.keyX.toId()), 0);
        // at the launch tick the single-sided range is not active yet
        assertEq(manager.getLiquidity(info.keyA.toId()), 0);
    }

    function test_createPair_keepsItsCategory_anyNumber() public {
        // the helper's launch: a duel about animals, as the app numbers its categories
        PairInfo memory info = _createPair(0, 0, false);
        assertEq(hook.getPair(info.id).category, 5);
        // any number: the app names those it knows, and may name more later
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        params.category = 255;
        vm.recordLogs();
        vm.prank(creator);
        uint256 id = factory.createPair{value: LAUNCH_FEE}(params);
        assertEq(hook.getPair(id).category, 255);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 registered = keccak256("PairRegistered(uint256,address,address,address,uint8)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != registered) continue;
            (,, uint8 category) = abi.decode(logs[i].data, (address, address, uint8));
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), creator);
            assertEq(category, 255);
            ++found;
        }
        assertEq(found, 1);
    }

    function test_createPair_launchPriceMatchesStartFdv() public {
        PairInfo memory info = _createPair(0, 0, false);
        // tokens per wei at launch ~= supply / FDV, within the 2% of one 200-tick step
        uint256 priceX96 = uint256(_sqrtPrice(info.keyA)) * uint256(_sqrtPrice(info.keyA)) >> 96;
        uint256 supply = 1_000_000_000 ether;
        uint256 expected = (supply << 96) / 1.68 ether;
        assertApproxEqRel(priceX96, expected, 0.021e18);
    }

    function test_createPair_creatorBuysBothSides() public {
        uint256 treasuryBefore = treasury.balance;
        PairInfo memory info = _createPair(0.05 ether, 0.02 ether, false);
        uint256 boughtA = info.a.balanceOf(creator);
        uint256 boughtD = info.d.balanceOf(creator);
        assertGt(boughtA, boughtD);
        assertGt(boughtD, 0);
        // the creator pays the swap fee but no anti-snipe tax
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(treasury.balance - treasuryBefore, LAUNCH_FEE);
        assertEq(
            hook.protocolFees(),
            (0.05 ether * 120 / 10_000) * 3300 / 10_000 + (0.02 ether * 120 / 10_000) * 3300 / 10_000
        );
        assertGt(p.creatorFees, 0);
        assertEq(address(factory).balance, 0);
    }

    function test_createPair_creatorBuysOneSide() public {
        PairInfo memory info = _createPair(0, 0.03 ether, false);
        assertEq(info.a.balanceOf(creator), 0);
        assertGt(info.d.balanceOf(creator), 0);
    }

    function test_createPair_refundsExcessValue() public {
        uint256 before = creator.balance;
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(creator);
        factory.createPair{value: 1 ether}(params);
        assertEq(before - creator.balance, LAUNCH_FEE);
    }

    function test_createPair_revertsWhenCreatorBuysTooMuch() public {
        DuelFactory.CreateParams memory params = createParams(5 ether, 0, false);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.CreatorBuyTooLarge.selector);
        factory.createPair{value: 5 ether + LAUNCH_FEE}(params);
    }

    /// @dev A pair with `params`, refused or not.
    function _tryCreate(DuelFactory.CreateParams memory params, bool refused) internal {
        vm.prank(creator);
        if (refused) vm.expectRevert(DuelFactory.InvalidMetadata.selector);
        factory.createPair{value: LAUNCH_FEE}(params);
    }

    function _text(uint256 length, bytes1 char) internal pure returns (string memory) {
        bytes memory text = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            text[i] = char;
        }
        return string(text);
    }

    function test_createPair_boundsNamesTickersAndMetadata() public {
        DuelFactory.CreateParams memory p = createParams(0, 0, false);
        // at the bounds: 32 four-byte characters for a name, 10 for a ticker, 4096 bytes of metadata
        p.nameA = _text(128, "a");
        p.nameD =
            unicode"🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶";
        assertEq(bytes(p.nameD).length, 128);
        p.symbolA = _text(40, "A");
        p.metadataURI = _text(4096, "m");
        _tryCreate(p, false);
        p = createParams(0, 0, false);
        p.metadataURI = "";
        _tryCreate(p, false);
        // a byte past any bound, or an empty name or ticker, is refused
        p = createParams(0, 0, false);
        p.nameD = _text(129, "d");
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.symbolD = _text(41, "D");
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.metadataURI = _text(4097, "m");
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.nameA = "";
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.symbolA = "";
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.nameD = "";
        _tryCreate(p, true);
        p = createParams(0, 0, false);
        p.symbolD = "";
        _tryCreate(p, true);
    }

    function test_createPair_revertsOnInsufficientValue() public {
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.InsufficientValue.selector);
        factory.createPair{value: LAUNCH_FEE - 1}(params);
    }

    function test_createPair_chargesTheLaunchFeeOnChain() public {
        // the former 0.001 ETH no longer launches a duel, nor the fee without the creator's buys
        DuelFactory.CreateParams memory none = createParams(0, 0, false);
        DuelFactory.CreateParams memory buying = createParams(0.02 ether, 0, false);
        vm.startPrank(creator);
        vm.expectRevert(DuelFactory.InsufficientValue.selector);
        factory.createPair{value: 0.001 ether}(none);
        vm.expectRevert(DuelFactory.InsufficientValue.selector);
        factory.createPair{value: 0.01 ether + 0.02 ether - 1}(buying);

        // 0.01 ETH exactly does, and all of it goes to the treasury
        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = creator.balance;
        factory.createPair{value: 0.01 ether}(none);
        vm.stopPrank();
        assertEq(treasury.balance - treasuryBefore, 0.01 ether);
        assertEq(creatorBefore - creator.balance, 0.01 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_createPair_revertsWhenPaused() public {
        vm.prank(owner);
        factory.setPaused(true);
        assertTrue(factory.paused());
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.CreationPaused.selector);
        factory.createPair{value: LAUNCH_FEE}(params);

        vm.prank(owner);
        factory.setPaused(false);
        _createPair(0, 0, false);
    }

    /// @dev The site hashes the terms it shows from what config() returned, so that the hash it commits to can only be
    ///      theirs: configHash() must be the hash of those very bytes.
    function test_configHash_isTheHashOfWhatConfigReturns() public view {
        (bool ok, bytes memory returned) = address(factory).staticcall(abi.encodeCall(factory.config, ()));
        assertTrue(ok);
        assertEq(returned.length, 10 * 32);
        assertEq(factory.configHash(), keccak256(returned));
    }

    /// @dev A launch commits to the configuration its launcher was shown: one applied since makes it revert, whoever
    ///      applied it, and the launcher reads the new terms and launches with them.
    function test_createPair_revertsWhenTheConfigChangedSinceItWasRead() public {
        assertEq(factory.configHash(), keccak256(abi.encode(factory.config())));
        DuelFactory.CreateParams memory stale = createParams(0, 0, false);
        DuelFactory.Config memory next = defaultConfig();
        next.swapFeeBps = 150;
        vm.prank(owner);
        factory.proposeConfig(next);
        vm.warp(vm.getBlockTimestamp() + factory.CONFIG_DELAY());
        vm.prank(alice);
        factory.applyConfig();
        assertEq(factory.configHash(), keccak256(abi.encode(next)));

        vm.prank(creator);
        vm.expectRevert(DuelFactory.ConfigChanged.selector);
        factory.createPair{value: LAUNCH_FEE}(stale);
        // nor does a launch that commits to nothing go through
        stale.config = bytes32(0);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.ConfigChanged.selector);
        factory.createPair{value: LAUNCH_FEE}(stale);

        DuelFactory.CreateParams memory fresh = createParams(0, 0, false);
        vm.prank(creator);
        uint256 id = factory.createPair{value: LAUNCH_FEE}(fresh);
        assertEq(hook.getPair(id).fees.swapFeeBps, 150);
    }

    function test_setPaused_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setPaused(true);
    }

    function test_createPair_revertsWhenTreasuryRejectsEth() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        DuelFactory.Config memory c = defaultConfig();
        c.treasury = address(rejecting);
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(block.timestamp + 48 hours);
        factory.applyConfig();

        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.TransferFailed.selector);
        factory.createPair{value: LAUNCH_FEE}(params);
    }

    function test_createPair_revertsWhenRefundIsRejected() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.deal(address(rejecting), 1 ether);
        DuelFactory.CreateParams memory refunded = createParams(0, 0, false);
        vm.expectRevert(DuelFactory.TransferFailed.selector);
        rejecting.create{value: 2 * LAUNCH_FEE}(factory, refunded);
    }

    function test_createPair_withoutLaunchFee() public {
        DuelFactory.Config memory c = defaultConfig();
        c.launchFee = 0;
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(block.timestamp + 48 hours);
        factory.applyConfig();

        uint256 treasuryBefore = treasury.balance;
        DuelFactory.CreateParams memory free = createParams(0, 0, false);
        vm.prank(creator);
        factory.createPair(free);
        assertEq(treasury.balance, treasuryBefore);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(DuelFactory.NotPoolManager.selector);
        factory.unlockCallback("");
    }

    function test_config_proposeApplyCancel() public {
        DuelFactory.Config memory c = defaultConfig();
        c.swapFeeBps = 150;

        vm.expectRevert(DuelFactory.NoPendingConfig.selector);
        factory.applyConfig();

        vm.prank(owner);
        factory.proposeConfig(c);
        assertEq(factory.pendingConfigEta(), block.timestamp + 48 hours);
        assertEq(factory.pendingConfig().swapFeeBps, 150);

        vm.expectRevert(DuelFactory.ConfigNotReady.selector);
        factory.applyConfig();

        vm.prank(owner);
        factory.cancelConfig();
        assertEq(factory.pendingConfigEta(), 0);
        assertEq(factory.pendingConfig().swapFeeBps, 0);

        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(block.timestamp + 48 hours);
        factory.applyConfig();
        assertEq(factory.config().swapFeeBps, 150);
        assertEq(factory.pendingConfigEta(), 0);

        // new pairs use the new terms, existing ones keep theirs
        PairInfo memory info = _createPair(0, 0, false);
        assertEq(hook.getPair(info.id).fees.swapFeeBps, 150);
    }

    function test_proposeConfig_onlyOwner() public {
        DuelFactory.Config memory c = defaultConfig();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.proposeConfig(c);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.cancelConfig();
    }

    /// @dev The factory is born paused: its owner launches the first pair, whose id is 1, whenever it wants; nobody else
    ///      launches until the owner opens the launches.
    function test_bornPaused_theFirstPairIsItsOwners() public {
        // a factory as its constructor leaves it
        DuelFactory born = new DuelFactory(manager, hook, owner, defaultConfig());
        assertTrue(born.paused());

        // the test's own, paused again as it was born, before any pair
        vm.prank(owner);
        factory.setPaused(true);
        assertEq(hook.pairCount(), 0);
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        address[3] memory others = [creator, alice, treasury];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.deal(others[i], 1 ether);
            vm.prank(others[i]);
            vm.expectRevert(DuelFactory.CreationPaused.selector);
            factory.createPair{value: LAUNCH_FEE}(params);
        }
        assertEq(hook.pairCount(), 0);

        // days later, the owner: the first pair, its own
        vm.warp(block.timestamp + 3 days);
        vm.deal(owner, 1 ether);
        DuelFactory.CreateParams memory own = createParams(0.01 ether, 0, false);
        vm.prank(owner);
        uint256 first = factory.createPair{value: LAUNCH_FEE + 0.01 ether}(own);
        assertEq(first, 1);
        assertEq(hook.getPair(1).creator, owner);
        // still closed to the others until the owner opens the launches
        vm.prank(creator);
        vm.expectRevert(DuelFactory.CreationPaused.selector);
        factory.createPair{value: LAUNCH_FEE}(params);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setPaused(false);
        vm.prank(owner);
        factory.setPaused(false);
        assertEq(_createPair(0, 0, false).id, 2);
    }

    /// @dev Paused again later, the factory still launches for its owner, and for nobody else.
    function test_paused_theOwnerStillLaunches() public {
        assertEq(_createPair(0, 0, false).id, 1);
        vm.prank(owner);
        factory.setPaused(true);
        DuelFactory.CreateParams memory params = createParams(0, 0, false);
        vm.prank(creator);
        vm.expectRevert(DuelFactory.CreationPaused.selector);
        factory.createPair{value: LAUNCH_FEE}(params);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        assertEq(factory.createPair{value: LAUNCH_FEE}(params), 2);
        // a new owner takes that with the role, the former one loses it
        vm.prank(owner);
        factory.transferOwnership(bob);
        vm.prank(bob);
        factory.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(DuelFactory.CreationPaused.selector);
        factory.createPair{value: LAUNCH_FEE}(params);
        vm.prank(bob);
        assertEq(factory.createPair{value: LAUNCH_FEE}(params), 3);
    }
}
