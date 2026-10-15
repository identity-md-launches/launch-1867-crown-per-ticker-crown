// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";

/// @notice Deploys the standing challenger candidate for ticker CRWN: a distinct plain ERC-20 named "Crown Demo",
/// symbol CRWN, its whole supply minted to `holder`.
/// Usage: CHALLENGER_HOLDER=0x... forge script script/DeployChallenger.s.sol --rpc-url $RPC --broadcast
contract DeployChallenger is Script {
    function deploy(address holder) public returns (CrownChallengerToken) {
        return new CrownChallengerToken(holder);
    }

    function run() external returns (CrownChallengerToken token) {
        address holder = vm.envAddress("CHALLENGER_HOLDER");
        vm.startBroadcast();
        token = deploy(holder);
        vm.stopBroadcast();
    }
}
