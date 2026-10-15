// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {Ticker} from "../src/libraries/Ticker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RejectingTreasury {
    receive() external payable {
        revert("treasury closed");
    }
}

/// @notice Drives CrownRegistry with random, bounded calls from a fixed cast of actors over two tickers. Every
/// action is wrapped in try/catch so refused calls are part of the sequence; ghost totals record what actually went
/// in and out.
contract RegistryHandler is Test {
    uint256 internal constant BOND = 0.01 ether;
    address internal constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    CrownRegistry public immutable registry;
    bytes32[2] internal tickers;
    address[3][2] internal tokens;
    address[6] internal actors;
    bytes internal rejectingCode;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostFinalizations;
    uint256 public ghostClaims;
    uint256 public ghostTreasuryRetries;
    bool public treasuryRejects;

    bool public winnerUnderpaid;
    bool public loserOverpaid;
    bool public claimableMismatch;
    bool public claimReceiptMismatch;
    bool public doubleClaim;
    mapping(uint256 challengeId => bool) public sawFinalized;
    mapping(uint256 challengeId => mapping(address => bool)) public ghostClaimed;

    constructor(CrownRegistry r, bytes32[2] memory t, address[3][2] memory toks) {
        registry = r;
        tickers = t;
        tokens = toks;
        for (uint256 i; i < 6; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        rejectingCode = address(new RejectingTreasury()).code;
    }

    function actorList() external view returns (address[6] memory) {
        return actors;
    }

    function tickerList() external view returns (bytes32[2] memory) {
        return tickers;
    }

    // ------------------------------------------------------------------ actions

    function openChallenge(uint256 tickerSeed, uint256 tokenSeed, uint256 actorSeed) external {
        uint256 ti = tickerSeed % 2;
        address token = tokens[ti][tokenSeed % 3];
        address actor = actors[actorSeed % 6];
        vm.deal(actor, BOND);
        vm.prank(actor);
        try registry.openChallenge{value: BOND}(tickers[ti], token) {
            ghostDeposited += BOND;
        } catch {}
    }

    function stake(uint256 idSeed, bool challengerSide, uint256 amount, uint256 actorSeed) external {
        // ids 1..count exist; 0 and count + 1 are unknown and must be refused
        uint256 id = idSeed % (registry.challengeCount() + 2);
        amount = bound(amount, 0, 2 ether);
        address actor = actors[actorSeed % 6];
        vm.deal(actor, amount);
        vm.prank(actor);
        try registry.stake{value: amount}(
            id, challengerSide ? CrownRegistry.Side.Challenger : CrownRegistry.Side.King
        ) {
            ghostDeposited += amount;
        } catch {}
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 4 days);
        vm.warp(block.timestamp + secs);
    }

    function finalize(uint256 idSeed) external {
        uint256 count = registry.challengeCount();
        uint256 id = count == 0 ? 1 : (idSeed % count) + 1;
        try registry.finalize(id) {
            ghostFinalizations += 1;
            sawFinalized[id] = true;
        } catch {}
    }

    function claim(uint256 idSeed, uint256 actorSeed) external {
        uint256 count = registry.challengeCount();
        uint256 id = count == 0 ? 1 : (idSeed % count) + 1;
        address actor = actors[actorSeed % 6];
        uint256 expected = registry.claimable(id, actor);
        uint256 before = actor.balance;
        vm.prank(actor);
        try registry.claim(id) returns (uint256 amount) {
            if (ghostClaimed[id][actor]) doubleClaim = true;
            ghostClaimed[id][actor] = true;
            ghostClaims += 1;
            ghostWithdrawn += amount;
            if (amount != expected) claimableMismatch = true;
            if (actor.balance - before != amount) claimReceiptMismatch = true;
            _checkPayout(id, actor, amount);
        } catch {}
    }

    function payTreasury() external {
        try registry.payTreasury() {
            ghostTreasuryRetries += 1;
        } catch {}
    }

    /// @dev Flips the treasury between a plain account and one that refuses ETH, so both the push and the
    /// `treasuryOwed` fallback are exercised.
    function toggleTreasury() external {
        treasuryRejects = !treasuryRejects;
        if (treasuryRejects) {
            vm.etch(TREASURY, rejectingCode);
        } else {
            vm.etch(TREASURY, "");
            // once the treasury accepts again, anyone can clear the arrears
            registry.payTreasury();
        }
    }

    // ------------------------------------------------------------------ checks

    function _checkPayout(uint256 id, address actor, uint256 amount) internal {
        (,,,,,,, bool won,,,,,,) = registry.challenges(id);
        uint256 kingStake = registry.stakeOf(id, actor, CrownRegistry.Side.King);
        uint256 chalStake = registry.stakeOf(id, actor, CrownRegistry.Side.Challenger);
        (uint256 winnerStake, uint256 loserStake) = won ? (chalStake, kingStake) : (kingStake, chalStake);
        // a winner is always made whole; a pure loser never gets more than 80% plus rounding dust
        if (amount < winnerStake) winnerUnderpaid = true;
        if (winnerStake == 0 && amount > loserStake * 8 / 10 + 8) loserOverpaid = true;
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract CrownRegistryInvariantTest is Test {
    uint256 internal constant QUORUM = 0.05 ether;
    address internal constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    CrownRegistry internal registry;
    RegistryHandler internal handler;
    bytes32[2] internal tickers;
    address[3][2] internal tokens;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new CrownRegistry();
        tickers = [keccak256("AAA"), keccak256("BBB")];
        string[2] memory symbols = ["AAA", "bbb"];
        for (uint256 t; t < 2; ++t) {
            for (uint256 i; i < 3; ++i) {
                tokens[t][i] = address(new MockERC20("Token", symbols[t], 1));
            }
        }
        // AAA has a king from the start; BBB is crowned by the handler's first successful registration below.
        registry.registerKing(tickers[0], tokens[0][0], makeAddr("genesis"));
        registry.registerKing(tickers[1], tokens[1][1], makeAddr("genesisB"));

        handler = new RegistryHandler(registry, tickers, tokens);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RegistryHandler.openChallenge.selector;
        selectors[1] = RegistryHandler.stake.selector;
        selectors[2] = RegistryHandler.warp.selector;
        selectors[3] = RegistryHandler.finalize.selector;
        selectors[4] = RegistryHandler.claim.selector;
        selectors[5] = RegistryHandler.payTreasury.selector;
        selectors[6] = RegistryHandler.toggleTreasury.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    struct C {
        bytes32 ticker;
        address challengerToken;
        address challengerBeneficiary;
        uint64 openedAt;
        uint64 stakingEndsAt;
        uint64 finalizableAt;
        bool finalized;
        bool challengerWon;
        uint256 kingStake;
        uint256 challengerStake;
        uint256 winnerPoolLeft;
        uint256 winnerStakeLeft;
        uint256 loserPoolLeft;
        uint256 loserStakeLeft;
    }

    function read(uint256 id) internal view returns (C memory c) {
        (
            c.ticker,
            c.challengerToken,
            c.challengerBeneficiary,
            c.openedAt,
            c.stakingEndsAt,
            c.finalizableAt,
            c.finalized,
            c.challengerWon,
            c.kingStake,
            c.challengerStake,
            c.winnerPoolLeft,
            c.winnerStakeLeft,
            c.loserPoolLeft,
            c.loserStakeLeft
        ) = registry.challenges(id);
    }

    /// @notice The registry holds exactly what it still owes: live stakes, unclaimed pools and the treasury arrears.
    function invariant_balanceEqualsObligations() public view {
        uint256 owed = registry.treasuryOwed();
        uint256 n = registry.challengeCount();
        for (uint256 id = 1; id <= n; ++id) {
            C memory c = read(id);
            owed += c.finalized ? c.winnerPoolLeft + c.loserPoolLeft : c.kingStake + c.challengerStake;
        }
        assertEq(address(registry).balance, owed, "registry balance != obligations");
    }

    /// @notice Every wei that went in is still in the registry, at the treasury, or was claimed. Nothing is lost
    /// or created.
    function invariant_ethIsConserved() public view {
        assertEq(
            handler.ghostDeposited(),
            address(registry).balance + TREASURY.balance + handler.ghostWithdrawn(),
            "deposits != registry + treasury + claims"
        );
    }

    /// @notice Payout rules observed by the handler on every claim: winners whole, losers capped, claimable exact,
    /// no double claims.
    function invariant_claimRulesHold() public view {
        assertFalse(handler.winnerUnderpaid(), "a winner got less than its stake");
        assertFalse(handler.loserOverpaid(), "a loser got more than 80% plus dust");
        assertFalse(handler.claimableMismatch(), "claimable() disagreed with claim()");
        assertFalse(handler.claimReceiptMismatch(), "claim() paid a different amount than it returned");
        assertFalse(handler.doubleClaim(), "a staker claimed twice");
    }

    /// @notice Resolution is rule-based: the recorded outcome of every finalized challenge matches the rule, the
    /// winning pool always covers the winning stake, and a finished challenge never reopens.
    function invariant_resolutionMatchesRule() public view {
        uint256 n = registry.challengeCount();
        for (uint256 id = 1; id <= n; ++id) {
            C memory c = read(id);
            (uint256 active,,,,,) = registry.tickerTotals(c.ticker);
            if (!c.finalized) {
                assertEq(active, id, "a live challenge is not the ticker's active one");
                assertFalse(handler.sawFinalized(id), "a finalized challenge reopened");
                continue;
            }
            assertTrue(active != id, "a finalized challenge is still active");
            bool shouldWin = c.challengerStake > c.kingStake && c.kingStake + c.challengerStake >= QUORUM;
            assertEq(c.challengerWon, shouldWin, "outcome disagrees with the rule");
            assertGe(c.winnerPoolLeft, c.winnerStakeLeft, "winning pool cannot refund the winners");
            assertLe(c.loserPoolLeft, c.loserStakeLeft, "losing pool exceeds the losing stake");
        }
    }

    /// @notice Per-ticker totals are the sums over that ticker's challenges, and the king always reports the ticker.
    function invariant_tickerTotalsAndKings() public view {
        uint256 n = registry.challengeCount();
        for (uint256 t; t < 2; ++t) {
            bytes32 ticker = tickers[t];
            uint256 staked;
            uint256 slashed;
            uint256 opened;
            uint256 liveCount;
            for (uint256 id = 1; id <= n; ++id) {
                C memory c = read(id);
                if (c.ticker != ticker) continue;
                opened += 1;
                staked += c.kingStake + c.challengerStake;
                if (c.finalized) {
                    uint256 losers = c.challengerWon ? c.kingStake : c.challengerStake;
                    slashed += losers * 2_000 / 10_000;
                } else {
                    liveCount += 1;
                }
            }
            (uint256 active,, uint64 challenges,, uint256 totalStaked, uint256 totalSlashed) =
                registry.tickerTotals(ticker);
            assertEq(totalStaked, staked, "totalStaked");
            assertEq(totalSlashed, slashed, "totalSlashed");
            assertEq(challenges, opened, "challenges");
            assertLe(liveCount, 1, "more than one live challenge per ticker");
            assertEq(active == 0 ? 0 : 1, liveCount, "activeChallengeId vs live count");

            (address kingToken, address beneficiary,) = registry.king(ticker);
            assertTrue(kingToken != address(0) && beneficiary != address(0), "ticker lost its king");
            assertEq(Ticker.ofToken(kingToken), ticker, "king token does not report the ticker");
        }
    }

    /// @notice Treasury arrears only exist while the treasury refuses ETH: a finalize against an accepting treasury
    /// pushes at once, and the retry the handler makes when the treasury reopens clears what accrued meanwhile.
    function invariant_treasuryArrearsOnlyWhileRejecting() public view {
        if (handler.treasuryRejects()) return;
        assertEq(registry.treasuryOwed(), 0, "treasury arrears while the treasury accepts ETH");
    }
}
