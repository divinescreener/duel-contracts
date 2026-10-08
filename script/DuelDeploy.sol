// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {DuelHook} from "../src/DuelHook.sol";
import {DuelFactory} from "../src/DuelFactory.sol";
import {DuelRouter} from "../src/DuelRouter.sol";
import {DuelLens} from "../src/DuelLens.sol";
import {DuelVersion} from "../src/libraries/DuelVersion.sol";
import {DuelBootstrap} from "./DuelBootstrap.sol";

/// @title DuelDeploy
/// @notice Deployment helpers shared by the deploy script and the fork tests: the hook must live at an address whose
///         lowest 14 bits are its permission flags, so it is deployed with CREATE2 at a mined salt, and it names the
///         factory, which names it. A DuelBootstrap created by the deploying account deploys both in one transaction
///         (no shared CREATE2 deployer that anyone could use first, and no nonce planned across transactions).
library DuelDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The four contracts of a deployment.
    struct Deployment {
        DuelHook hook;
        DuelFactory factory;
        DuelRouter router;
        DuelLens lens;
    }

    /// @notice Uniswap V4 PoolManager on Robinhood Chain (mainnet and testnet share the address).
    address internal constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @notice The code hash of that PoolManager, the same on Robinhood Chain and its testnet (read from both, and
    ///         checked by test/fork): a deployment expects it there, so that another contract at that address, or a
    ///         node that lies about it, is refused before anything is sent.
    bytes32 internal constant ROBINHOOD_POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    /// @notice The chain id of a local node (anvil): the one chain where a deployment may expect
    ///         no code hash.
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    /// @notice Permission flags the hook address must carry: 0x2AEC.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Launch configuration of Duel v1.
    function defaultConfig(address treasury) internal pure returns (DuelFactory.Config memory) {
        return DuelFactory.Config({
            treasury: treasury,
            launchFee: 0.01 ether,
            startFdv: 1.68 ether,
            crossShareBps: 200,
            swapFeeBps: 120,
            switchFeeBps: 50,
            protocolShareBps: 3300,
            potShareBps: 3400,
            snipeStartBps: 9800,
            snipeWindow: 10
        });
    }

    /// @notice Creation code of the hook for a given factory.
    function hookInitCode(IPoolManager poolManager, address factory) internal pure returns (bytes memory) {
        return abi.encodePacked(type(DuelHook).creationCode, abi.encode(address(poolManager), factory));
    }

    /// @notice Finds a CREATE2 salt that puts the hook, created by `deployer`, at an address carrying exactly its flags.
    function mineSalt(bytes32 initCodeHash, address deployer)
        internal
        view
        returns (bytes32 salt, address hookAddress)
    {
        for (uint256 i = 0; i < 1_000_000; ++i) {
            hookAddress = vm.computeCreate2Address(bytes32(i), initCodeHash, deployer);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && hookAddress.code.length == 0) {
                return (bytes32(i), hookAddress);
            }
        }
        revert("DuelDeploy: no salt found");
    }

    /// @notice Deploys the hook and the factory in one transaction from `deployer` (the broadcasting account, or the
    ///         contract that runs this): a DuelBootstrap at `deployer`'s next address, the salt mined for it, which it
    ///         checks puts the hook where planned.
    function deployCore(IPoolManager poolManager, address owner, DuelFactory.Config memory config, address deployer)
        internal
        returns (DuelHook hook, DuelFactory factory)
    {
        address at = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        // the bootstrap's own nonce, 1 for the hook, then 2 for the factory
        address predictedFactory = vm.computeCreateAddress(at, 2);
        (bytes32 salt, address hookAddress) = mineSalt(keccak256(hookInitCode(poolManager, predictedFactory)), at);
        DuelBootstrap bootstrap = new DuelBootstrap(poolManager, salt, hookAddress, owner, config);
        require(address(bootstrap) == at, "DuelDeploy: bootstrap address mismatch");
        hook = bootstrap.hook();
        factory = bootstrap.factory();
        require(address(factory) == predictedFactory, "DuelDeploy: factory address mismatch");
    }

    /// @notice The code hash a deployment expects at `poolManager`: the operator's (POOL_MANAGER_CODEHASH), else the
    ///         one of Robinhood Chain's PoolManager at its address, else none.
    function expectedCodehash(IPoolManager poolManager, bytes32 given) internal pure returns (bytes32) {
        if (given != bytes32(0)) return given;
        return address(poolManager) == ROBINHOOD_POOL_MANAGER ? ROBINHOOD_POOL_MANAGER_CODEHASH : bytes32(0);
    }

    /// @notice Checks the target of a deployment before anything is sent: the chain the operator names, and the
    ///         PoolManager there, with the code expected (expectedCodehash). Only a local node may expect none.
    function checkTarget(IPoolManager poolManager, uint256 chainId, bytes32 codehash) internal view {
        require(block.chainid == chainId, "DuelDeploy: not the chain named");
        require(address(poolManager).code.length != 0, "DuelDeploy: no PoolManager there");
        require(codehash != bytes32(0) || chainId == LOCAL_CHAIN_ID, "DuelDeploy: POOL_MANAGER_CODEHASH needed");
        require(
            codehash == bytes32(0) || address(poolManager).codehash == codehash,
            "DuelDeploy: not the PoolManager code expected"
        );
    }

    /// @notice Checks a deployment as it stands at its launch: its contracts (checkContracts: the hook at an address
    ///         carrying its flags, the hook and the factory naming each other, every contract on `poolManager`, the lens
    ///         reading the hook, every contract of the same launchpad, each one's code this build's), the factory owned
    ///         by `owner` with no transfer pending, its fees going to `treasury`, its launch terms this version's with
    ///         none waiting and launches still paused (as the factory is born: its owner launches the first pair, then
    ///         opens them), the protocol taking its whole share, and the treasury taking ETH (`probe`,
    ///         created and given a wei in a simulation after the broadcast, sends it one). Nothing of it reaches the
    ///         chain. The hook names its factory for good: a mismatch here means deploying again.
    function checkDeployment(
        Deployment memory d,
        IPoolManager poolManager,
        address owner,
        address treasury,
        TreasuryProbe probe
    ) internal {
        checkLinks(d, poolManager);
        require(d.factory.owner() == owner && d.factory.pendingOwner() == address(0), "DuelDeploy: owner");
        require(d.factory.config().treasury == treasury, "DuelDeploy: treasury");
        // the terms every launch gets: a factory deployed with others within the bounds passed the checks above
        require(
            keccak256(abi.encode(d.factory.config())) == keccak256(abi.encode(defaultConfig(treasury))),
            "DuelDeploy: launch terms"
        );
        // born paused: opened already, anyone may have launched before the owner's first pair
        require(d.factory.pendingConfigEta() == 0 && d.factory.paused(), "DuelDeploy: terms pending, or launches open");
        // as the hook is deployed: the protocol takes the share each duel's terms give it, all of it
        require(d.hook.protocolRateBps() == 10_000, "DuelDeploy: protocol rate");
        // what claimProtocolFees pays it with: a call carrying ETH, which a treasury taking only empty calls refuses
        require(address(probe).balance != 0, "DuelDeploy: the probe needs one wei");
        require(probe.pay(treasury), "DuelDeploy: treasury refuses ETH");
        checkCode(d, poolManager, owner);
    }

    /// @notice Checks a deployment's contracts alone, which hold for its whole life: what checkDeployment checks but the
    ///         state of its launch (the owner, the treasury, the terms, the pause, the protocol's rate), which the
    ///         owner moves afterwards. A router deployed later beside a deployment (script/DeployRouter.s.sol) is
    ///         checked so: with the launch's terms changed since, or launches opened, checkDeployment would refuse a
    ///         deployment that is sound. `owner` is any address but zero: the factory's code does not hold it.
    function checkContracts(Deployment memory d, IPoolManager poolManager, address owner) internal {
        checkLinks(d, poolManager);
        checkCode(d, poolManager, owner);
    }

    /// @notice The hook at an address carrying its flags, the hook and the factory naming each other, every contract on
    ///         `poolManager`, the lens reading the hook, and every contract of the same launchpad (its version and its
    ///         code name, DuelVersion).
    function checkLinks(Deployment memory d, IPoolManager poolManager) internal view {
        require(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "DuelDeploy: hook flags");
        require(
            d.hook.factory() == address(d.factory) && address(d.factory.hook()) == address(d.hook),
            "DuelDeploy: hook and factory not linked"
        );
        require(
            address(d.hook.poolManager()) == address(poolManager)
                && address(d.factory.poolManager()) == address(poolManager)
                && address(d.router.poolManager()) == address(poolManager)
                && address(d.lens.poolManager()) == address(poolManager),
            "DuelDeploy: not on the PoolManager"
        );
        require(address(d.lens.hook()) == address(d.hook), "DuelDeploy: lens not on the hook");
        // one launchpad: every contract of the same version, of the same name
        bytes32 codename = keccak256(bytes(DuelVersion.CODENAME));
        require(
            d.hook.VERSION() == DuelVersion.NUMBER && d.factory.VERSION() == DuelVersion.NUMBER
                && d.router.VERSION() == DuelVersion.NUMBER && d.lens.VERSION() == DuelVersion.NUMBER
                && keccak256(bytes(d.hook.CODENAME())) == codename && keccak256(bytes(d.factory.CODENAME())) == codename
                && keccak256(bytes(d.router.CODENAME())) == codename && keccak256(bytes(d.lens.CODENAME())) == codename,
            "DuelDeploy: versions"
        );
    }

    /// @notice Each contract's code this build's, byte for byte: the code its constructor arguments give here, run in
    ///         the simulation (sameCode). A launchpad of the same version built from other sources (one without
    ///         permits, say) fails there.
    function checkCode(Deployment memory d, IPoolManager poolManager, address owner) internal {
        require(
            sameCode(address(d.hook), "DuelHook.sol:DuelHook", abi.encode(poolManager, address(d.factory))),
            "DuelDeploy: hook code"
        );
        require(
            sameCode(
                address(d.factory),
                "DuelFactory.sol:DuelFactory",
                abi.encode(poolManager, d.hook, owner, d.factory.config())
            ),
            "DuelDeploy: factory code"
        );
        require(
            sameCode(address(d.router), "DuelRouter.sol:DuelRouter", abi.encode(poolManager)), "DuelDeploy: router code"
        );
        require(sameCode(address(d.lens), "DuelLens.sol:DuelLens", abi.encode(d.hook)), "DuelDeploy: lens code");
    }

    /// @notice Whether `deployed` holds the code that this build's `artifact` gives with `args`: its creation code run
    ///         as a call, in the simulation, at an address carrying the hook's flags (which the hook's constructor
    ///         checks). Immutables included, the code is the same byte for byte, or the sources were not these.
    function sameCode(address deployed, string memory artifact, bytes memory args) internal returns (bool) {
        address at = address(
            (uint160(uint256(keccak256(abi.encode("DuelDeploy: copy of", deployed)))) & ~Hooks.ALL_HOOK_MASK)
                | HOOK_FLAGS
        );
        vm.etch(at, abi.encodePacked(vm.getCode(artifact), args));
        (bool ok, bytes memory runtime) = at.call("");
        vm.etch(at, "");
        return ok && keccak256(runtime) == keccak256(deployed.code);
    }
}

/// @notice Sends a treasury one wei, as claimProtocolFees pays it, to check that it takes ETH. The scripts create it and
///         give it the wei in their simulation (a script's own address is not to be relied upon), so that nothing
///         reaches the chain.
contract TreasuryProbe {
    function pay(address treasury) external returns (bool ok) {
        (ok,) = treasury.call{value: 1}("");
    }
}
