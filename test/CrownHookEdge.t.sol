// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {MultiSwapper} from "./mocks/MultiSwapper.sol";
import {CrownFixture} from "./utils/CrownFixture.sol";

contract RejectsEther {
    receive() external payable {
        revert("no");
    }
}

/// @notice Hook edges the main suite does not reach: sub-cut swaps, batched routers, every swap shape under fuzz,
/// an ERC-20/ERC-20 pool, a second pool on the same ticker, and claim redemption by the wrong holder.
contract CrownHookEdgeTest is CrownFixture {
    Currency internal constant ETH = Currency.wrap(address(0));

    function setUp() public {
        setUpPool();
    }

    function test_swapBelowOneHundredWei_paysNoCutAndStillSettles() public {
        uint256 before = payer.balance;
        BalanceDelta d = trader.swap(key, true, 99);
        assertEq(uint256(-int256(d.amount0())), 99);
        assertEq(payer.balance, before, "99 wei rounds to no cut");
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        trader.swap(key, true, 100);
        assertEq(payer.balance - before, 1, "100 wei pays one wei");
        assertEq(hook.crownPaid(CRWN, ETH), 1);
    }

    function test_batchedRouter_paysTheCutOnEverySwapInOneUnlock() public {
        MultiSwapper router = new MultiSwapper(manager);
        fund(Swapper(payable(address(router))), address(token));
        bool[] memory dirs = new bool[](3);
        uint256[] memory amounts = new uint256[](3);
        (dirs[0], amounts[0]) = (true, 1 ether);
        (dirs[1], amounts[1]) = (false, 1 ether);
        (dirs[2], amounts[2]) = (true, 0.5 ether);

        uint256 before = payer.balance;
        BalanceDelta[] memory d = router.swapMany(key, dirs, amounts);
        uint256 total = payer.balance - before;
        uint256 sellCut = total - 0.01 ether - 0.005 ether;
        uint256 received = uint256(int256(d[1].amount0()));
        assertEq(sellCut, (received + sellCut) / 100, "the middle sell paid 1% of its output");
        assertGt(sellCut, 0);
        assertEq(hook.crownPaid(CRWN, ETH), total);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_buyExactOutput(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        uint256 before = payer.balance;
        BalanceDelta d = trader.swapExact(key, true, int256(amount));
        uint256 cut = payer.balance - before;
        assertEq(uint256(int256(d.amount1())), amount, "exact tokens out");
        uint256 paid = uint256(-int256(d.amount0()));
        assertEq(cut, (paid - cut) / 100, "1% of the pool's input, added to the trader's payment");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sellExactInput(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        uint256 before = payer.balance;
        BalanceDelta d = trader.swap(key, false, amount);
        uint256 cut = payer.balance - before;
        assertEq(uint256(-int256(d.amount1())), amount, "exact tokens in");
        uint256 received = uint256(int256(d.amount0()));
        assertEq(cut, (received + cut) / 100, "1% of the pool's output, withheld from the trader");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sellExactOutput(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        uint256 before = payer.balance;
        BalanceDelta d = trader.swapExact(key, false, int256(amount));
        assertEq(uint256(int256(d.amount0())), amount, "exact ETH out");
        assertEq(payer.balance - before, amount / 100, "1% of the requested output, on top");
        assertEq(hook.crownPaid(CRWN, ETH), amount / 100);
    }

    function test_erc20PairPool_paysTheCutInCurrency0() public {
        MockERC20 a = new MockERC20("Alpha", "ALPH", 0);
        MockERC20 b = new MockERC20("Beta", "BETA", 0);
        (MockERC20 c0, MockERC20 c1) = address(a) < address(b) ? (a, b) : (b, a);
        address kingBen = makeAddr("kingBen");
        MockERC20 kingTok = new MockERC20("King", "KNG", 1);
        registry.registerKing(keccak256("KNG"), address(kingTok), kingBen);

        PoolKey memory k =
            PoolKey(Currency.wrap(address(c0)), Currency.wrap(address(c1)), POOL_FEE, SPACING, IHooks(address(hook)));
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("KNG"), 250);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(c0), address(lp), 1_000_000 ether);
        deal(address(c1), address(lp), 1_000_000 ether);
        deal(address(c0), address(trader), 1_000_000 ether);
        deal(address(c1), address(trader), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);

        BalanceDelta d = trader.swap(k, true, 2 ether);
        assertEq(uint256(-int256(d.amount0())), 2 ether);
        assertEq(c0.balanceOf(kingBen), 0.05 ether, "2.5% of the currency0 input, in currency0");
        assertEq(c1.balanceOf(kingBen), 0);
        assertEq(kingBen.balance, 0);
        assertEq(hook.crownPaid(keccak256("KNG"), Currency.wrap(address(c0))), 0.05 ether);
        assertEq(hook.crownPaid(keccak256("KNG"), ETH), 0);
        assertEq(c0.balanceOf(address(hook)), 0);

        // a sell on the same pool pays in currency0 too
        trader.swap(k, false, 1 ether);
        assertGt(c0.balanceOf(kingBen), 0.05 ether);
        assertEq(c1.balanceOf(kingBen), 0);
    }

    function test_secondPoolOnTheLaunchToken_sharesTheKingAndDoesNotRecrown() public {
        PoolKey memory k2 = PoolKey(ETH, Currency.wrap(address(token)), 3_000, 60, IHooks(address(hook)));
        (address kingBefore, address benBefore, uint64 sinceBefore) = registry.king(CRWN);
        vm.prank(payer);
        manager.initialize(k2, SQRT_PRICE_1_1);
        (bytes32 ticker, uint16 bps, bool set) = hook.poolConfig(k2.toId());
        assertEq(ticker, CRWN);
        assertEq(bps, 100);
        assertTrue(set);
        (address kingAfter, address benAfter, uint64 sinceAfter) = registry.king(CRWN);
        assertEq(kingAfter, kingBefore);
        assertEq(benAfter, benBefore);
        assertEq(sinceAfter, sinceBefore, "the reign was not reset");

        lp.modifyLiquidity(k2, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100 ether);
        uint256 before = payer.balance;
        trader.swap(k2, true, 1 ether);
        assertEq(payer.balance - before, 0.01 ether);
        assertEq(hook.crownPaid(CRWN, ETH), 0.01 ether, "one counter per ticker across pools");
    }

    function test_configurePool_canBeRevisedUntilThePoolOpens() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, CRWN, 500);
        hook.configurePool(k, CRWN, 50);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.expectRevert(CrownHook.PoolAlreadyLive.selector);
        hook.configurePool(k, CRWN, 500);
        vm.stopPrank();
        (, uint16 bps,) = hook.poolConfig(k.toId());
        assertEq(bps, 50, "the last configuration before opening wins");
        (bytes32 pendingTicker,, bool pendingSet) = hook.pendingConfig(k.toId());
        assertEq(pendingTicker, bytes32(0));
        assertFalse(pendingSet, "pending config is consumed");
    }

    function test_redeemClaim_onlyTheHolderAndOnlyWhatItHolds() public {
        // pay a rejecting beneficiary so a claim exists
        address b = address(new RejectsEther());
        MockERC20 kingTok = new MockERC20("Reject", "RJCT", 1);
        registry.registerKing(keccak256("RJCT"), address(kingTok), b);
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("RJCT"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);
        trader.swap(k, true, 1 ether);
        assertEq(manager.balanceOf(b, 0), 0.01 ether);

        address thief = makeAddr("thief");
        vm.startPrank(thief);
        manager.setOperator(address(hook), true);
        vm.expectRevert();
        hook.redeemClaim(ETH, 0.01 ether);
        vm.stopPrank();
        assertEq(manager.balanceOf(b, 0), 0.01 ether, "someone else's claim is untouched");

        // the claim moves with ERC-6909 transfer, and the new holder cannot take more than it holds
        vm.prank(b);
        manager.transfer(thief, 0, 0.004 ether);
        vm.startPrank(thief);
        vm.expectRevert();
        hook.redeemClaim(ETH, 0.004 ether + 1);
        uint256 before = thief.balance;
        hook.redeemClaim(ETH, 0.004 ether);
        vm.stopPrank();
        assertEq(thief.balance - before, 0.004 ether);
        assertEq(manager.balanceOf(thief, 0), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }
}
