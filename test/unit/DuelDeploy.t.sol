// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelBootstrap} from "../../script/DuelBootstrap.sol";
import {DuelDeploy, TreasuryProbe} from "../../script/DuelDeploy.sol";
import {DeployRouter} from "../../script/DeployRouter.s.sol";

/// @dev The deploy script's checks, called from outside so that their failures can be expected.
contract DeployChecks {
    function checkTarget(IPoolManager poolManager, uint256 chainId, bytes32 codehash) external view {
        DuelDeploy.checkTarget(poolManager, chainId, codehash);
    }

    function expectedCodehash(IPoolManager poolManager, bytes32 given) external pure returns (bytes32) {
        return DuelDeploy.expectedCodehash(poolManager, given);
    }

    function checkDeployment(
        DuelDeploy.Deployment memory d,
        IPoolManager poolManager,
        address owner,
        address treasury,
        TreasuryProbe probe
    ) external {
        DuelDeploy.checkDeployment(d, poolManager, owner, treasury, probe);
    }

    function checkContracts(DuelDeploy.Deployment memory d, IPoolManager poolManager, address owner) external {
        DuelDeploy.checkContracts(d, poolManager, owner);
    }
}

contract DuelDeployTest is DuelTestBase {
    DeployChecks internal checks = new DeployChecks();
    TreasuryProbe internal probe = new TreasuryProbe();

    /// @dev The deployment as it is born: its launches still paused.
    function _opened() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        // the wei the probe sends the treasury, as the scripts give it
        vm.deal(address(probe), 1 ether);
    }

    function _deployment() internal view returns (DuelDeploy.Deployment memory) {
        return DuelDeploy.Deployment({hook: hook, factory: factory, router: router, lens: lens});
    }

    /// @dev A hook at an address carrying its flags, on the same PoolManager, trusting another factory.
    function _otherHook() internal returns (DuelHook) {
        address at = address(uint160(0x5555) << 144 | DuelDeploy.HOOK_FLAGS);
        deployCodeTo("DuelHook.sol:DuelHook", abi.encode(address(manager), makeAddr("another factory")), at);
        return DuelHook(at);
    }

    function test_checkTarget_namesTheChainAndThePoolManager() public {
        bytes32 codehash = address(manager).codehash;
        checks.checkTarget(manager, block.chainid, codehash);
        // a local node alone may expect no code
        assertEq(block.chainid, DuelDeploy.LOCAL_CHAIN_ID);
        checks.checkTarget(manager, block.chainid, bytes32(0));
        vm.expectRevert("DuelDeploy: not the chain named");
        checks.checkTarget(manager, block.chainid + 1, codehash);
        vm.expectRevert("DuelDeploy: no PoolManager there");
        checks.checkTarget(IPoolManager(makeAddr("nothing")), block.chainid, bytes32(0));
        vm.expectRevert("DuelDeploy: not the PoolManager code expected");
        checks.checkTarget(manager, block.chainid, keccak256("another PoolManager"));
        // on Robinhood Chain, a PoolManager whose code nobody named is refused
        vm.chainId(4663);
        vm.expectRevert("DuelDeploy: POOL_MANAGER_CODEHASH needed");
        checks.checkTarget(manager, 4663, bytes32(0));
        checks.checkTarget(manager, 4663, codehash);
    }

    function test_expectedCodehash_isTheOperatorsElseRobinhoodChainsAtItsPoolManager() public view {
        IPoolManager robinhood = IPoolManager(DuelDeploy.ROBINHOOD_POOL_MANAGER);
        assertEq(checks.expectedCodehash(robinhood, bytes32(0)), DuelDeploy.ROBINHOOD_POOL_MANAGER_CODEHASH);
        assertEq(checks.expectedCodehash(robinhood, keccak256("given")), keccak256("given"));
        assertEq(checks.expectedCodehash(manager, bytes32(0)), bytes32(0));
        assertEq(checks.expectedCodehash(manager, keccak256("given")), keccak256("given"));
    }

    function test_checkDeployment_passesTheDeploymentAsItStands() public {
        checks.checkDeployment(_deployment(), manager, owner, treasury, probe);
    }

    /// @dev The deploy path: one bootstrap, created by the deploying account, deploys the hook at the salt mined for
    ///      its address and the factory at its second address, each naming the other, the factory owned by the
    ///      multisig; the deployment check passes on it.
    function test_deployCore_deploysTheHookAndTheFactoryInOneBootstrap() public {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (DuelHook h, DuelFactory f) = DuelDeploy.deployCore(manager, owner, defaultConfig(), address(this));
        assertEq(address(DuelBootstrap(at).hook()), address(h));
        assertEq(address(DuelBootstrap(at).factory()), address(f));
        assertEq(address(f), vm.computeCreateAddress(at, 2));
        assertEq(DuelBootstrap(at).createAddress(at, 2), address(f));
        assertEq(uint160(address(h)) & Hooks.ALL_HOOK_MASK, DuelDeploy.HOOK_FLAGS);
        assertEq(h.factory(), address(f));
        assertEq(address(f.hook()), address(h));
        assertEq(f.owner(), owner);
        DuelDeploy.Deployment memory d =
            DuelDeploy.Deployment({hook: h, factory: f, router: new DuelRouter(manager), lens: new DuelLens(h)});
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }

    /// @dev Only the bootstrap a salt was mined for deploys the hook with it: at another address (a nonce used in
    ///      between) the hook's address would not carry its flags, its constructor refuses it, and nothing deploys.
    function test_bootstrap_aSaltMinedForAnotherAddressDeploysNothing() public {
        uint64 nonce = vm.getNonce(address(this));
        address elsewhere = vm.computeCreateAddress(address(this), nonce + 1);
        (bytes32 salt, address planned) = DuelDeploy.mineSalt(
            keccak256(DuelDeploy.hookInitCode(manager, vm.computeCreateAddress(elsewhere, 2))), elsewhere
        );
        DuelFactory.Config memory config = defaultConfig();
        vm.expectRevert();
        new DuelBootstrap(manager, salt, planned, owner, config);
    }

    /// @dev Nor where the salt gives the flags too, as one salt in 16,384 does at any other address: the bootstrap
    ///      checks the hook landed at the address planned, not only its flags. Here the salt gives valid flags at the
    ///      address the bootstrap takes, and the plan was for another.
    function test_bootstrap_aHookAnywhereElseThanPlannedDeploysNothing() public {
        uint64 nonce = vm.getNonce(address(this));
        address here = vm.computeCreateAddress(address(this), nonce);
        address elsewhere = vm.computeCreateAddress(address(this), nonce + 1);
        (bytes32 salt, address valid) =
            DuelDeploy.mineSalt(keccak256(DuelDeploy.hookInitCode(manager, vm.computeCreateAddress(here, 2))), here);
        (, address planned) = DuelDeploy.mineSalt(
            keccak256(DuelDeploy.hookInitCode(manager, vm.computeCreateAddress(elsewhere, 2))), elsewhere
        );
        assertEq(uint160(valid) & Hooks.ALL_HOOK_MASK, DuelDeploy.HOOK_FLAGS);
        DuelFactory.Config memory config = defaultConfig();
        vm.expectRevert("DuelBootstrap: hook address");
        new DuelBootstrap(manager, salt, planned, owner, config);
    }

    /// @dev The bootstrap carries the hook's and the factory's creation code: with its arguments it must stay under the
    ///      49,152 bytes a creation may carry (EIP-3860), else a larger hook or factory could not deploy this way.
    function test_bootstrap_fitsTheInitcodeLimit() public view {
        bytes memory initCode = abi.encodePacked(
            type(DuelBootstrap).creationCode, abi.encode(manager, bytes32(0), address(0), owner, defaultConfig())
        );
        assertLe(initCode.length, 49_152);
        assertGt(initCode.length, type(DuelHook).creationCode.length + type(DuelFactory).creationCode.length);
    }

    function test_checkDeployment_refusesEveryMismatch() public {
        DuelDeploy.Deployment memory d = _deployment();
        // another PoolManager than the one named
        vm.expectRevert("DuelDeploy: not on the PoolManager");
        checks.checkDeployment(d, IPoolManager(makeAddr("elsewhere")), owner, treasury, probe);
        // a lens reading another hook
        d.lens = new DuelLens(_otherHook());
        vm.expectRevert("DuelDeploy: lens not on the hook");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        d = _deployment();
        // an owner, or a treasury, other than the operator's
        vm.expectRevert("DuelDeploy: owner");
        checks.checkDeployment(d, manager, alice, treasury, probe);
        vm.expectRevert("DuelDeploy: treasury");
        checks.checkDeployment(d, manager, owner, alice, probe);
        // an ownership transfer left pending
        vm.prank(owner);
        factory.transferOwnership(alice);
        vm.expectRevert("DuelDeploy: owner");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        vm.prank(alice);
        factory.acceptOwnership();
        vm.prank(alice);
        factory.transferOwnership(owner);
        vm.prank(owner);
        factory.acceptOwnership();
        // other launch terms within the bounds, proposed and applied; or waiting; or launches opened already
        DuelFactory.Config memory other = factory.config();
        other.swapFeeBps = 150;
        vm.prank(owner);
        factory.proposeConfig(other);
        vm.expectRevert("DuelDeploy: terms pending, or launches open");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.applyConfig();
        vm.expectRevert("DuelDeploy: launch terms");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        other.swapFeeBps = 120;
        vm.prank(owner);
        factory.proposeConfig(other);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.applyConfig();
        // opened: anyone may have launched before the owner's first pair
        vm.prank(owner);
        factory.setPaused(false);
        vm.expectRevert("DuelDeploy: terms pending, or launches open");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        vm.prank(owner);
        factory.setPaused(true);
        checks.checkDeployment(d, manager, owner, treasury, probe);
        // a treasury that refuses ETH
        vm.etch(treasury, hex"fe");
        vm.expectRevert("DuelDeploy: treasury refuses ETH");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        // one that takes a call without ETH, and refuses any carrying some: `if (callvalue) revert`
        vm.etch(treasury, hex"34156008575f5ffd5b00");
        (bool empty,) = treasury.call("");
        assertTrue(empty);
        vm.expectRevert("DuelDeploy: treasury refuses ETH");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        // and the probe needs the wei it sends
        vm.etch(treasury, "");
        vm.deal(address(probe), 0);
        vm.expectRevert("DuelDeploy: the probe needs one wei");
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }

    /// @dev The protocol's rate is part of a launch's state: a hook whose owner already lowered it is not as deployed.
    function test_checkDeployment_refusesAProtocolRateAlreadyLowered() public {
        DuelDeploy.Deployment memory d = _deployment();
        vm.prank(owner);
        factory.setProtocolRate(5000);
        vm.expectRevert("DuelDeploy: protocol rate");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        vm.prank(owner);
        factory.setProtocolRate(10_000);
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }

    /// @dev A router deployed later beside a deployment is checked with its contracts alone: by then the owner may have
    ///      changed the launch terms, opened the launches, lowered the protocol's rate, moved the treasury or offered
    ///      its role, each of which the launch's check refuses, though the deployment is sound.
    function test_checkContracts_passesADeploymentWhoseLaunchStateMoved() public {
        DuelDeploy.Deployment memory d = _deployment();
        checks.checkContracts(d, manager, owner);

        DuelFactory.Config memory other = factory.config();
        other.launchFee = 0.005 ether;
        other.treasury = alice;
        vm.startPrank(owner);
        factory.proposeConfig(other);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.applyConfig();
        factory.proposeConfig(other);
        factory.setPaused(false);
        factory.setProtocolRate(2500);
        factory.transferOwnership(bob);
        vm.stopPrank();
        vm.expectRevert("DuelDeploy: owner");
        checks.checkDeployment(d, manager, owner, treasury, probe);

        // with a new router: this build's, on the deployment's PoolManager
        d.router = new DuelRouter(manager);
        checks.checkContracts(d, manager, owner);
        // and what holds for a deployment's whole life is still checked
        d.router = new DuelRouter(IPoolManager(makeAddr("elsewhere")));
        vm.expectRevert("DuelDeploy: not on the PoolManager");
        checks.checkContracts(d, manager, owner);
        d = _deployment();
        _rebuilt(address(router));
        vm.expectRevert("DuelDeploy: router code");
        checks.checkContracts(d, manager, owner);
    }

    /// @dev A router deployed later is sent beside a deployment checked first, in the simulation: one of other
    ///      sources (here its lens) is refused before the broadcast, where script/Verify.s.sol refused it only once
    ///      the router had been sent, and its address was never written.
    function test_deployRouter_checksTheDeploymentBeforeSendingAnything() public {
        vm.setEnv("DUEL_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("POOL_MANAGER", vm.toString(address(manager)));
        vm.setEnv("POOL_MANAGER_CODEHASH", vm.toString(address(manager).codehash));
        vm.setEnv("DUEL_HOOK", vm.toString(address(hook)));
        vm.setEnv("DUEL_FACTORY", vm.toString(address(factory)));
        vm.setEnv("DUEL_LENS", vm.toString(address(lens)));
        DeployRouter script = new DeployRouter();
        DuelRouter deployed = script.run();
        assertEq(address(deployed.poolManager()), address(manager));
        _rebuilt(address(lens));
        vm.expectRevert("DuelDeploy: lens code");
        script.run();
    }

    /// @dev The same contract with one byte of its code changed (its last, of no use to a call): another build.
    function _rebuilt(address target) internal {
        bytes memory code = target.code;
        code[code.length - 1] = bytes1(uint8(code[code.length - 1]) ^ 0x01);
        vm.etch(target, code);
    }

    function test_checkDeployment_attestsEveryContractIsThisBuild() public {
        DuelDeploy.Deployment memory d = _deployment();
        address[4] memory parts = [address(hook), address(factory), address(router), address(lens)];
        string[4] memory names =
            ["DuelDeploy: hook code", "DuelDeploy: factory code", "DuelDeploy: router code", "DuelDeploy: lens code"];
        for (uint256 i; i < parts.length; i++) {
            bytes memory code = parts[i].code;
            // what other sources of the same version would deploy (a router without permits, say)
            _rebuilt(parts[i]);
            vm.expectRevert(bytes(names[i]));
            checks.checkDeployment(d, manager, owner, treasury, probe);
            vm.etch(parts[i], code);
        }
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }

    function test_everyContractNamesItsLaunchpad() public view {
        assertEq(hook.VERSION(), 1);
        assertEq(factory.VERSION(), 1);
        assertEq(router.VERSION(), 1);
        assertEq(lens.VERSION(), 1);
        assertEq(hook.CODENAME(), "Petunia");
        assertEq(factory.CODENAME(), "Petunia");
        assertEq(router.CODENAME(), "Petunia");
        assertEq(lens.CODENAME(), "Petunia");
    }

    function test_checkDeployment_refusesAContractOfAnotherLaunchpad() public {
        DuelDeploy.Deployment memory d = _deployment();
        address[4] memory parts = [address(hook), address(factory), address(router), address(lens)];
        for (uint256 i = 0; i < parts.length; ++i) {
            // another version
            vm.mockCall(parts[i], abi.encodeWithSignature("VERSION()"), abi.encode(uint256(2)));
            vm.expectRevert("DuelDeploy: versions");
            checks.checkDeployment(d, manager, owner, treasury, probe);
            vm.clearMockedCalls();
            // the same version, another name
            vm.mockCall(parts[i], abi.encodeWithSignature("CODENAME()"), abi.encode("Tulip"));
            vm.expectRevert("DuelDeploy: versions");
            checks.checkDeployment(d, manager, owner, treasury, probe);
            vm.clearMockedCalls();
        }
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }

    function test_checkDeployment_refusesAHookWithoutItsFlagsOrItsFactory() public {
        DuelDeploy.Deployment memory d = _deployment();
        d.hook = DuelHook(address(uint160(address(hook)) ^ 1));
        vm.expectRevert("DuelDeploy: hook flags");
        checks.checkDeployment(d, manager, owner, treasury, probe);
        // a hook whose factory is another: what a nonce used out of turn would leave behind
        d.hook = _otherHook();
        vm.expectRevert("DuelDeploy: hook and factory not linked");
        checks.checkDeployment(d, manager, owner, treasury, probe);
    }
}
