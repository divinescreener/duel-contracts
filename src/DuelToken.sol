// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {DuelVersion} from "./libraries/DuelVersion.sol";

/// @title DuelToken
/// @notice Plain fixed-supply ERC-20 used for both sides of a Duel pair, with EIP-2612 permits: a holder approves by
///         signature, so that a sale through DuelRouter takes one transaction (`swapExactInWithPermit`). Every Duel
///         token's permits are signed in an EIP-712 domain named "Duel" (version "1"): with this token's address and
///         chain, it is its own. Not the token's name: OpenZeppelin's domain names fit 31 bytes, a token's 128.
/// @dev No owner, no transfer hooks, no taxes, no blacklist and no minting after deployment: the whole supply is
///      minted once to the factory, which seeds it into the pair's Uniswap V4 pools in the same transaction.
contract DuelToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Fixed supply of every Duel token (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice Version of the launchpad that launched this token (DuelVersion): a later launchpad's tokens say theirs.
    uint256 public constant LAUNCHPAD_VERSION = DuelVersion.NUMBER;
    /// @notice Code name of that launchpad's version.
    string public constant LAUNCHPAD_CODENAME = DuelVersion.CODENAME;

    /// @notice Pointer to the pair's off-chain metadata (image, description, links), set once at deployment.
    string public metadataURI;

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param metadataURI_ Metadata pointer shared by both sides of the pair.
    /// @param recipient Receiver of the whole supply (the factory).
    constructor(string memory name_, string memory symbol_, string memory metadataURI_, address recipient)
        ERC20(name_, symbol_)
        ERC20Permit("Duel")
    {
        metadataURI = metadataURI_;
        _mint(recipient, TOTAL_SUPPLY);
    }
}
