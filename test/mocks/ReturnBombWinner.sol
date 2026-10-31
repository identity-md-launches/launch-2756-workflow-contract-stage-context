// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Code a winning wallet can carry (an EIP-7702 delegation on Sepolia or mainnet): it answers
/// an ETH transfer with a payload sized to the gas it was given, as revert data or as return data, so
/// that a payer which copies the payload into memory runs out of gas however much it brought. A payer
/// that copies nothing only sees the call fail (or succeed with the return-data variant).
contract ReturnBombWinner {
    bool public returnsInsteadOfReverting;

    function setReturns(bool value) external {
        returnsInsteadOfReverting = value;
    }

    receive() external payable {
        bool ret = returnsInsteadOfReverting;
        assembly ("memory-safe") {
            let g := mul(div(gas(), 10), 9)
            // n words whose expansion costs about g: n*n/512 ~= g, so n ~= sqrt(512 g).
            let x := mul(g, 512)
            let n := x
            let y := div(add(n, 1), 2)
            for {} lt(y, n) {} {
                n := y
                y := div(add(div(x, y), y), 2)
            }
            // Leave the payer's memory alone: the payload lives in this frame only.
            if ret { return(0, mul(n, 32)) }
            revert(0, mul(n, 32))
        }
    }
}
