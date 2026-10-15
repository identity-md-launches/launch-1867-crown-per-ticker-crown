// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Property tests for the challenge arithmetic (bond, quorum, slash split) exact to the wei, plus the
/// failure paths the unit suite does not reach: staking during the timelock, an invalid side, a dethroned king
/// challenging back, dust stakes, and the absence of any admin surface.
contract CrownMathTest is Test {
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant QUORUM = 0.05 ether;
    bytes32 internal constant TICKER = keccak256("CRWN");
    address internal constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    CrownRegistry internal registry;
    MockERC20 internal kingToken;
    MockERC20 internal challengerToken;
    address internal kingBeneficiary = makeAddr("kingBeneficiary");
    address internal challenger = makeAddr("challenger");

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new CrownRegistry();
        kingToken = new MockERC20("Crown Demo", "CRWN", 1);
        challengerToken = new MockERC20("Crown Demo", "CRWN", 1);
        registry.registerKing(TICKER, address(kingToken), kingBeneficiary);
        vm.deal(challenger, 100 ether);
    }

    function open(address token) internal returns (uint256 id) {
        vm.prank(challenger);
        id = registry.openChallenge{value: BOND}(TICKER, token);
    }

    function stakeAs(address who, uint256 id, CrownRegistry.Side side, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        registry.stake{value: amount}(id, side);
    }

    function claimAs(address who, uint256 id) internal returns (uint256 got) {
        uint256 before = who.balance;
        vm.prank(who);
        uint256 returned = registry.claim(id);
        got = who.balance - before;
        assertEq(got, returned, "claim() returned a different amount than it paid");
    }

    function isWon(uint256 id) internal view returns (bool won) {
        (,,,,,,, won,,,,,,) = registry.challenges(id);
    }

    // ------------------------------------------------------------------ slash split, to the wei

    /// @dev Five stakers of random sizes on random sides, plus the challenger's bond, claimed in a random order.
    /// Expected values are computed from the brief's rule, not from the contract.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_slashSplit_exactToTheWei(uint96[5] memory raw, uint8 sideBits, uint8 orderSeed) public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));

        address[5] memory stakers;
        uint256[5] memory amounts;
        bool[5] memory onChallenger;
        uint256 kingTotal;
        uint256 chalTotal = BOND;
        for (uint256 i; i < 5; ++i) {
            stakers[i] = makeAddr(string.concat("s", vm.toString(i)));
            amounts[i] = bound(uint256(raw[i]), 1, 5 ether);
            onChallenger[i] = (sideBits >> i) & 1 == 1;
            stakeAs(
                stakers[i], id, onChallenger[i] ? CrownRegistry.Side.Challenger : CrownRegistry.Side.King, amounts[i]
            );
            if (onChallenger[i]) chalTotal += amounts[i];
            else kingTotal += amounts[i];
        }

        bool expectWin = chalTotal > kingTotal && kingTotal + chalTotal >= QUORUM;
        (uint256 W, uint256 L) = expectWin ? (chalTotal, kingTotal) : (kingTotal, chalTotal);
        uint256 slash = L * 20 / 100;
        uint256 toWinners = W == 0 ? 0 : slash / 2;
        uint256 toTreasury = slash - toWinners;

        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id);
        assertEq(isWon(id), expectWin, "outcome");
        assertEq(TREASURY.balance, toTreasury, "treasury share");
        assertEq(registry.treasuryOwed(), 0);
        (,,,,, uint256 totalSlashed) = registry.tickerTotals(TICKER);
        assertEq(totalSlashed, slash);

        // claim in a rotated order so the "last claimer takes the remainder" rule is hit from every position
        uint256 winnersPaid;
        uint256 losersPaid;
        for (uint256 j; j < 6; ++j) {
            uint256 k = (j + orderSeed) % 6;
            if (k == 5) {
                uint256 got = claimAs(challenger, id);
                if (expectWin) {
                    assertGe(got, BOND, "challenger refunded in full when winning");
                    winnersPaid += got;
                } else {
                    assertLe(got, BOND * 8 / 10 + 8, "challenger keeps at most 80% plus dust when losing");
                    losersPaid += got;
                }
                continue;
            }
            uint256 paid = claimAs(stakers[k], id);
            bool winner = onChallenger[k] == expectWin;
            if (winner) {
                assertGe(paid, amounts[k], "a winner got less than its stake");
                winnersPaid += paid;
            } else {
                assertLe(paid, amounts[k] * 8 / 10 + 8, "a loser got more than 80% plus dust");
                losersPaid += paid;
            }
        }
        assertEq(winnersPaid, W + toWinners, "winning side: stake + half the slash, to the wei");
        assertEq(losersPaid, L - slash, "losing side: 80% of its stake, to the wei");
        assertEq(address(registry).balance, 0, "nothing left behind");
    }

    /// @dev One wei below quorum keeps the king even when the challenger out-stakes it; exactly at quorum it flips.
    function testFuzz_quorumBoundary(uint256 kingStake) public {
        kingStake = bound(kingStake, 0, 0.0199 ether);
        address loyalist = makeAddr("loyalist");
        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 id = open(address(challengerToken));
        uint256 chalStake = QUORUM - 1 - kingStake; // > kingStake, total one wei short of quorum
        stakeAs(challenger, id, CrownRegistry.Side.Challenger, chalStake - BOND);
        if (kingStake != 0) stakeAs(loyalist, id, CrownRegistry.Side.King, kingStake);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        vm.expectEmit(true, true, false, true, address(registry));
        emit CrownRegistry.ChallengeFailed(TICKER, id, kingStake, chalStake, uint64(vm.getBlockTimestamp() + 3 days));
        registry.finalize(id);
        (address t,,) = registry.king(TICKER);
        assertEq(t, address(kingToken), "one wei short of quorum keeps the king");

        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 id2 = open(address(challengerToken));
        chalStake = QUORUM - kingStake; // total exactly the quorum
        stakeAs(challenger, id2, CrownRegistry.Side.Challenger, chalStake - BOND);
        if (kingStake != 0) stakeAs(loyalist, id2, CrownRegistry.Side.King, kingStake);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id2);
        (t,,) = registry.king(TICKER);
        assertEq(t, address(challengerToken), "exactly the quorum flips");
        assertTrue(isWon(id2));
    }

    /// @dev Equal stakes never flip, whatever the size; one more wei on the challenger side does.
    function testFuzz_tieKeepsKing_oneWeiMoreFlips(uint256 amount) public {
        // both sides together always meet the quorum, so only the strict comparison decides
        amount = bound(amount, QUORUM / 2, 10 ether);
        address loyalist = makeAddr("loyalist");
        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 id = open(address(challengerToken));
        if (amount > BOND) stakeAs(challenger, id, CrownRegistry.Side.Challenger, amount - BOND);
        stakeAs(loyalist, id, CrownRegistry.Side.King, amount);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id);
        assertFalse(isWon(id), "a tie keeps the king");
        (address t,,) = registry.king(TICKER);
        assertEq(t, address(kingToken));
        // the tied challenger side is the losing side and is slashed
        assertEq(TREASURY.balance, amount * 20 / 100 - amount * 20 / 100 / 2);

        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 id2 = open(address(challengerToken));
        stakeAs(challenger, id2, CrownRegistry.Side.Challenger, amount - BOND + 1);
        stakeAs(loyalist, id2, CrownRegistry.Side.King, amount);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id2);
        assertTrue(isWon(id2), "one wei more flips");
    }

    /// @dev Any value but exactly the bond is refused, including zero and a generous overpayment.
    function testFuzz_wrongBond(uint256 value) public {
        value = bound(value, 0, 1 ether);
        vm.assume(value != BOND);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.WrongBond.selector);
        registry.openChallenge{value: value}(TICKER, address(challengerToken));
    }

    /// @dev Loser stakes of 1, 2 and 3 wei: the slash rounds to 1 wei, the winners' half rounds to zero, the first
    /// loser's share rounds to zero, and the last loser takes the exact remainder.
    function test_dustStakes_lastClaimerTakesExactRemainder() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));
        address a = makeAddr("a");
        address b = makeAddr("b");
        address c = makeAddr("c");
        stakeAs(a, id, CrownRegistry.Side.King, 1);
        stakeAs(b, id, CrownRegistry.Side.King, 2);
        stakeAs(c, id, CrownRegistry.Side.King, 3);
        stakeAs(challenger, id, CrownRegistry.Side.Challenger, 0.04 ether);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id);
        assertTrue(isWon(id));
        // L = 6 wei, slash = 1 wei, winners' half = 0, treasury = 1; losers share 5 wei
        assertEq(TREASURY.balance, 1);
        assertEq(registry.claimable(id, a), 0);
        assertEq(claimAs(a, id), 0, "rounds to zero but is recorded");
        assertTrue(registry.claimed(id, a));
        assertEq(claimAs(b, id), 2);
        assertEq(claimAs(c, id), 3, "the exact remainder");
        assertEq(claimAs(challenger, id), 0.05 ether, "winner refunded in full, no reward to round");
        assertEq(address(registry).balance, 0);
    }

    // ------------------------------------------------------------------ failure paths

    function test_timelock_windowClosedButNotFinalized_isStillLive() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.expectRevert(CrownRegistry.StakingClosed.selector);
        stakeAs(challenger, id, CrownRegistry.Side.King, 1);
        MockERC20 third = new MockERC20("Third", "CRWN", 1);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.ChallengeLive.selector);
        registry.openChallenge{value: BOND}(TICKER, address(third));
        vm.expectRevert(CrownRegistry.TimelockActive.selector);
        registry.finalize(id);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.NotFinalized.selector);
        registry.claim(id);
    }

    function test_stake_invalidSideIsRefused() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));
        vm.prank(challenger);
        (bool ok,) =
            address(registry).call{value: 1}(abi.encodeWithSelector(CrownRegistry.stake.selector, id, uint8(2)));
        assertFalse(ok, "side 2 must not be accepted");
        (,,,,,,,, uint256 kingStake, uint256 chalStake,,,,) = registry.challenges(id);
        assertEq(kingStake, 0);
        assertEq(chalStake, BOND);
    }

    function test_dethronedKing_canChallengeBackAfterMinReign() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));
        stakeAs(challenger, id, CrownRegistry.Side.Challenger, 0.04 ether);
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id);
        (address t, address b, uint64 since) = registry.king(TICKER);
        assertEq(t, address(challengerToken));
        assertEq(b, challenger);
        assertEq(since, vm.getBlockTimestamp());

        address loyalist = makeAddr("loyalist");
        vm.deal(loyalist, 1 ether);
        // the new king is itself protected for a week, then the old token can come back
        vm.prank(loyalist);
        vm.expectRevert(CrownRegistry.ReignTooShort.selector);
        registry.openChallenge{value: BOND}(TICKER, address(kingToken));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(loyalist);
        vm.expectRevert(CrownRegistry.SameToken.selector);
        registry.openChallenge{value: BOND}(TICKER, address(challengerToken));
        vm.prank(loyalist);
        uint256 id2 = registry.openChallenge{value: BOND}(TICKER, address(kingToken));
        (, address ct, address cb,,,,,,,,,,,) = registry.challenges(id2);
        assertEq(ct, address(kingToken));
        assertEq(cb, loyalist, "the opener, not the old beneficiary, would be paid");
    }

    function test_registerKing_rejectsZeroTickerAndCrownsOtherTickersIndependently() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 1);
        vm.expectRevert(CrownRegistry.TickerMismatch.selector);
        registry.registerKing(bytes32(0), address(other), kingBeneficiary);
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        registry.registerKing(keccak256("OTHR"), address(0), kingBeneficiary);
        registry.registerKing(keccak256("OTHR"), address(other), kingBeneficiary);
        (address t,,) = registry.king(keccak256("OTHR"));
        assertEq(t, address(other));
        (t,,) = registry.king(TICKER);
        assertEq(t, address(kingToken), "untouched");
        assertEq(registry.beneficiaryOf(keccak256("NONE")), address(0));
    }

    function test_finalize_isPermissionlessAndNotRepeatable() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 id = open(address(challengerToken));
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        vm.prank(makeAddr("stranger"));
        registry.finalize(id);
        vm.expectRevert(CrownRegistry.AlreadyFinalized.selector);
        registry.finalize(id);
        (uint256 active, uint64 cooldownUntil,,,,) = registry.tickerTotals(TICKER);
        assertEq(active, 0);
        assertEq(cooldownUntil, vm.getBlockTimestamp() + 3 days);
    }

    /// @dev No admin surface: the usual owner, pause, parameter and sweep selectors are all unknown to the registry.
    function test_noAdminFunctions() public {
        string[8] memory sigs = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "setTreasury(address)",
            "setBond(uint256)",
            "setQuorum(uint256)",
            "withdraw(uint256)",
            "sweep(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(registry).call(abi.encodeWithSignature(sigs[i], address(this), 1));
            assertFalse(ok, sigs[i]);
        }
        (bool okPlain,) = address(registry).call{value: 1}("");
        assertFalse(okPlain, "no receive(): stray ETH is refused");
    }
}
