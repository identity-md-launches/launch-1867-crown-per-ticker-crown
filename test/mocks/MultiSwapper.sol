// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice A batching router: several exact-input swaps inside one unlock, settled together at the end, the way an
/// aggregator or a multi-hop router does. Lets the tests check the hook's per-swap delta accounting when the
/// swapper's own deltas are still open between swaps.
contract MultiSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Runs `zeroForOne[i]` exact-input swaps of `amounts[i]` on `key`, in order, in one unlock.
    function swapMany(PoolKey memory key, bool[] memory zeroForOne, uint256[] memory amounts)
        external
        returns (BalanceDelta[] memory)
    {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amounts)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, bool[] memory zeroForOne, uint256[] memory amounts) =
            abi.decode(raw, (PoolKey, bool[], uint256[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](amounts.length);
        int256 total0;
        int256 total1;
        for (uint256 i; i < amounts.length; ++i) {
            uint160 limit = zeroForOne[i] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            deltas[i] = manager.swap(key, SwapParams(zeroForOne[i], -int256(amounts[i]), limit), "");
            total0 += deltas[i].amount0();
            total1 += deltas[i].amount1();
        }
        _settle(key.currency0, total0);
        _settle(key.currency1, total1);
        return abi.encode(deltas);
    }

    function _settle(Currency currency, int256 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(-amount);
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(amount));
        }
    }

    receive() external payable {}
}
