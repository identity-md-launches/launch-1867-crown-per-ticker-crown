// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {CrownToken} from "../src/CrownToken.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {CrownFixture} from "./utils/CrownFixture.sol";

/// @notice A wallet that can open challenges and stake, and that can be switched to refuse ETH so that a king paid
/// at the source is paid as a claim instead.
contract ChallengerWallet {
    CrownRegistry internal immutable registry;
    IPoolManager internal immutable manager;
    CrownHook internal immutable hook;
    bool public rejects;

    constructor(CrownRegistry r, IPoolManager m, CrownHook h) {
        registry = r;
        manager = m;
        hook = h;
    }

    function setRejects(bool v) external {
        rejects = v;
    }

    function open(bytes32 ticker, address token) external payable returns (uint256) {
        return registry.openChallenge{value: msg.value}(ticker, token);
    }

    function stake(uint256 id, CrownRegistry.Side side) external payable {
        registry.stake{value: msg.value}(id, side);
    }

    function redeem(uint256 amount) external {
        manager.setOperator(address(hook), true);
        hook.redeemClaim(Currency.wrap(address(0)), amount);
    }

    receive() external payable {
        if (rejects) revert("closed");
    }
}

/// @notice Random swaps of every shape on the launch pool, interleaved with challenges, stakes, time, finalizations
/// and claim redemptions. Records what the king's beneficiary actually received, by transfer and by claim.
contract HookHandler is Test {
    bytes32 internal constant CRWN = keccak256("CRWN");
    Currency internal constant ETH = Currency.wrap(address(0));

    PoolManager internal immutable manager;
    CrownHook internal immutable hook;
    CrownRegistry internal immutable registry;
    CrownToken internal immutable token;
    Swapper internal immutable trader;
    PoolKey internal key;
    address internal immutable payer;

    ChallengerWallet[3] public wallets;
    address[3] public rivals;

    uint256 public ghostTransferred;
    uint256 public ghostMinted;
    uint256 public ghostRedeemed;
    uint256 public ghostSwaps;
    uint256 public ghostFlips;
    bool public cutMismatch;
    bool public traderShortchanged;
    bool public swapWithoutKing;

    constructor(
        PoolManager m,
        CrownHook h,
        CrownToken t,
        PoolKey memory k,
        Swapper trader_,
        address payer_,
        address[3] memory rivals_
    ) {
        manager = m;
        hook = h;
        registry = h.registry();
        token = t;
        key = k;
        trader = trader_;
        payer = payer_;
        rivals = rivals_;
        for (uint256 i; i < 3; ++i) {
            wallets[i] = new ChallengerWallet(registry, m, h);
        }
    }

    // ------------------------------------------------------------------ swaps

    function _before() internal view returns (address b, uint256 eth, uint256 claims) {
        b = registry.beneficiaryOf(CRWN);
        eth = b.balance;
        claims = manager.balanceOf(b, 0);
    }

    function _after(address b, uint256 eth, uint256 claims, uint256 expectedCut) internal {
        uint256 gotEth = b.balance - eth;
        uint256 gotClaims = manager.balanceOf(b, 0) - claims;
        ghostTransferred += gotEth;
        ghostMinted += gotClaims;
        ghostSwaps += 1;
        if (b == address(0)) swapWithoutKing = true;
        if (gotEth + gotClaims != expectedCut) cutMismatch = true;
    }

    function buyExactIn(uint256 amount) external {
        amount = bound(amount, 1, 20 ether);
        (address b, uint256 eth, uint256 claims) = _before();
        try trader.swap(key, true, amount) returns (BalanceDelta d) {
            if (uint256(-int256(d.amount0())) != amount) traderShortchanged = true;
            _after(b, eth, claims, amount / 100);
        } catch {}
    }

    function buyExactOut(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        (address b, uint256 eth, uint256 claims) = _before();
        try trader.swapExact(key, true, int256(amount)) returns (BalanceDelta d) {
            if (uint256(int256(d.amount1())) != amount) traderShortchanged = true;
            uint256 paid = uint256(-int256(d.amount0()));
            uint256 cut = b.balance - eth + manager.balanceOf(b, 0) - claims;
            // the cut is 1% of what the pool took, which is the trader's payment less the cut
            _after(b, eth, claims, (paid - cut) / 100);
        } catch {}
    }

    function sellExactIn(uint256 amount) external {
        amount = bound(amount, 1, 20 ether);
        (address b, uint256 eth, uint256 claims) = _before();
        try trader.swap(key, false, amount) returns (BalanceDelta d) {
            if (uint256(-int256(d.amount1())) != amount) traderShortchanged = true;
            uint256 received = uint256(int256(d.amount0()));
            uint256 cut = b.balance - eth + manager.balanceOf(b, 0) - claims;
            // the cut is 1% of what the pool paid out, which is what the trader got plus the cut
            _after(b, eth, claims, (received + cut) / 100);
        } catch {}
    }

    function sellExactOut(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        (address b, uint256 eth, uint256 claims) = _before();
        try trader.swapExact(key, false, int256(amount)) returns (BalanceDelta d) {
            if (uint256(int256(d.amount0())) != amount) traderShortchanged = true;
            _after(b, eth, claims, amount / 100);
        } catch {}
    }

    // ------------------------------------------------------------------ the crown

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 4 days);
        vm.warp(block.timestamp + secs);
    }

    function challenge(uint256 walletSeed, uint256 rivalSeed) external {
        ChallengerWallet w = wallets[walletSeed % 3];
        vm.deal(address(this), 0.01 ether);
        try w.open{value: 0.01 ether}(CRWN, rivals[rivalSeed % 3]) {} catch {}
    }

    function stake(uint256 walletSeed, bool challengerSide, uint256 amount) external {
        (uint256 id,,,,,) = registry.tickerTotals(CRWN);
        if (id == 0) return;
        amount = bound(amount, 1, 0.2 ether);
        vm.deal(address(this), amount);
        try wallets[walletSeed % 3].stake{value: amount}(
            id, challengerSide ? CrownRegistry.Side.Challenger : CrownRegistry.Side.King
        ) {}
            catch {}
    }

    function finalize() external {
        (uint256 id,,,,,) = registry.tickerTotals(CRWN);
        if (id == 0) return;
        address before = registry.beneficiaryOf(CRWN);
        try registry.finalize(id) {
            if (registry.beneficiaryOf(CRWN) != before) ghostFlips += 1;
        } catch {}
    }

    function toggleRejects(uint256 walletSeed) external {
        ChallengerWallet w = wallets[walletSeed % 3];
        w.setRejects(!w.rejects());
    }

    function redeem(uint256 walletSeed) external {
        ChallengerWallet w = wallets[walletSeed % 3];
        uint256 amount = manager.balanceOf(address(w), 0);
        if (amount == 0) return;
        uint256 before = address(w).balance;
        try w.redeem(amount) {
            ghostRedeemed += amount;
            if (address(w).balance - before != amount) cutMismatch = true;
        } catch {}
    }

    function outstandingClaims() external view returns (uint256 total) {
        total = manager.balanceOf(payer, 0);
        for (uint256 i; i < 3; ++i) {
            total += manager.balanceOf(address(wallets[i]), 0);
        }
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract CrownHookInvariantTest is CrownFixture {
    Currency internal constant ETH = Currency.wrap(address(0));
    HookHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        setUpPool();
        address[3] memory rivals;
        for (uint256 i; i < 3; ++i) {
            rivals[i] = address(new CrownChallengerToken(makeAddr(string.concat("holder", vm.toString(i)))));
        }
        handler = new HookHandler(manager, hook, token, key, trader, payer, rivals);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = HookHandler.buyExactIn.selector;
        selectors[1] = HookHandler.buyExactOut.selector;
        selectors[2] = HookHandler.sellExactIn.selector;
        selectors[3] = HookHandler.sellExactOut.selector;
        selectors[4] = HookHandler.warp.selector;
        selectors[5] = HookHandler.challenge.selector;
        selectors[6] = HookHandler.stake.selector;
        selectors[7] = HookHandler.finalize.selector;
        selectors[8] = HookHandler.toggleRejects.selector;
        selectors[9] = HookHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Pay-at-source: the hook never holds ETH, tokens or claims.
    function invariant_hookHoldsNothing() public view {
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds tokens");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook holds ETH claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "hook holds token claims");
    }

    /// @notice crownPaid is exactly what the kings' beneficiaries received, by transfer plus by claim.
    function invariant_crownPaidMatchesReceipts() public view {
        assertEq(
            hook.crownPaid(CRWN, ETH),
            handler.ghostTransferred() + handler.ghostMinted(),
            "crownPaid != transfers + claims"
        );
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(token))), 0, "the cut is never taken in the token");
    }

    /// @notice Every swap paid exactly the pool's bps of its ETH leg to whoever was king at that moment, and the
    /// trader always got or paid exactly the amount specified.
    function invariant_everyCutExact() public view {
        assertFalse(handler.cutMismatch(), "a swap paid a different cut than 1% of its ETH leg");
        assertFalse(handler.traderShortchanged(), "the trader's specified amount was changed");
        assertFalse(handler.swapWithoutKing(), "a swap ran while the ticker had no king");
    }

    /// @notice Claims minted to beneficiaries are always backed by ETH in the manager, and redeeming them never
    /// touches the hook.
    function invariant_claimsAreBacked() public view {
        assertGe(address(manager).balance, handler.outstandingClaims(), "ETH claims exceed the manager's ETH");
        assertEq(handler.ghostMinted() - handler.ghostRedeemed(), handler.outstandingClaims(), "claim bookkeeping");
    }

    /// @notice The ticker's king is always a token that reports CRWN with a live beneficiary.
    function invariant_kingAlwaysSet() public view {
        (address kingToken, address beneficiary,) = registry.king(CRWN);
        assertTrue(beneficiary != address(0), "no beneficiary");
        assertEq(registry.tickerOf(CrownToken(kingToken).symbol()), CRWN, "king does not report CRWN");
    }
}
