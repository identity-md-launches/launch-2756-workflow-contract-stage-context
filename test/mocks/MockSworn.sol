// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A stand-in for the Sworn card registry: a settable balance per wallet.
contract MockSworn {
    mapping(address => uint256) public balanceOf;

    function setBalance(address owner, uint256 balance) external {
        balanceOf[owner] = balance;
    }
}
