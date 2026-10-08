// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DuelHook} from "../src/DuelHook.sol";
import {DuelFactory} from "../src/DuelFactory.sol";

/// @notice Deploys the hook and the factory in one transaction, each naming the other: the hook through CREATE2 at
///         the salt the deploy script mined for this contract's address (the address carries the hook's permission
///         flags, which its constructor checks), then the factory through CREATE at the address the hook was given.
///         Only this contract can create at those addresses, and only the deployer's account can create this
///         contract at its own: nobody can deploy either of them first. Created anywhere else (another account, or
///         the deployer's at another nonce), it deploys nothing: the hook would not land where the script planned.
contract DuelBootstrap {
    DuelHook public immutable hook;
    DuelFactory public immutable factory;

    /// @param hookAddress where `salt` puts the hook from the address the script planned for this contract. Checked:
    ///        the flags alone would not do, as one salt in 16,384 gives them at another address too.
    constructor(
        IPoolManager poolManager,
        bytes32 salt,
        address hookAddress,
        address owner,
        DuelFactory.Config memory config
    ) {
        // a contract's nonce starts at 1: the hook takes it, the factory comes next
        address predicted = createAddress(address(this), 2);
        DuelHook hook_ = new DuelHook{salt: salt}(poolManager, predicted);
        require(address(hook_) == hookAddress, "DuelBootstrap: hook address");
        DuelFactory factory_ = new DuelFactory(poolManager, hook_, owner, config);
        require(address(factory_) == predicted, "DuelBootstrap: factory address");
        hook = hook_;
        factory = factory_;
    }

    /// @notice The address `deployer` creates at with CREATE and a nonce under 128.
    function createAddress(address deployer, uint8 nonce) public pure returns (address) {
        require(nonce > 0 && nonce < 0x80, "DuelBootstrap: nonce");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), deployer, bytes1(nonce))))));
    }
}
