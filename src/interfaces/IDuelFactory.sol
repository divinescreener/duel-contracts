// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDuelFactory
/// @notice Part of the factory the hook relies on.
interface IDuelFactory {
    /// @notice Receiver of the protocol's share of the fees.
    function treasury() external view returns (address);
}
