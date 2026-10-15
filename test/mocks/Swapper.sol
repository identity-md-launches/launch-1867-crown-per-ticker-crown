// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Test router: swaps and modifies liquidity from its own balance, settling after the action (as v4 routers
/// do), and keeps whatever the pool pays out.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Exact-input swap of `amount`.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (BalanceDelta) {
        return swapExact(key, zeroForOne, -int256(amount));
    }

    /// @notice Swap with v4's sign convention: negative `amountSpecified` is exact input, positive exact output.
    function swapExact(PoolKey memory key, bool zeroForOne, int256 amountSpecified) public returns (BalanceDelta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory data = abi.encode(uint8(0), abi.encode(key, SwapParams(zeroForOne, amountSpecified, limit)));
        return abi.decode(manager.unlock(data), (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        bytes memory data = abi.encode(
            uint8(1), abi.encode(key, ModifyLiquidityParams(tickLower, tickUpper, liquidity, bytes32(0)))
        );
        return abi.decode(manager.unlock(data), (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (uint8 action, bytes memory data) = abi.decode(raw, (uint8, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        if (action == 0) {
            SwapParams memory params;
            (key, params) = abi.decode(data, (PoolKey, SwapParams));
            delta = manager.swap(key, params, "");
        } else {
            ModifyLiquidityParams memory params;
            (key, params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
