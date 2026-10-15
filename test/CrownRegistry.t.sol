// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RejectEther {
    receive() external payable {
        revert("no");
    }
}

contract ReentrantStaker {
    CrownRegistry internal immutable registry;
    uint256 internal id;
    uint256 public reentered;

    constructor(CrownRegistry r) {
        registry = r;
    }

    function stakeOn(uint256 challengeId, CrownRegistry.Side side) external payable {
        id = challengeId;
        registry.stake{value: msg.value}(challengeId, side);
    }

    function claimIt() external {
        registry.claim(id);
    }

    receive() external payable {
        if (reentered == 0) {
            reentered = 1;
            try registry.claim(id) {
                reentered = 2;
            } catch {}
        }
    }
}

contract CrownRegistryTest is Test {
    CrownRegistry registry;
    MockERC20 kingToken;
    MockERC20 challengerToken;
    bytes32 constant TICKER = keccak256("CRWN");
    address constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    address kingBeneficiary = makeAddr("kingBeneficiary");
    address challenger = makeAddr("challenger");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_000_000);
        registry = new CrownRegistry();
        kingToken = new MockERC20("Crown Demo", "CRWN", 1);
        challengerToken = new MockERC20("Crown Demo", "crwn", 1);
        registry.registerKing(TICKER, address(kingToken), kingBeneficiary);
        vm.deal(challenger, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function open() internal returns (uint256 id) {
        vm.warp(block.timestamp + 7 days);
        vm.prank(challenger);
        id = registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
    }

    function stakeAs(address who, uint256 id, CrownRegistry.Side side, uint256 amount) internal {
        vm.prank(who);
        registry.stake{value: amount}(id, side);
    }

    function claimAs(address who, uint256 id) internal returns (uint256 got) {
        uint256 before = who.balance;
        vm.prank(who);
        registry.claim(id);
        got = who.balance - before;
    }

    function finalizeAfterWindow(uint256 id) internal {
        vm.warp(block.timestamp + 96 hours);
        registry.finalize(id);
    }

    // ------------------------------------------------------------------ registration

    function test_registerKing_crownsFirstRegistration() public view {
        (address t, address b, uint64 since) = registry.king(TICKER);
        assertEq(t, address(kingToken));
        assertEq(b, kingBeneficiary);
        assertEq(since, 1_000_000);
        assertEq(registry.tickerOf("cRwN"), TICKER);
    }

    function test_registerKing_rejectsSecondRegistration() public {
        vm.expectRevert(CrownRegistry.AlreadyCrowned.selector);
        registry.registerKing(TICKER, address(challengerToken), alice);
    }

    function test_registerKing_rejectsWrongSymbolZeroAndCodeless() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 1);
        vm.expectRevert(CrownRegistry.TickerMismatch.selector);
        registry.registerKing(keccak256("NEW"), address(other), alice);
        vm.expectRevert(CrownRegistry.TickerMismatch.selector);
        registry.registerKing(keccak256("NEW"), address(0xBEEF), alice);
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        registry.registerKing(keccak256("OTHR"), address(other), address(0));
    }

    // ------------------------------------------------------------------ opening

    function test_openChallenge_requiresExactBond() public {
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(challenger);
        vm.expectRevert(CrownRegistry.WrongBond.selector);
        registry.openChallenge{value: 0.0099 ether}(TICKER, address(challengerToken));
        vm.expectRevert(CrownRegistry.WrongBond.selector);
        registry.openChallenge{value: 0.02 ether}(TICKER, address(challengerToken));
        uint256 id = registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
        vm.stopPrank();
        assertEq(registry.stakeOf(id, challenger, CrownRegistry.Side.Challenger), 0.01 ether);
        assertEq(address(registry).balance, 0.01 ether);
    }

    function test_openChallenge_minimumReignBoundary() public {
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.ReignTooShort.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
        vm.warp(block.timestamp + 1);
        vm.prank(challenger);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
    }

    function test_openChallenge_oneLiveChallengePerTicker() public {
        open();
        MockERC20 third = new MockERC20("Third", "CRWN", 1);
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.ChallengeLive.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(third));
    }

    function test_openChallenge_rejectsSameTokenWrongTickerAndNoKing() public {
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(challenger);
        vm.expectRevert(CrownRegistry.SameToken.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(kingToken));
        MockERC20 other = new MockERC20("Other", "OTHR", 1);
        vm.expectRevert(CrownRegistry.TickerMismatch.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(other));
        vm.expectRevert(CrownRegistry.NoKing.selector);
        registry.openChallenge{value: 0.01 ether}(keccak256("OTHR"), address(other));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ staking window

    function test_stake_windowBoundaryAndZero() public {
        uint256 id = open();
        (,,,, uint64 endsAt,,,,,,,,,) = registry.challenges(id);
        assertEq(endsAt, block.timestamp + 72 hours);
        vm.expectRevert(CrownRegistry.ZeroStake.selector);
        stakeAs(alice, id, CrownRegistry.Side.King, 0);
        vm.warp(endsAt - 1);
        stakeAs(alice, id, CrownRegistry.Side.King, 1 ether);
        vm.warp(endsAt);
        vm.expectRevert(CrownRegistry.StakingClosed.selector);
        stakeAs(alice, id, CrownRegistry.Side.King, 1 ether);
        vm.expectRevert(CrownRegistry.UnknownChallenge.selector);
        stakeAs(alice, 99, CrownRegistry.Side.King, 1 ether);
    }

    function test_finalize_timelockBoundary() public {
        uint256 id = open();
        vm.warp(block.timestamp + 96 hours - 1);
        vm.expectRevert(CrownRegistry.TimelockActive.selector);
        registry.finalize(id);
        vm.warp(block.timestamp + 1);
        registry.finalize(id);
        vm.expectRevert(CrownRegistry.AlreadyFinalized.selector);
        registry.finalize(id);
        vm.expectRevert(CrownRegistry.UnknownChallenge.selector);
        registry.finalize(42);
    }

    // ------------------------------------------------------------------ resolution math

    function test_dethrone_slashSplitExactToTheWei() public {
        uint256 id = open(); // challenger bonds 0.01 on the challenger side
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.04 ether);
        stakeAs(bob, id, CrownRegistry.Side.King, 0.02 ether);
        stakeAs(carol, id, CrownRegistry.Side.King, 0.01 ether);

        vm.expectEmit(true, true, false, true, address(registry));
        emit CrownRegistry.Dethroned(
            TICKER, id, address(kingToken), address(challengerToken), challenger, 0.03 ether, 0.05 ether
        );
        finalizeAfterWindow(id);

        (address t, address b, uint64 since) = registry.king(TICKER);
        assertEq(t, address(challengerToken));
        assertEq(b, challenger);
        assertEq(since, block.timestamp);

        // losers 0.03: slash 0.006 => 0.003 to winners, 0.003 to treasury; losers keep 0.024
        assertEq(TREASURY.balance, 0.003 ether);
        assertEq(claimAs(bob, id), 0.016 ether);
        assertEq(claimAs(carol, id), 0.008 ether);
        // winners 0.05 stake + 0.003 reward, pro rata
        assertEq(claimAs(challenger, id), 0.0106 ether);
        assertEq(claimAs(alice, id), 0.0424 ether);
        assertEq(address(registry).balance, 0);

        (,,, uint64 dethrones, uint256 totalStaked, uint256 totalSlashed) = registry.tickerTotals(TICKER);
        assertEq(dethrones, 1);
        assertEq(totalStaked, 0.08 ether);
        assertEq(totalSlashed, 0.006 ether);
    }

    function test_failedChallenge_belowQuorumSlashesChallengersAndCoolsDown() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.03 ether); // challenger side 0.04
        stakeAs(bob, id, CrownRegistry.Side.King, 0.005 ether); // total 0.045 < quorum
        finalizeAfterWindow(id);

        (address t,,) = registry.king(TICKER);
        assertEq(t, address(kingToken), "king kept below quorum");
        // losers 0.04: slash 0.008 => 0.004 to bob, 0.004 to treasury
        assertEq(TREASURY.balance, 0.004 ether);
        assertEq(claimAs(bob, id), 0.009 ether);
        assertEq(claimAs(challenger, id), 0.008 ether);
        assertEq(claimAs(alice, id), 0.024 ether);
        assertEq(address(registry).balance, 0);

        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.CoolingDown.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
        vm.warp(block.timestamp + 3 days);
        vm.prank(challenger);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
    }

    function test_tie_keepsTheKing() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.04 ether);
        stakeAs(bob, id, CrownRegistry.Side.King, 0.05 ether);
        finalizeAfterWindow(id);
        (address t,,) = registry.king(TICKER);
        assertEq(t, address(kingToken));
        (,,,,,,, bool won,,,,,,) = registry.challenges(id);
        assertFalse(won);
    }

    function test_unopposedChallengeBelowQuorum_sendsWholeSlashToTreasury() public {
        uint256 id = open();
        finalizeAfterWindow(id);
        assertEq(TREASURY.balance, 0.002 ether);
        assertEq(claimAs(challenger, id), 0.008 ether);
        assertEq(address(registry).balance, 0);
    }

    function test_unopposedChallengeAtQuorum_dethronesAndRefundsInFull() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.04 ether);
        finalizeAfterWindow(id);
        (address t,,) = registry.king(TICKER);
        assertEq(t, address(challengerToken));
        assertEq(claimAs(challenger, id), 0.01 ether);
        assertEq(claimAs(alice, id), 0.04 ether);
        assertEq(TREASURY.balance, 0);
    }

    function test_newKingMustReignSevenDays() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.05 ether);
        stakeAs(bob, id, CrownRegistry.Side.King, 0.01 ether); // a defended king: the flip restarts the clock
        finalizeAfterWindow(id);
        (,, uint64 since) = registry.king(TICKER);
        assertEq(since, block.timestamp);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.ReignTooShort.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(kingToken));
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(kingToken));
    }

    function test_uncontestedFlip_doesNotRestartTheReignClock() public {
        (,, uint64 sinceBefore) = registry.king(TICKER);
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.04 ether); // nobody defends the king
        finalizeAfterWindow(id);
        (address t, address b, uint64 since) = registry.king(TICKER);
        assertEq(t, address(challengerToken));
        assertEq(b, challenger);
        assertEq(since, sinceBefore, "an undefended crown passes with the clock untouched");
        (,,, uint64 dethrones,,) = registry.tickerTotals(TICKER);
        assertEq(dethrones, 1);
        // the new king is challengeable at once: a free flip buys no immunity
        vm.prank(alice);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(kingToken));
    }

    function test_openChallenge_refusesTheSittingBeneficiary() public {
        vm.warp(block.timestamp + 7 days);
        vm.deal(kingBeneficiary, 1 ether);
        vm.prank(kingBeneficiary);
        vm.expectRevert(CrownRegistry.SelfChallenge.selector);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(challengerToken));
        // once dethroned, the former beneficiary may challenge back like anyone else
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.04 ether);
        finalizeAfterWindow(id);
        vm.prank(kingBeneficiary);
        registry.openChallenge{value: 0.01 ether}(TICKER, address(kingToken));
    }

    function test_stakerOnBothSides_isPaidForBoth() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.Challenger, 0.05 ether);
        stakeAs(alice, id, CrownRegistry.Side.King, 0.02 ether);
        finalizeAfterWindow(id);
        // losers 0.02 (all alice): slash 0.004, alice keeps 0.016 + wins 0.05 + 0.002*(5/6)
        assertEq(registry.claimable(id, alice), 0.016 ether + 0.05 ether + uint256(0.002 ether) * 5 / 6);
        claimAs(alice, id);
        claimAs(challenger, id);
        assertEq(address(registry).balance, 0);
    }

    // ------------------------------------------------------------------ claims

    function test_claim_failurePaths() public {
        uint256 id = open();
        stakeAs(alice, id, CrownRegistry.Side.King, 0.05 ether);
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.NotFinalized.selector);
        registry.claim(id);
        finalizeAfterWindow(id);
        claimAs(alice, id);
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.AlreadyClaimed.selector);
        registry.claim(id);
        vm.prank(bob);
        vm.expectRevert(CrownRegistry.NothingToClaim.selector);
        registry.claim(id);
    }

    function test_claim_reentrancyCannotDoublePay() public {
        uint256 id = open();
        ReentrantStaker evil = new ReentrantStaker(registry);
        evil.stakeOn{value: 0.05 ether}(id, CrownRegistry.Side.King);
        finalizeAfterWindow(id);
        uint256 owed = registry.claimable(id, address(evil));
        evil.claimIt();
        assertEq(address(evil).balance, owed);
        assertEq(evil.reentered(), 1, "the nested claim was refused");
        claimAs(challenger, id);
        assertEq(address(registry).balance, 0);
    }

    function test_treasuryThatRejectsEther_doesNotBlockFinalize() public {
        vm.etch(TREASURY, address(new RejectEther()).code);
        uint256 id = open();
        finalizeAfterWindow(id);
        assertEq(registry.treasuryOwed(), 0.002 ether);
        vm.etch(TREASURY, "");
        registry.payTreasury();
        assertEq(registry.treasuryOwed(), 0);
        assertEq(TREASURY.balance, 0.002 ether);
    }

    function test_treasuryIsolatedPayment_isSelfOnlyAndFailedRetriesPreserveCredit() public {
        vm.etch(TREASURY, address(new RejectEther()).code);
        uint256 id = open();
        finalizeAfterWindow(id);
        uint256 credit = registry.treasuryOwed();
        uint256 balance = address(registry).balance;
        vm.prank(TREASURY);
        vm.expectRevert(CrownRegistry.NotSelf.selector);
        registry.payTreasuryIsolated();
        registry.payTreasury();
        registry.payTreasury();
        assertEq(registry.treasuryOwed(), credit);
        assertEq(address(registry).balance, balance);
        vm.etch(TREASURY, "");
        registry.payTreasury();
        registry.payTreasury();
        assertEq(registry.treasuryOwed(), 0);
        assertEq(TREASURY.balance, credit);
        assertEq(address(registry).balance, balance - credit);
    }

    // ------------------------------------------------------------------ conservation

    function testFuzz_conservation(uint64[3] memory k, uint64[3] memory c) public {
        uint256 id = open();
        address[3] memory kingStakers = [makeAddr("k0"), makeAddr("k1"), makeAddr("k2")];
        address[3] memory chalStakers = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
        uint256 total = 0.01 ether;
        for (uint256 i; i < 3; ++i) {
            uint256 ka = bound(k[i], 1, 1 ether);
            uint256 ca = bound(c[i], 1, 1 ether);
            vm.deal(kingStakers[i], ka);
            vm.deal(chalStakers[i], ca);
            stakeAs(kingStakers[i], id, CrownRegistry.Side.King, ka);
            stakeAs(chalStakers[i], id, CrownRegistry.Side.Challenger, ca);
            total += ka + ca;
        }
        finalizeAfterWindow(id);
        (,,,,,,, bool won,,,,,,) = registry.challenges(id);

        uint256 paid = TREASURY.balance;
        paid += claimAs(challenger, id);
        for (uint256 i; i < 3; ++i) {
            uint256 kg = claimAs(kingStakers[i], id);
            uint256 cg = claimAs(chalStakers[i], id);
            uint256 ks = registry.stakeOf(id, kingStakers[i], CrownRegistry.Side.King);
            uint256 cs = registry.stakeOf(id, chalStakers[i], CrownRegistry.Side.Challenger);
            // winners get at least their stake back, losers 80% (within a few wei of rounding)
            if (won) {
                assertGe(cg, cs);
                assertLe(kg, ks * 8 / 10 + 5);
            } else {
                assertGe(kg, ks);
                assertLe(cg, cs * 8 / 10 + 5);
            }
            paid += kg + cg;
        }
        assertEq(paid, total, "every wei staked is paid out");
        assertEq(address(registry).balance, 0);
    }
}
