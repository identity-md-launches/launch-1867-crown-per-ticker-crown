// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {CrownFixture} from "./utils/CrownFixture.sol";

/// @dev A beneficiary that re-syncs the manager while being paid: `sync` is open to anyone and moves no delta.
contract SyncingBeneficiary {
    IPoolManager internal immutable manager;
    Currency internal immutable target;

    constructor(IPoolManager m, Currency c) {
        manager = m;
        target = c;
    }

    receive() external payable {
        manager.sync(target);
    }
}

/// @dev A router that pays its ERC-20 input up front: sync, transfer, swap, settle, inside one unlock.
contract PrepayRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function sell(PoolKey memory key, uint256 amountIn) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, amountIn)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, uint256 amountIn) = abi.decode(raw, (PoolKey, uint256));
        manager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(manager), amountIn);
        BalanceDelta d = manager.swap(key, SwapParams(false, -int256(amountIn), TickMath.MAX_SQRT_PRICE - 1), "");
        manager.settle();
        if (d.amount0() > 0) manager.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        return abi.encode(d);
    }

    receive() external payable {}
}

/// @dev An ERC-20 whose balanceOf can be made to revert, as a paused or upgraded token might.
contract PausableBalanceToken is MockERC20 {
    bool public paused;

    constructor(string memory n, string memory s) MockERC20(n, s, 0) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function balanceOf(address who) public view override returns (uint256) {
        require(!paused, "paused");
        return super.balanceOf(who);
    }
}

contract Bytes32SymbolToken {
    function symbol() external pure returns (bytes32) {
        return "MKR";
    }
}

/// @notice Regression tests for the revision findings: the cut on partially filled and oversized requests, a
/// beneficiary that re-syncs the manager, a token whose balanceOf reverts, pools opened on a squatted or unreadable
/// ticker, and the registry's self-challenge rules.
contract CrownRevisionTest is CrownFixture {
    Currency internal constant ETH = Currency.wrap(address(0));

    function setUp() public {
        setUpPool();
    }

    function ethPaid(BalanceDelta d) internal pure returns (uint256) {
        return uint256(-int256(d.amount0()));
    }

    // ------------------------------------------------------------------ partial fills and oversized requests

    function test_exactInputBuy_partialFill_isRefused() public {
        uint256 before = payer.balance;
        vm.expectRevert(); // CrownHook.PartialFill, wrapped by the manager's hook-call revert
        trader.swapWith(key, SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)));
        assertEq(payer.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        // the same request without a binding limit fills in full and pays exactly 1% of it
        BalanceDelta d = trader.swap(key, true, 100 ether);
        assertEq(ethPaid(d), 100 ether);
        assertEq(payer.balance - before, 1 ether);
    }

    function test_exactOutputSell_partialFill_isRefused() public {
        uint256 ethBefore = address(trader).balance;
        vm.expectRevert();
        trader.swapWith(key, SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(10)));
        assertEq(address(trader).balance, ethBefore, "the seller paid no ETH");
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        // a limit that still lets the request fill in full is fine
        BalanceDelta d = trader.swapWith(key, SwapParams(false, 1 ether, TickMath.getSqrtPriceAtTick(600)));
        assertEq(uint256(int256(d.amount0())), 1 ether);
        assertEq(hook.crownPaid(CRWN, ETH), 0.01 ether);
    }

    function test_exactInputBuy_limitReachedExactlyAtTheRequest_isNotAPartialFill() public {
        // find what a buy limited to one tick consumes, then request exactly that: the fill is complete
        uint256 snap = vm.snapshotState();
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("NOKING"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000 ether);
        BalanceDelta probe = trader.swapWith(k, SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)));
        uint256 consumed = ethPaid(probe);
        vm.revertToState(snap);

        // on the crowned pool, ask for consumed / 0.99 so the pool's net request is exactly `consumed`
        uint256 request = consumed * 100 / 99;
        while (request - request / 100 < consumed) request++;
        BalanceDelta d = trader.swapWith(key, SwapParams(true, -int256(request), TickMath.getSqrtPriceAtTick(-1)));
        assertEq(ethPaid(d), request);
        assertEq(hook.crownPaid(CRWN, ETH), request / 100);
    }

    function test_oversizedExactInput_isRefusedOnACrownedPool() public {
        uint256 before = address(trader).balance;
        vm.expectRevert();
        trader.swapWith(
            key, SwapParams(true, -int256(uint256(type(uint128).max) + 1), TickMath.getSqrtPriceAtTick(-60))
        );
        assertEq(address(trader).balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        vm.expectRevert();
        trader.swapWith(key, SwapParams(false, int256(uint256(type(uint128).max) + 1), TickMath.getSqrtPriceAtTick(60)));
    }

    function test_partialFillsAndOversizedRequests_proceedWhenNothingIsCharged() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("NOKING"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000 ether);

        // no king for the ticker: nothing is reserved, so a price-limited partial fill goes through untouched
        BalanceDelta d = trader.swapWith(k, SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)));
        assertGt(ethPaid(d), 0);
        assertLt(ethPaid(d), 1 ether);
        assertEq(hook.crownPaid(keccak256("NOKING"), ETH), 0);

        // a zero-bps pool lets even an oversized request through, bounded by its limit, as plain v4 would
        MockERC20 free = new MockERC20("Free", "FREE", 0);
        PoolKey memory kf = keyFor(address(free), hook);
        vm.startPrank(payer);
        hook.configurePool(kf, CRWN, 0);
        manager.initialize(kf, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(free), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(kf, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000 ether);
        d = trader.swapWith(
            kf, SwapParams(true, -int256(uint256(type(uint128).max) + 1), TickMath.getSqrtPriceAtTick(-60))
        );
        assertGt(ethPaid(d), 1 ether);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactInputBuy_withLimit_neverOvercharges(uint256 amount, int24 tick) public {
        amount = bound(amount, 100, 1_000 ether);
        tick = int24(bound(int256(tick), -3_000, -1));
        uint256 before = payer.balance;
        try trader.swapWith(key, SwapParams(true, -int256(amount), TickMath.getSqrtPriceAtTick(tick))) returns (
            BalanceDelta d
        ) {
            uint256 cut = payer.balance - before;
            assertEq(ethPaid(d), amount, "a filled request is charged exactly what was asked");
            assertEq(cut, amount / 100, "and the cut is 1% of it");
        } catch {
            assertEq(payer.balance, before, "a refused fill pays nothing");
        }
    }

    // ------------------------------------------------------------------ a beneficiary that re-syncs the manager

    function _crownContract(address beneficiary) internal {
        vm.warp(block.timestamp + 7 days);
        MockERC20 rival = new MockERC20("Crown Demo", "CRWN", 1);
        vm.deal(beneficiary, 1 ether);
        vm.prank(beneficiary);
        uint256 id = registry.openChallenge{value: 0.01 ether}(CRWN, address(rival));
        vm.prank(beneficiary);
        registry.stake{value: 0.05 ether}(id, CrownRegistry.Side.Challenger);
        vm.warp(block.timestamp + 96 hours);
        registry.finalize(id);
        assertEq(registry.beneficiaryOf(CRWN), beneficiary);
    }

    function test_beneficiaryResettingTheSync_isPaidAsClaimAndThePrepayRouterSettles() public {
        address hostile = address(new SyncingBeneficiary(manager, ETH));
        _crownContract(hostile);
        PrepayRouter r = new PrepayRouter(manager);
        token.transfer(address(r), 10 ether);
        uint256 before = hostile.balance;
        BalanceDelta d = r.sell(key, 1 ether);
        assertGt(d.amount0(), 0);
        uint256 cut = manager.balanceOf(hostile, 0);
        assertGt(cut, 0, "the transfer was rolled back and the cut became a claim");
        assertEq(hostile.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    function test_beneficiarySyncingTheToken_isPaidAsClaimAndTheNativeBuyerSettles() public {
        address hostile = address(new SyncingBeneficiary(manager, Currency.wrap(address(token))));
        _crownContract(hostile);
        // Swapper settles ETH after the swap with sync then settle{value}: a stale synced token would break it
        uint256 before = hostile.balance;
        BalanceDelta d = trader.swap(key, true, 1 ether);
        assertEq(ethPaid(d), 1 ether);
        assertEq(manager.balanceOf(hostile, 0), 0.01 ether);
        assertEq(hostile.balance, before);
    }

    // ------------------------------------------------------------------ an ERC-20 currency0 whose balanceOf reverts

    function test_erc20Currency0_revertingBalanceOf_paysAsClaimInsteadOfBlocking() public {
        PausableBalanceToken a;
        MockERC20 b;
        // find a pausable token that sorts below its pair so it is currency0
        for (uint256 i; i < 32; ++i) {
            a = new PausableBalanceToken("Alpha", "ALPH");
            b = new MockERC20("Beta", "BETA", 0);
            if (address(a) < address(b)) break;
        }
        require(address(a) < address(b), "no ordering found");
        address kingBen = makeAddr("kingBen");
        MockERC20 kingTok = new MockERC20("King", "KNG", 1);
        registry.registerKing(keccak256("KNG"), address(kingTok), kingBen);
        PoolKey memory k =
            PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), POOL_FEE, SPACING, IHooks(address(hook)));
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("KNG"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(a), address(lp), 1_000_000 ether);
        deal(address(b), address(lp), 1_000_000 ether);
        deal(address(a), address(trader), 1_000_000 ether);
        deal(address(b), address(trader), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);

        trader.swap(k, true, 1 ether);
        assertEq(a.balanceOf(kingBen), 0.01 ether, "paid directly while the balance is readable");

        a.setPaused(true);
        // balanceOf reverts, but the swap must still go through; the cut is minted as a claim
        BalanceDelta d = trader.swap(k, false, 1 ether);
        assertGt(d.amount0(), 0);
        assertGt(manager.balanceOf(kingBen, Currency.wrap(address(a)).toId()), 0);
        a.setPaused(false);
    }

    // ------------------------------------------------------------------ opening pools on a squatted or unreadable ticker

    function test_afterInitialize_refusesAPoolWhoseTickerIsHeldByAnotherToken() public {
        MockERC20 squat = new MockERC20("Squat", "SQAT", 1);
        address squatter = makeAddr("squatter");
        registry.registerKing(keccak256("SQAT"), address(squat), squatter);
        MockERC20 mine = new MockERC20("Mine", "SQAT", 1);
        PoolKey memory k = keyFor(address(mine), hook);
        vm.prank(payer);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        (,, bool set) = hook.poolConfig(k.toId());
        assertFalse(set, "nothing was recorded");
        // the owner can still open it knowingly, naming the ticker explicitly
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("SQAT"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        (bytes32 ticker,, bool live) = hook.poolConfig(k.toId());
        assertEq(ticker, keccak256("SQAT"));
        assertTrue(live);
    }

    function test_afterInitialize_refusesATokenWithoutAReadableStringSymbol() public {
        Bytes32SymbolToken t = new Bytes32SymbolToken();
        PoolKey memory k = keyFor(address(t), hook);
        vm.prank(payer);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        // configured explicitly, it can open and pay a ticker that has a king
        vm.startPrank(payer);
        hook.configurePool(k, CRWN, 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        (bytes32 ticker,, bool live) = hook.poolConfig(k.toId());
        assertEq(ticker, CRWN);
        assertTrue(live);
    }
}
