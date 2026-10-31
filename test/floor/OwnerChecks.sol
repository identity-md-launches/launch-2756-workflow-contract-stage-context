// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared owner checks for launch contracts: a contract that exposes an owner must not name
/// the launch factory or IMD's launch wallet (standing in as `ORIGIN_PROBE`) as that owner.
abstract contract OwnerChecks is Test {
    /// @dev Where IMD's launch wallet stands in the floor: `tx.origin` while the hook is deployed.
    address internal constant ORIGIN_PROBE = address(0x0000000000000000000000000000000000000716);

    function checkOwner(string memory name, address target, address factory) internal view {
        string[3] memory getters = ["owner()", "admin()", "getOwner()"];
        for (uint256 i = 0; i < getters.length; i++) {
            (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(getters[i]));
            if (!ok || ret.length != 32) continue;
            address holder = abi.decode(ret, (address));
            assertTrue(holder != factory, string.concat(name, " is owned by the launch factory"));
            assertTrue(holder != ORIGIN_PROBE, string.concat(name, " is owned by IMD's launch wallet"));
        }
    }
}
