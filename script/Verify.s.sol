// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DuelHook} from "../src/DuelHook.sol";
import {DuelFactory} from "../src/DuelFactory.sol";
import {DuelRouter} from "../src/DuelRouter.sol";
import {DuelLens} from "../src/DuelLens.sol";
import {DuelDeploy, TreasuryProbe} from "./DuelDeploy.sol";

/// @notice Checks a deployment on the chain itself, once its receipts are in: nothing is sent.
/// @dev Environment: DUEL_CHAIN_ID, DUEL_OWNER, DUEL_TREASURY, POOL_MANAGER and POOL_MANAGER_CODEHASH as for
///      script/Deploy.s.sol, and the four addresses it printed: DUEL_HOOK, DUEL_FACTORY, DUEL_ROUTER, DUEL_LENS.
///      `forge script script/Verify.s.sol --rpc-url robinhood`
///      DUEL_LAUNCH_STATE=false checks the contracts alone, not the state a deployment has at its launch (its owner,
///      its treasury, its launch terms with none pending, launches open, the protocol's whole rate), which the owner
///      moves afterwards: for a router deployed later (script/DeployRouter.s.sol), whenever that is.
contract Verify is Script {
    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DuelDeploy.ROBINHOOD_POOL_MANAGER));
        DuelDeploy.checkTarget(
            poolManager,
            vm.envUint("DUEL_CHAIN_ID"),
            DuelDeploy.expectedCodehash(poolManager, vm.envOr("POOL_MANAGER_CODEHASH", bytes32(0)))
        );
        DuelDeploy.Deployment memory d = DuelDeploy.Deployment({
            hook: DuelHook(vm.envAddress("DUEL_HOOK")),
            factory: DuelFactory(vm.envAddress("DUEL_FACTORY")),
            router: DuelRouter(vm.envAddress("DUEL_ROUTER")),
            lens: DuelLens(vm.envAddress("DUEL_LENS"))
        });
        if (!vm.envOr("DUEL_LAUNCH_STATE", true)) {
            DuelDeploy.checkContracts(d, poolManager, vm.envAddress("DUEL_OWNER"));
            console2.log("Duel contracts checked on chain", block.chainid);
            return;
        }
        // simulated only: the probe that sends the treasury a wei (DuelDeploy.checkDeployment)
        TreasuryProbe probe = new TreasuryProbe();
        vm.deal(address(probe), 1);
        DuelDeploy.checkDeployment(d, poolManager, vm.envAddress("DUEL_OWNER"), vm.envAddress("DUEL_TREASURY"), probe);
        console2.log("Duel deployment checked on chain", block.chainid);
    }
}
