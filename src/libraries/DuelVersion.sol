// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DuelVersion
/// @notice The launchpad these contracts make up: its version, and the code name it goes by. Every contract of the
///         launchpad answers them, and every token it launches keeps them, so that a token says which launchpad
///         launched it. A launchpad deployed later counts on (2, with a code name of its own).
library DuelVersion {
    /// @notice Version of the launchpad.
    uint256 internal constant NUMBER = 1;
    /// @notice Code name of the launchpad's version.
    string internal constant CODENAME = "Petunia";
}
