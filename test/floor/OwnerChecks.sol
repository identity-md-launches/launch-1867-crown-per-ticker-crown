// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Checks that a contract is not owned or administered by the launch factory or by IMD's launch wallet.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` when the hook is deployed.
    address internal constant ORIGIN_PROBE = address(uint160(uint256(keccak256("imd.floor.origin-probe"))));

    function checkOwner(string memory name, address target, address factory_) internal view {
        string[4] memory getters = ["owner()", "admin()", "getOwner()", "governance()"];
        for (uint256 i; i < getters.length; ++i) {
            (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(getters[i]));
            if (!ok || data.length != 32) continue;
            address holder = abi.decode(data, (address));
            assertTrue(holder != factory_, string.concat(name, " is administered by the launch factory: ", getters[i]));
            assertTrue(
                holder != ORIGIN_PROBE, string.concat(name, " is administered by IMD's launch wallet: ", getters[i])
            );
        }
    }
}
