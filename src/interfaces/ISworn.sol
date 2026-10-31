// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one read the mainnet-only Sworn card check makes on the Sworn registry.
interface ISworn {
    function balanceOf(address owner) external view returns (uint256);
}
