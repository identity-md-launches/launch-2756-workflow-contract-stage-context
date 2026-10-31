// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A contract that refuses ETH until told otherwise, standing in for a winner wallet that
/// cannot receive a payout.
contract RejectingWinner {
    bool public accepting;

    function setAccepting(bool value) external {
        accepting = value;
    }

    function withdrawFrom(address hook) external {
        (bool ok, bytes memory ret) = hook.call(abi.encodeWithSignature("withdrawOwed()"));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    receive() external payable {
        require(accepting, "no ETH please");
    }
}
