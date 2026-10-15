// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CrownToken
/// @notice The launch token: "Crown Demo" (CRWN), a fixed supply of 1,000,000,000 tokens at 18 decimals minted once to
/// the deployer (the launch factory). No mint, owner, pause, blocklist, fee or upgrade functions.
contract CrownToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Crown Demo", "CRWN") {
        _mint(msg.sender, SUPPLY);
    }
}
