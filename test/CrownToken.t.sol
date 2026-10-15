// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownToken} from "../src/CrownToken.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DeployChallenger} from "../script/DeployChallenger.s.sol";
import {DeployCrown} from "../script/DeployCrown.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract CrownTokenTest is Test {
    function test_launchToken_fixedSupplyToDeployer() public {
        CrownToken t = new CrownToken();
        assertEq(t.name(), "Crown Demo");
        assertEq(t.symbol(), "CRWN");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.balanceOf(address(this)), 1_000_000_000 ether);
        address to = makeAddr("to");
        assertTrue(t.transfer(to, 123 ether));
        assertEq(t.balanceOf(to), 123 ether);
        assertEq(t.totalSupply(), 1_000_000_000 ether);
    }

    function test_challengerScript_deploysDistinctSameTickerToken() public {
        address holder = makeAddr("holder");
        CrownChallengerToken c = new DeployChallenger().deploy(holder);
        CrownToken t = new CrownToken();
        assertTrue(address(c) != address(t));
        assertEq(c.name(), t.name());
        assertEq(c.symbol(), t.symbol());
        assertEq(c.balanceOf(holder), c.totalSupply());

        CrownRegistry r = new CrownRegistry();
        bytes32 ticker = r.tickerOf("CRWN");
        r.registerKing(ticker, address(t), holder);
        vm.warp(block.timestamp + 7 days);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        r.openChallenge{value: 0.01 ether}(ticker, address(c));
    }

    function test_challengerToken_rejectsZeroHolder() public {
        vm.expectRevert(CrownChallengerToken.ZeroHolder.selector);
        new CrownChallengerToken(address(0));
    }

    function test_deployScript_minesFlagAddress() public {
        DeployCrown s = new DeployCrown();
        DeployCrown.Config memory cfg =
            DeployCrown.Config(IPoolManager(makeAddr("pm")), makeAddr("factory"), makeAddr("owner"));
        bytes memory code = s.initCode(cfg);
        (bytes32 salt, address at) = s.mineSalt(address(this), code);
        assertTrue(HookFlags.matches(at, HookFlags.CROWN_HOOK));
        address deployed;
        assembly {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        assertEq(deployed, at);
        assertEq(CrownHook(deployed).owner(), cfg.owner);
    }
}
