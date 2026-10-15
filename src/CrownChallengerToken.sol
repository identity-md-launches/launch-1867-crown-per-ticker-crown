// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CrownChallengerToken
/// @notice A second, distinct plain ERC-20 with the same name and symbol as the launch token ("Crown Demo", CRWN). It
/// is the standing challenger candidate for ticker CRWN, deployed by script/DeployChallenger.s.sol after launch.
/// Fixed supply minted once to `holder`; no owner and no other functions.
contract CrownChallengerToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    error ZeroHolder();

    constructor(address holder) ERC20("Crown Demo", "CRWN") {
        if (holder == address(0)) revert ZeroHolder();
        _mint(holder, SUPPLY);
    }
}
