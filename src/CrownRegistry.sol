// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ticker} from "./libraries/Ticker.sol";

/// @title CrownRegistry
/// @notice One canonical token per ticker, the king. Maps ticker => {kingToken, beneficiary, reignStartedAt}.
/// Anyone may challenge a king with a bonded ETH stake-vote; resolution is purely rule-based and the registry has no
/// admin functions.
/// @dev Tickers are keccak256 of the uppercased symbol, and every token named here must report that symbol.
/// All payouts are pull-based except the treasury share, which is pushed at finalization and falls back to a
/// permissionless `payTreasury` if the push fails, so no recipient can block a resolution.
contract CrownRegistry {
    enum Side {
        King,
        Challenger
    }

    struct King {
        address token;
        address beneficiary;
        uint64 reignStartedAt;
        // When the crown may next be challenged. Registration and a defended flip set it MIN_REIGN ahead; a flip that
        // the king side did not defend with at least MIN_DEFENCE leaves it untouched.
        uint64 challengeableAt;
    }

    struct Challenge {
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
        // Set at finalization: what is left to pay each side, and the stake it is paid pro rata over.
        uint256 winnerPoolLeft;
        uint256 winnerStakeLeft;
        uint256 loserPoolLeft;
        uint256 loserStakeLeft;
    }

    struct TickerTotals {
        uint256 activeChallengeId;
        uint64 cooldownUntil;
        uint64 challenges;
        uint64 dethrones;
        uint256 totalStaked;
        uint256 totalSlashed;
    }

    uint256 public constant BOND = 0.01 ether;
    uint256 public constant QUORUM = 0.05 ether;
    uint256 public constant MIN_REIGN = 7 days;
    uint256 public constant STAKING_WINDOW = 72 hours;
    uint256 public constant TIMELOCK = 24 hours;
    uint256 public constant FAILED_COOLDOWN = 3 days;
    uint256 public constant SLASH_BPS = 2_000; // 20% of the losing side
    uint256 public constant BPS = 10_000;
    /// @notice The king-side stake a challenge needs before a flip grants the new king MIN_REIGN of protection: the
    /// king must have been defended with at least what the challenger bonded. Below it the slash rounds towards
    /// nothing, so an incumbent could re-crown itself through a second wallet for free; at it, every such cycle
    /// forfeits the treasury's half of the defence's 20% slash.
    uint256 public constant MIN_DEFENCE = BOND;
    address public constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    mapping(bytes32 ticker => King) internal _kings;
    mapping(bytes32 ticker => TickerTotals) public tickerTotals;
    mapping(uint256 challengeId => Challenge) public challenges;
    mapping(uint256 challengeId => mapping(address staker => uint256[2])) internal _stakes;
    mapping(uint256 challengeId => mapping(address staker => bool)) public claimed;

    uint256 public challengeCount;
    uint256 public treasuryOwed;
    bool private _locked;

    event Crowned(bytes32 indexed ticker, address indexed token, address indexed beneficiary, uint256 challengeId);
    event ChallengeOpened(
        bytes32 indexed ticker,
        uint256 indexed challengeId,
        address indexed challenger,
        address challengerToken,
        uint64 stakingEndsAt,
        uint64 finalizableAt
    );
    event Staked(
        uint256 indexed challengeId, bytes32 indexed ticker, address indexed staker, Side side, uint256 amount
    );
    event Dethroned(
        bytes32 indexed ticker,
        uint256 indexed challengeId,
        address oldToken,
        address newToken,
        address newBeneficiary,
        uint256 kingStake,
        uint256 challengerStake
    );
    event ChallengeFailed(
        bytes32 indexed ticker,
        uint256 indexed challengeId,
        uint256 kingStake,
        uint256 challengerStake,
        uint64 cooldownUntil
    );
    event Slashed(uint256 indexed challengeId, uint256 slashed, uint256 toWinners, uint256 toTreasury);
    event Claimed(uint256 indexed challengeId, address indexed staker, uint256 amount);
    event TreasuryPaid(uint256 amount);

    error AlreadyCrowned();
    error NoKing();
    error ZeroAddress();
    error TickerMismatch();
    error WrongBond();
    error ChallengeLive();
    error ReignTooShort();
    error CoolingDown();
    error SameToken();
    error SelfChallenge();
    error UnknownChallenge();
    error StakingClosed();
    error ZeroStake();
    error TimelockActive();
    error AlreadyFinalized();
    error NotFinalized();
    error AlreadyClaimed();
    error NothingToClaim();
    error TransferFailed();
    error Reentrancy();
    error NotSelf();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ------------------------------------------------------------------ views

    /// @notice The current king of `ticker`; all zero when the ticker has never been registered.
    function king(bytes32 ticker)
        external
        view
        returns (address kingToken, address beneficiary, uint64 reignStartedAt)
    {
        King storage k = _kings[ticker];
        return (k.token, k.beneficiary, k.reignStartedAt);
    }

    /// @notice The wallet the hook pays for `ticker`, or zero when it has no king.
    function beneficiaryOf(bytes32 ticker) external view returns (address) {
        return _kings[ticker].beneficiary;
    }

    /// @notice The earliest time a challenge may be opened against the king of `ticker` (the cooldown after a failed
    /// challenge is separate, in `tickerTotals`). Zero when the ticker has never been registered.
    function challengeableAt(bytes32 ticker) external view returns (uint64) {
        return _kings[ticker].challengeableAt;
    }

    function stakeOf(uint256 challengeId, address staker, Side side) external view returns (uint256) {
        return _stakes[challengeId][staker][uint256(side)];
    }

    /// @notice What `staker` would receive from `claim(challengeId)` right now.
    function claimable(uint256 challengeId, address staker) external view returns (uint256 amount) {
        Challenge storage c = challenges[challengeId];
        if (!c.finalized || claimed[challengeId][staker]) return 0;
        (amount,,,,) = _payout(c, _stakes[challengeId][staker]);
    }

    function tickerOf(string calldata symbol) external pure returns (bytes32) {
        return Ticker.fromSymbol(symbol);
    }

    // ------------------------------------------------------------------ actions

    /// @notice Crowns `token` for `ticker` if the ticker has no king yet. First registration wins.
    function registerKing(bytes32 ticker, address token, address beneficiary) external {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (_kings[ticker].token != address(0)) revert AlreadyCrowned();
        if (ticker == bytes32(0) || Ticker.ofToken(token) != ticker) revert TickerMismatch();
        _kings[ticker] = King(token, beneficiary, uint64(block.timestamp), uint64(block.timestamp + MIN_REIGN));
        emit Crowned(ticker, token, beneficiary, 0);
    }

    /// @notice Challenges the king of `ticker` with `challengerToken`, bonding exactly `BOND`. The bond is the
    /// challenger's opening stake on the challenger side, and `msg.sender` becomes the beneficiary if it wins.
    /// The sitting beneficiary cannot challenge its own crown: it would only hold the ticker's single challenge
    /// slot against everyone else.
    function openChallenge(bytes32 ticker, address challengerToken) external payable returns (uint256 challengeId) {
        if (msg.value != BOND) revert WrongBond();
        King storage k = _kings[ticker];
        if (k.token == address(0)) revert NoKing();
        if (msg.sender == k.beneficiary) revert SelfChallenge();
        TickerTotals storage t = tickerTotals[ticker];
        if (t.activeChallengeId != 0) revert ChallengeLive();
        if (block.timestamp < k.challengeableAt) revert ReignTooShort();
        if (block.timestamp < t.cooldownUntil) revert CoolingDown();
        if (challengerToken == k.token) revert SameToken();
        if (challengerToken == address(0)) revert ZeroAddress();
        if (Ticker.ofToken(challengerToken) != ticker) revert TickerMismatch();

        challengeId = ++challengeCount;
        uint64 stakingEndsAt = uint64(block.timestamp + STAKING_WINDOW);
        uint64 finalizableAt = uint64(block.timestamp + STAKING_WINDOW + TIMELOCK);
        Challenge storage c = challenges[challengeId];
        c.ticker = ticker;
        c.challengerToken = challengerToken;
        c.challengerBeneficiary = msg.sender;
        c.openedAt = uint64(block.timestamp);
        c.stakingEndsAt = stakingEndsAt;
        c.finalizableAt = finalizableAt;
        t.activeChallengeId = challengeId;
        t.challenges += 1;

        emit ChallengeOpened(ticker, challengeId, msg.sender, challengerToken, stakingEndsAt, finalizableAt);
        _stake(c, challengeId, Side.Challenger);
    }

    /// @notice Stakes `msg.value` on `side` of a live challenge, during its staking window.
    function stake(uint256 challengeId, Side side) external payable {
        Challenge storage c = challenges[challengeId];
        if (c.openedAt == 0) revert UnknownChallenge();
        if (block.timestamp >= c.stakingEndsAt) revert StakingClosed();
        _stake(c, challengeId, side);
    }

    /// @notice Resolves a challenge after its window and timelock. Anyone may call.
    /// @dev The challenger wins iff its stake exceeds the king's and the total meets QUORUM. The losing side keeps
    /// 80%; of the 20% slash, half goes pro rata to the winning side and half to TREASURY (all of it to TREASURY when
    /// the winning side has no stake). A flip always restarts `reignStartedAt`, but it pushes `challengeableAt`
    /// (which gates the next challenge) MIN_REIGN ahead only when the king side was defended with at least
    /// MIN_DEFENCE: a crown nobody defended, or one defended with dust whose slash rounds to zero, passes with its
    /// protection untouched, so a throwaway challenge (from the incumbent's own second wallet or anyone else's)
    /// cannot buy a fresh seven days of immunity without forfeiting a slash.
    function finalize(uint256 challengeId) external nonReentrant {
        Challenge storage c = challenges[challengeId];
        if (c.openedAt == 0) revert UnknownChallenge();
        if (c.finalized) revert AlreadyFinalized();
        if (block.timestamp < c.finalizableAt) revert TimelockActive();

        bytes32 ticker = c.ticker;
        TickerTotals storage t = tickerTotals[ticker];
        uint256 kingStake = c.kingStake;
        uint256 challengerStake = c.challengerStake;
        bool won = challengerStake > kingStake && kingStake + challengerStake >= QUORUM;

        (uint256 winners, uint256 losers) = won ? (challengerStake, kingStake) : (kingStake, challengerStake);
        uint256 slash = losers * SLASH_BPS / BPS;
        uint256 toWinners = winners == 0 ? 0 : slash / 2;
        uint256 toTreasury = slash - toWinners;

        c.finalized = true;
        c.challengerWon = won;
        c.winnerPoolLeft = winners + toWinners;
        c.winnerStakeLeft = winners;
        c.loserPoolLeft = losers - slash;
        c.loserStakeLeft = losers;
        t.activeChallengeId = 0;
        t.totalSlashed += slash;

        if (won) {
            King storage k = _kings[ticker];
            address oldToken = k.token;
            k.token = c.challengerToken;
            k.beneficiary = c.challengerBeneficiary;
            k.reignStartedAt = uint64(block.timestamp);
            if (kingStake >= MIN_DEFENCE) k.challengeableAt = uint64(block.timestamp + MIN_REIGN);
            t.dethrones += 1;
            emit Dethroned(
                ticker, challengeId, oldToken, c.challengerToken, c.challengerBeneficiary, kingStake, challengerStake
            );
            emit Crowned(ticker, c.challengerToken, c.challengerBeneficiary, challengeId);
        } else {
            uint64 cooldownUntil = uint64(block.timestamp + FAILED_COOLDOWN);
            t.cooldownUntil = cooldownUntil;
            emit ChallengeFailed(ticker, challengeId, kingStake, challengerStake, cooldownUntil);
        }
        emit Slashed(challengeId, slash, toWinners, toTreasury);

        if (toTreasury != 0) {
            treasuryOwed += toTreasury;
            _payTreasury();
        }
    }

    /// @notice Pays out everything `msg.sender` is owed from a finalized challenge, on both sides.
    function claim(uint256 challengeId) external nonReentrant returns (uint256 amount) {
        Challenge storage c = challenges[challengeId];
        if (!c.finalized) revert NotFinalized();
        if (claimed[challengeId][msg.sender]) revert AlreadyClaimed();
        uint256 winnerPaid;
        uint256 winnerStake;
        uint256 loserPaid;
        uint256 loserStake;
        (amount, winnerPaid, winnerStake, loserPaid, loserStake) = _payout(c, _stakes[challengeId][msg.sender]);
        if (winnerStake == 0 && loserStake == 0) revert NothingToClaim();

        claimed[challengeId][msg.sender] = true;
        c.winnerPoolLeft -= winnerPaid;
        c.winnerStakeLeft -= winnerStake;
        c.loserPoolLeft -= loserPaid;
        c.loserStakeLeft -= loserStake;
        emit Claimed(challengeId, msg.sender, amount);

        // A dust stake can round to zero; it is still recorded so the last claimer takes the exact remainder.
        if (amount != 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Pushes the treasury's accrued slash share to TREASURY. Anyone may call.
    function payTreasury() external nonReentrant {
        _payTreasury();
    }

    /// @dev Self-call boundary: a failed transfer rolls back the credit update atomically.
    /// Only the guarded finalize/payTreasury paths can enter it through _payTreasury.
    function payTreasuryIsolated() external {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 amount = treasuryOwed;
        treasuryOwed = 0;
        (bool ok,) = TREASURY.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit TreasuryPaid(amount);
    }

    // ------------------------------------------------------------------ internals

    function _stake(Challenge storage c, uint256 challengeId, Side side) private {
        if (msg.value == 0) revert ZeroStake();
        if (side == Side.King) c.kingStake += msg.value;
        else c.challengerStake += msg.value;
        _stakes[challengeId][msg.sender][uint256(side)] += msg.value;
        tickerTotals[c.ticker].totalStaked += msg.value;
        emit Staked(challengeId, c.ticker, msg.sender, side, msg.value);
    }

    /// @dev Each side's pool is paid pro rata over the stake not yet claimed, so the last claimer takes the exact
    /// remainder: the sum paid equals the pool to the wei, and a winner never receives less than its stake.
    function _payout(Challenge storage c, uint256[2] storage s)
        private
        view
        returns (uint256 amount, uint256 winnerPaid, uint256 winnerStake, uint256 loserPaid, uint256 loserStake)
    {
        (winnerStake, loserStake) = c.challengerWon
            ? (s[uint256(Side.Challenger)], s[uint256(Side.King)])
            : (s[uint256(Side.King)], s[uint256(Side.Challenger)]);
        if (winnerStake != 0) winnerPaid = c.winnerPoolLeft * winnerStake / c.winnerStakeLeft;
        if (loserStake != 0) loserPaid = c.loserPoolLeft * loserStake / c.loserStakeLeft;
        amount = winnerPaid + loserPaid;
    }

    function _payTreasury() private {
        if (treasuryOwed == 0) return;
        try this.payTreasuryIsolated() {} catch {}
    }
}
