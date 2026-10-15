// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CrownHook} from "../../src/CrownHook.sol";
import {CrownRegistry} from "../../src/CrownRegistry.sol";
import {CrownToken} from "../../src/CrownToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {Swapper} from "../mocks/Swapper.sol";

abstract contract CrownFixture is Test {
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes32 internal constant CRWN = keccak256("CRWN");

    address internal factory = makeAddr("factory");
    address internal payer = makeAddr("payer");

    PoolManager internal manager;
    CrownHook internal hook;
    CrownRegistry internal registry;
    CrownToken internal token;
    PoolKey internal key;
    Swapper internal lp;
    Swapper internal trader;

    function deployHook(IPoolManager manager_, uint160 salt) internal returns (CrownHook h) {
        address at = address((salt << 100) | HookFlags.CROWN_HOOK);
        deployCodeTo("CrownHook.sol:CrownHook", abi.encode(manager_, factory, payer), at);
        h = CrownHook(at);
    }

    function keyFor(address tokenAddr, CrownHook h) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(tokenAddr), POOL_FEE, SPACING, IHooks(address(h)));
    }

    function fund(Swapper who, address tokenAddr) internal {
        vm.deal(address(who), 1_000_000 ether);
        deal(tokenAddr, address(who), 1_000_000 ether);
    }

    function setUpPool() internal {
        manager = new PoolManager(address(this));
        hook = deployHook(manager, 0xC0FFEE);
        registry = hook.registry();
        token = new CrownToken();
        key = keyFor(address(token), hook);
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        lp = new Swapper(manager);
        trader = new Swapper(manager);
        fund(lp, address(token));
        fund(trader, address(token));
        lp.modifyLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000 ether);
    }
}
