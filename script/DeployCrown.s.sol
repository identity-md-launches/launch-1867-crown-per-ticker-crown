// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Manual deployment of CrownHook (and the CrownRegistry it creates) through the deterministic CREATE2
/// deployer, at an address mined for the hook's permission flags. The IMD launch deploys through its own factory
/// instead; this script is for rehearsals and for additional deployments.
/// Usage: POOL_MANAGER=0x... HOOK_FACTORY=0x... HOOK_OWNER=0x... forge script script/DeployCrown.s.sol --broadcast
contract DeployCrown is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        IPoolManager poolManager;
        address factory;
        address owner;
    }

    function initCode(Config memory cfg) public pure returns (bytes memory) {
        return abi.encodePacked(type(CrownHook).creationCode, abi.encode(cfg.poolManager, cfg.factory, cfg.owner));
    }

    /// @notice The first salt whose CREATE2 address from `deployer` carries exactly CrownHook's flags.
    function mineSalt(address deployer, bytes memory code) public pure returns (bytes32 salt, address at) {
        bytes32 codeHash = keccak256(code);
        for (uint256 i; i < 500_000; ++i) {
            salt = bytes32(i);
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
            if (HookFlags.matches(at, HookFlags.CROWN_HOOK)) return (salt, at);
        }
        revert("no salt found");
    }

    function run() external returns (CrownHook hook) {
        Config memory cfg = Config(
            IPoolManager(vm.envAddress("POOL_MANAGER")), vm.envAddress("HOOK_FACTORY"), vm.envAddress("HOOK_OWNER")
        );
        bytes memory code = initCode(cfg);
        (bytes32 salt, address at) = mineSalt(CREATE2_DEPLOYER, code);
        vm.startBroadcast();
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, code));
        vm.stopBroadcast();
        require(ok && at.code.length != 0, "deploy failed");
        hook = CrownHook(at);
    }
}
