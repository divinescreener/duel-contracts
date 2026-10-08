// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DuelRouter} from "../src/DuelRouter.sol";
import {DuelLens} from "../src/DuelLens.sol";
import {DuelDeploy, TreasuryProbe} from "./DuelDeploy.sol";

/// @notice Deploys Duel on Robinhood Chain (or a fork of it), then checks what it deployed.
/// @dev Environment:
///      - DUEL_CHAIN_ID          chain the deployment is for: 4663 (Robinhood Chain) or 46630 (its testnet); nothing
///                               is sent to another
///      - DUEL_OWNER             owner of the factory configuration (a multisig)
///      - DUEL_TREASURY          receiver of the protocol fees
///      - POOL_MANAGER           optional, defaults to the Robinhood Chain PoolManager
///      - POOL_MANAGER_CODEHASH  the PoolManager's code hash the operator expects there: needed on a public chain for
///                               another POOL_MANAGER; Robinhood Chain's is known (DuelDeploy)
///      Broadcast with the signer of your choice, e.g.
///      `forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast`, then check the chain
///      itself once the receipts are in with script/Verify.s.sol.
contract Deploy is Script {
    function run() external returns (DuelDeploy.Deployment memory d) {
        address owner = vm.envAddress("DUEL_OWNER");
        address treasury = vm.envAddress("DUEL_TREASURY");
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DuelDeploy.ROBINHOOD_POOL_MANAGER));
        DuelDeploy.checkTarget(
            poolManager,
            vm.envUint("DUEL_CHAIN_ID"),
            DuelDeploy.expectedCodehash(poolManager, vm.envOr("POOL_MANAGER_CODEHASH", bytes32(0)))
        );

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        // one transaction deploys the hook and the factory, through a bootstrap only this account can create
        (d.hook, d.factory) = DuelDeploy.deployCore(poolManager, owner, DuelDeploy.defaultConfig(treasury), deployer);
        d.router = new DuelRouter(poolManager);
        d.lens = new DuelLens(d.hook);
        vm.stopBroadcast();

        // simulated only: the probe that sends the treasury a wei (DuelDeploy.checkDeployment)
        TreasuryProbe probe = new TreasuryProbe();
        vm.deal(address(probe), 1);
        DuelDeploy.checkDeployment(d, poolManager, owner, treasury, probe);
        console2.log("chain      ", block.chainid);
        console2.log("DuelHook   ", address(d.hook));
        console2.log("DuelFactory", address(d.factory));
        console2.log("DuelRouter ", address(d.router));
        console2.log("DuelLens   ", address(d.lens));
    }
}
