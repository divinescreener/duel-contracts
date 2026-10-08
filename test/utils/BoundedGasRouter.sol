// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev A caller that gives `PoolManager.swap` a gas of its choosing and keeps its own to settle afterwards: the
///      shape a swap takes to starve the hook's arbitrage without starving the swap itself.
contract BoundedGasRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint256 swapGas) external payable {
        manager.unlock(abi.encode(key, zeroForOne, amountSpecified, swapGas, msg.sender));
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 swapGas, address user) =
            abi.decode(data, (PoolKey, bool, int256, uint256, address));
        BalanceDelta delta = manager.swap{gas: swapGas}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _clear(key.currency0, delta.amount0(), user);
        _clear(key.currency1, delta.amount1(), user);
        return "";
    }

    function _clear(Currency currency, int128 amount, address user) internal {
        if (amount > 0) {
            manager.take(currency, user, uint256(int256(amount)));
        } else if (amount < 0) {
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: uint256(int256(-amount))}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(user, address(manager), uint256(int256(-amount)));
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
