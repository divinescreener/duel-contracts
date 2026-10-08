// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DuelHook} from "../src/DuelHook.sol";
import {DuelFactory} from "../src/DuelFactory.sol";
import {DuelLens} from "../src/DuelLens.sol";
import {DuelRouter} from "../src/DuelRouter.sol";
import {DuelDeploy} from "./DuelDeploy.sol";

/// @notice Deploys a new DuelRouter beside a deployment: the router holds nothing between transactions and nothing
///         trusts it (the hook applies its rules whoever routes a swap), so a new one takes over from the old for the
///         site alone, whose settings name it.
/// @dev Environment: DUEL_CHAIN_ID, POOL_MANAGER and POOL_MANAGER_CODEHASH as for script/Deploy.s.sol, and the
///      deployment the router joins: DUEL_HOOK, DUEL_FACTORY and DUEL_LENS. Before anything is sent, the deployment is
///      checked with a router simulated beside it, as script/Verify.s.sol checks it afterwards (its contracts alone,
///      DuelDeploy.checkContracts): one of other sources, or on another PoolManager, is refused here, where it was
///      refused only once the router had been sent, its address never written.
///      `forge script script/DeployRouter.s.sol --rpc-url robinhood --account deployer --broadcast`, then
///      script/Verify.s.sol with the new address as DUEL_ROUTER and DUEL_LAUNCH_STATE=false: the contracts alone, the
///      deployment's terms, pause and rate being by then wherever its owner took them.
contract DeployRouter is Script {
    function run() external returns (DuelRouter router) {
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DuelDeploy.ROBINHOOD_POOL_MANAGER));
        DuelDeploy.checkTarget(
            poolManager,
            vm.envUint("DUEL_CHAIN_ID"),
            DuelDeploy.expectedCodehash(poolManager, vm.envOr("POOL_MANAGER_CODEHASH", bytes32(0)))
        );
        // the deployment as it will be checked once the router is sent, with a router simulated in its place (created
        // outside the broadcast, it is never sent): its contracts this build's, linked, on this PoolManager (a router
        // on another would trade none of its pools). The owner is any address but zero, the factory's code not holding
        // it: the script's sender when none is given (a script's own address is refused by forge, which does not keep
        // it)
        DuelDeploy.Deployment memory d = DuelDeploy.Deployment({
            hook: DuelHook(vm.envAddress("DUEL_HOOK")),
            factory: DuelFactory(vm.envAddress("DUEL_FACTORY")),
            router: new DuelRouter(poolManager),
            lens: DuelLens(vm.envAddress("DUEL_LENS"))
        });
        DuelDeploy.checkContracts(d, poolManager, vm.envOr("DUEL_OWNER", msg.sender));

        vm.startBroadcast();
        router = new DuelRouter(poolManager);
        vm.stopBroadcast();

        require(
            DuelDeploy.sameCode(address(router), "DuelRouter.sol:DuelRouter", abi.encode(poolManager)),
            "DeployRouter: router code"
        );
        console2.log("chain      ", block.chainid);
        console2.log("DuelRouter ", address(router));
    }
}
