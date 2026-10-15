// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {CrownFixture} from "./utils/CrownFixture.sol";

contract RejectingBeneficiary {
    receive() external payable {
        revert("no ether");
    }
}

contract GasBurningBeneficiary {
    receive() external payable {
        while (true) {}
    }
}

/// @dev Opens a debt in the manager while being paid, which would make the swapper's unlock revert if it stuck.
contract DebtOpeningBeneficiary {
    IPoolManager internal immutable manager;
    bool internal busy;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {
        if (busy) return;
        busy = true;
        manager.take(Currency.wrap(address(0)), address(this), 1);
        busy = false;
    }
}

contract CrownHookTest is CrownFixture {
    function setUp() public {
        setUpPool();
    }

    function ethPaid(BalanceDelta d) internal pure returns (uint256) {
        return uint256(-int256(d.amount0()));
    }

    // ------------------------------------------------------------------ configuration

    function test_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.CROWN_HOOK);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(CrownHook.ZeroAddress.selector);
        new CrownHook(IPoolManager(address(0)), factory, payer);
        vm.expectRevert(CrownHook.ZeroAddress.selector);
        new CrownHook(manager, address(0), payer);
        vm.expectRevert(CrownHook.ZeroAddress.selector);
        new CrownHook(manager, factory, address(0));
    }

    function test_afterInitialize_registersPoolAndCrownsGenesisKing() public view {
        (bytes32 ticker, uint16 bps, bool set) = hook.poolConfig(key.toId());
        assertEq(ticker, CRWN);
        assertEq(bps, 100);
        assertTrue(set);
        (address kingToken, address beneficiary,) = registry.king(CRWN);
        assertEq(kingToken, address(token));
        assertEq(beneficiary, payer);
        assertEq(hook.owner(), payer);
        assertEq(hook.factory(), factory);
    }

    function test_afterInitialize_refusesOtherInitializers() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 1 ether);
        PoolKey memory k = keyFor(address(other), hook);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        // the owner may open further pools
        vm.prank(payer);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_callbacksRefuseNonManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.afterInitialize(factory, key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, -1, 0), "");
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(CrownHook.NotSelf.selector);
        hook.payCrown(Currency.wrap(address(0)), address(this), 1);
    }

    function test_configurePool_rules() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 1 ether);
        PoolKey memory k = keyFor(address(other), hook);
        vm.expectRevert(CrownHook.NotOwner.selector);
        hook.configurePool(k, CRWN, 200);
        vm.startPrank(payer);
        vm.expectRevert(CrownHook.BpsTooHigh.selector);
        hook.configurePool(k, CRWN, 501);
        vm.expectRevert(CrownHook.ZeroTicker.selector);
        hook.configurePool(k, bytes32(0), 200);
        vm.expectRevert(CrownHook.PoolAlreadyLive.selector);
        hook.configurePool(key, CRWN, 200);
        PoolKey memory wrong = PoolKey(k.currency0, k.currency1, POOL_FEE, SPACING, IHooks(address(0)));
        vm.expectRevert(CrownHook.WrongHook.selector);
        hook.configurePool(wrong, CRWN, 200);
        // OTHR pool pays the CRWN king at 5%
        hook.configurePool(k, CRWN, 500);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        (bytes32 ticker, uint16 bps,) = hook.poolConfig(k.toId());
        assertEq(ticker, CRWN);
        assertEq(bps, 500);

        fund(trader, address(other));
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);
        uint256 before = payer.balance;
        trader.swap(k, true, 1 ether);
        assertEq(payer.balance - before, 0.05 ether);
    }

    // ------------------------------------------------------------------ the cut, four ways

    function test_buyExactInput_paysOnePercentOfInput() public {
        uint256 before = payer.balance;
        BalanceDelta d = trader.swap(key, true, 1 ether);
        assertEq(ethPaid(d), 1 ether, "trader pays exactly the input");
        assertEq(payer.balance - before, 0.01 ether);
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(0))), 0.01 ether);
        assertEq(address(hook).balance, 0, "hook holds nothing");
    }

    function test_buyExactOutput_paysOnePercentOnTopOfInput() public {
        uint256 before = payer.balance;
        BalanceDelta d = trader.swapExact(key, true, 1 ether);
        uint256 cut = payer.balance - before;
        assertEq(uint256(int256(d.amount1())), 1 ether, "exact tokens out");
        assertEq(cut, (ethPaid(d) - cut) / 100, "1% of the pool input");
        assertGt(cut, 0);
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(0))), cut);
    }

    function test_sellExactInput_paysOnePercentOfOutput() public {
        uint256 before = payer.balance;
        BalanceDelta d = trader.swap(key, false, 1 ether);
        uint256 cut = payer.balance - before;
        uint256 received = uint256(int256(d.amount0()));
        assertEq(cut, (received + cut) / 100, "1% of the pool output");
        assertGt(cut, 0);
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(0))), cut);
    }

    function test_sellExactOutput_paysOnePercentOfOutput() public {
        uint256 before = payer.balance;
        BalanceDelta d = trader.swapExact(key, false, 1 ether);
        assertEq(uint256(int256(d.amount0())), 1 ether, "exact ETH out");
        assertEq(payer.balance - before, 0.01 ether);
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(0))), 0.01 ether);
    }

    function testFuzz_buyExactInput(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        uint256 before = payer.balance;
        BalanceDelta d = trader.swap(key, true, amount);
        assertEq(ethPaid(d), amount);
        assertEq(payer.balance - before, amount / 100);
        assertEq(hook.crownPaid(CRWN, Currency.wrap(address(0))), amount / 100);
    }

    // ------------------------------------------------------------------ never blocking a swap

    function test_freshManagerSeededWithTokensOnly_mintsClaimThenRedeems() public {
        PoolManager fresh = new PoolManager(address(this));
        CrownHook h = deployHook(fresh, 0xBEEF);
        MockERC20 t = new MockERC20("Fresh", "FRSH", 0);
        PoolKey memory k = keyFor(address(t), h);
        vm.prank(factory);
        fresh.initialize(k, SQRT_PRICE_1_1);
        Swapper seeder = new Swapper(fresh);
        Swapper buyer = new Swapper(fresh);
        fund(seeder, address(t));
        fund(buyer, address(t));
        // a range below the price holds only the token (currency1)
        seeder.modifyLiquidity(k, -6000, 0, 100 ether);
        assertEq(address(fresh).balance, 0);

        uint256 before = payer.balance;
        buyer.swap(k, true, 0.1 ether);
        assertEq(payer.balance, before, "nothing to transfer from");
        assertEq(fresh.balanceOf(payer, 0), 0.001 ether, "claim minted to the beneficiary");
        assertEq(h.crownPaid(keccak256("FRSH"), Currency.wrap(address(0))), 0.001 ether);

        vm.startPrank(payer);
        fresh.setOperator(address(h), true);
        h.redeemClaim(Currency.wrap(address(0)), 0.001 ether);
        vm.stopPrank();
        assertEq(payer.balance - before, 0.001 ether);
        assertEq(fresh.balanceOf(payer, 0), 0);
    }

    function test_redeemClaim_requiresOperatorApproval() public {
        vm.prank(payer);
        vm.expectRevert();
        hook.redeemClaim(Currency.wrap(address(0)), 1);
    }

    function _otherPoolPaying(address beneficiary) internal returns (PoolKey memory k, bytes32 ticker) {
        MockERC20 king = new MockERC20("Reject", "RJCT", 1);
        ticker = keccak256("RJCT");
        registry.registerKing(ticker, address(king), beneficiary);
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, ticker, 200);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        deal(address(other), address(trader), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);
    }

    function test_beneficiaryRejectingEther_getsClaimAndSwapProceeds() public {
        address b = address(new RejectingBeneficiary());
        (PoolKey memory k, bytes32 ticker) = _otherPoolPaying(b);
        BalanceDelta d = trader.swap(k, true, 1 ether);
        assertEq(ethPaid(d), 1 ether);
        assertEq(manager.balanceOf(b, 0), 0.02 ether);
        assertEq(hook.crownPaid(ticker, Currency.wrap(address(0))), 0.02 ether);
    }

    function test_gasBurningBeneficiary_cannotBlockTheSwap() public {
        address b = address(new GasBurningBeneficiary());
        (PoolKey memory k,) = _otherPoolPaying(b);
        trader.swap{gas: 2_000_000}(k, true, 1 ether);
        assertEq(manager.balanceOf(b, 0), 0.02 ether);
    }

    function test_beneficiaryOpeningADebt_isUndoneAndPaidAsClaim() public {
        address b = address(new DebtOpeningBeneficiary(manager));
        (PoolKey memory k,) = _otherPoolPaying(b);
        trader.swap(k, true, 1 ether);
        assertEq(b.balance, 0, "the transfer and the debt were rolled back");
        assertEq(manager.balanceOf(b, 0), 0.02 ether);
    }

    function test_tickerWithoutKing_skipsTheCut() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, keccak256("NOKING"), 100);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);
        BalanceDelta d = trader.swap(k, true, 1 ether);
        assertEq(ethPaid(d), 1 ether);
        assertEq(hook.crownPaid(keccak256("NOKING"), Currency.wrap(address(0))), 0);
    }

    function test_zeroBpsPool_takesNothing() public {
        MockERC20 other = new MockERC20("Other", "OTHR", 0);
        PoolKey memory k = keyFor(address(other), hook);
        vm.startPrank(payer);
        hook.configurePool(k, CRWN, 0);
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.stopPrank();
        deal(address(other), address(lp), 1_000_000 ether);
        lp.modifyLiquidity(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 100 ether);
        uint256 before = payer.balance;
        trader.swap(k, true, 1 ether);
        assertEq(payer.balance, before);
    }

    function test_feeCollectWithZeroLiquidityChange_isNotBlocked() public {
        trader.swap(key, true, 1 ether);
        trader.swap(key, false, 1 ether);
        BalanceDelta d = lp.modifyLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 0);
        assertGt(d.amount0(), 0);
        assertGt(d.amount1(), 0);
    }

    // ------------------------------------------------------------------ end to end

    function test_endToEnd_buyChallengeStakeFinalizeBuy() public {
        Currency eth = Currency.wrap(address(0));
        address challenger = makeAddr("challenger");
        address backer = makeAddr("backer");
        address loyalist = makeAddr("loyalist");
        vm.deal(challenger, 1 ether);
        vm.deal(backer, 1 ether);
        vm.deal(loyalist, 1 ether);

        // buy: the genesis king's beneficiary (the launch payer) is paid
        uint256 payerBefore = payer.balance;
        trader.swap(key, true, 2 ether);
        uint256 firstCut = payer.balance - payerBefore;
        assertEq(firstCut, 0.02 ether);

        // challenge with the standing challenger candidate, after the minimum reign
        vm.warp(block.timestamp + 7 days);
        CrownChallengerToken rival = new CrownChallengerToken(challenger);
        vm.prank(challenger);
        uint256 id = registry.openChallenge{value: 0.01 ether}(CRWN, address(rival));
        vm.prank(backer);
        registry.stake{value: 0.05 ether}(id, CrownRegistry.Side.Challenger);
        vm.prank(loyalist);
        registry.stake{value: 0.03 ether}(id, CrownRegistry.Side.King);

        // still the old king during window and timelock
        vm.warp(block.timestamp + 72 hours + 24 hours - 1);
        vm.expectRevert(CrownRegistry.TimelockActive.selector);
        registry.finalize(id);
        vm.warp(block.timestamp + 1);
        registry.finalize(id);
        assertEq(registry.beneficiaryOf(CRWN), challenger);

        // buy again: the new king is paid, the old one is not
        uint256 challengerBefore = challenger.balance;
        payerBefore = payer.balance;
        trader.swap(key, true, 3 ether);
        uint256 secondCut = challenger.balance - challengerBefore;
        assertEq(secondCut, 0.03 ether);
        assertEq(payer.balance, payerBefore, "fee recipient changed");
        assertEq(hook.crownPaid(CRWN, eth), firstCut + secondCut, "crownPaid matches the transfers");
        assertEq(address(hook).balance, 0);
    }
}
