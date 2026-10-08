// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelDeploy, TreasuryProbe} from "../../script/DuelDeploy.sol";

/// @notice A deployment on a node, traded end to end in a fork of it: the bytecode its deploy script put there, not a
///         test build, its launches open (Robinhood Chain's own, or a local one whose owner opened them). A launch and
///         its anti-snipe window, buys and sales by several traders through the Duel router, switches both ways, a
///         round's close and its settlement with the buyback and the burn, the creator's and the treasury's claims,
///         and the books of every duel after it. Nothing is sent: it all happens in the fork.
///         `forge test --match-path "test/e2e/*" --fork-url <node>`, with DUEL_E2E=true and DUEL_HOOK, DUEL_FACTORY,
///         DUEL_ROUTER and DUEL_LENS set; skipped otherwise (README.md, "The live deployment, end to end").
contract DuelDeployedTest is Test {
    DuelHook internal hook;
    DuelFactory internal factory;
    DuelRouter internal router;
    DuelLens internal lens;
    IPoolManager internal manager;
    bool internal live;

    address internal creator = makeAddr("e2e creator");
    address internal sniper = makeAddr("e2e sniper");
    address internal alice = makeAddr("e2e alice");
    address internal bob = makeAddr("e2e bob");

    bytes32 internal constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256,uint256)");
    bytes32 internal constant ROUND_SETTLED = keccak256("RoundSettled(uint256,uint32,int24,address,uint256,uint256)");

    function setUp() public {
        live = vm.envOr("DUEL_E2E", false);
        if (!live) return;
        hook = DuelHook(vm.envAddress("DUEL_HOOK"));
        factory = DuelFactory(vm.envAddress("DUEL_FACTORY"));
        router = DuelRouter(vm.envAddress("DUEL_ROUTER"));
        lens = DuelLens(vm.envAddress("DUEL_LENS"));
        manager = hook.poolManager();
        for (uint256 i = 0; i < 4; ++i) {
            vm.deal([creator, sniper, alice, bob][i], 100 ether);
        }
    }

    function _buy(address user, PoolKey memory key, uint256 eth) internal returns (uint256) {
        vm.prank(user);
        return router.swapExactIn{value: eth}(key, true, eth, 0, user, block.timestamp);
    }

    function _sell(address user, PoolKey memory key, uint256 tokens) internal returns (uint256) {
        vm.startPrank(user);
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        uint256 out = router.swapExactIn(key, false, tokens, 0, user, block.timestamp);
        vm.stopPrank();
        return out;
    }

    /// @dev The hook's ETH claims against everything it owes, over every duel of the deployment.
    function _assertBooks() internal view {
        uint256 owed = hook.protocolFees();
        uint256 count = hook.pairCount();
        for (uint256 id = 1; id <= count; ++id) {
            DuelHook.Pair memory p = hook.getPair(id);
            owed += p.pot + p.creatorFees;
            assertEq(lens.getPair(id).gaugeBps, hook.gaugeBps(id));
        }
        assertEq(manager.balanceOf(address(hook), 0), owed);
    }

    function _found(Vm.Log[] memory logs, bytes32 topic) internal view returns (bytes memory data) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) data = logs[i].data;
        }
    }

    function test_deployed_passesItsChecks() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        DuelDeploy.Deployment memory d = DuelDeploy.Deployment(hook, factory, router, lens);
        // its contracts: the state of its launch was checked as it was born, paused, before its owner opened the
        // launches
        DuelDeploy.checkContracts(d, manager, factory.owner());
        assertFalse(factory.paused());
        _assertBooks();
    }

    function test_deployed_aDuelsWholeLife() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        // a launch with the creator's buys, then a sniper in the launch window
        DuelFactory.Config memory config = factory.config();
        DuelFactory.CreateParams memory params = DuelFactory.CreateParams(
            "E2E Cats", "ECATS", "E2E Dogs", "EDOGS", "", 0.01 ether, 0.01 ether, false, 5, factory.configHash()
        );
        vm.prank(creator);
        uint256 id = factory.createPair{value: config.launchFee + 0.02 ether}(params);
        (PoolKey memory keyA, PoolKey memory keyD, PoolKey memory keyX) = hook.poolKeys(id);
        vm.warp(block.timestamp + 1);
        uint256 bps = hook.snipeTaxBps(id);
        assertGt(bps, 0);
        vm.recordLogs();
        _buy(sniper, keyA, 1 ether);
        (, uint256 tax) = abi.decode(_found(vm.getRecordedLogs(), FEE_TAKEN), (uint256, uint256));
        // the launch window's tax, as its schedule stands one second in
        assertApproxEqAbs(tax, (1 ether * bps) / 10_000, 1e9);

        // traders after the window: both sides, a sale, switches both ways
        vm.warp(block.timestamp + 10);
        uint256 cats = _buy(alice, keyA, 2 ether);
        uint256 dogs = _buy(bob, keyD, 0.5 ether);
        _sell(alice, keyA, cats / 4);
        vm.startPrank(bob);
        IERC20(Currency.unwrap(keyD.currency1)).approve(address(router), type(uint256).max);
        uint256 switched = router.swapThroughEth(keyD, keyA, dogs / 2, 0, bob, block.timestamp);
        vm.stopPrank();
        assertGt(switched, 0);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(keyA.currency1)).approve(address(router), type(uint256).max);
        bool aFirst = Currency.unwrap(keyX.currency0) == Currency.unwrap(keyA.currency1);
        uint256 across = router.swapExactIn(keyX, aFirst, cats / 8, 0, alice, block.timestamp);
        vm.stopPrank();
        assertGt(across, 0);
        _assertBooks();

        // the close: settled with a buyback of the leader, which it burns
        DuelHook.Pair memory before = hook.getPair(id);
        assertGt(before.pot, 0);
        vm.warp(before.roundEnd);
        address a = Currency.unwrap(keyA.currency1);
        uint256 supplyA = DuelToken(a).totalSupply();
        vm.recordLogs();
        hook.settle(id);
        (, address winner, uint256 spent, uint256 burned) =
            abi.decode(_found(vm.getRecordedLogs(), ROUND_SETTLED), (int24, address, uint256, uint256));
        assertEq(winner, a, "A received most of the ETH");
        assertGt(spent, 0);
        assertEq(supplyA - DuelToken(a).totalSupply(), burned);
        assertEq(hook.getPair(id).roundIndex, before.roundIndex + 1);
        _assertBooks();

        // the claims: the creator's share and the treasury's, each once
        uint256 owed = hook.getPair(id).creatorFees;
        uint256 creatorBefore = creator.balance;
        hook.claimCreatorFees(id);
        assertEq(creator.balance - creatorBefore, owed);
        address treasury = config.treasury;
        uint256 protocol = hook.protocolFees();
        uint256 treasuryBefore = treasury.balance;
        hook.claimProtocolFees();
        assertEq(treasury.balance - treasuryBefore, protocol);
        vm.expectRevert(DuelHook.NothingToClaim.selector);
        hook.claimCreatorFees(id);
        _assertBooks();
        // and nothing stays in the router or the factory
        assertEq(address(router).balance, 0);
        assertEq(address(factory).balance, 0);
    }
}
