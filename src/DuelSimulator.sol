// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelHook} from "./DuelHook.sol";
import {DuelRouter} from "./DuelRouter.sol";

/// @title DuelSimulator
/// @notice Never deployed. The app puts this code on the trader's own address for one `eth_call` (a state override),
///         so that a trade runs as the trader, with the trader's ETH, tokens and allowances, and answers what the
///         trader would receive and where the split would stand once the hook has realigned the pools after it.
contract DuelSimulator {
    /// @notice Runs the trade through the router and reads the split after it, and what the trade took of `amountIn`:
    ///         all of it, unless a sale into an ETH pool found too little ETH there even after its passes
    ///         (DuelRouter `SALE_PASSES`).
    /// @dev Send `amountIn` with the call when ETH is paid, nothing otherwise. A token paid is approved here: the
    ///      approval is part of the simulation, like the trade.
    function simulate(
        DuelRouter router,
        DuelHook hook,
        uint256 pairId,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn
    ) external payable returns (uint256 amountOut, uint256 gaugeBps, uint256 paid) {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (!input.isAddressZero()) IERC20(Currency.unwrap(input)).approve(address(router), amountIn);
        uint256 held = input.balanceOf(address(this));
        amountOut = router.swapExactIn{value: msg.value}(key, zeroForOne, amountIn, 0, address(this), block.timestamp);
        gaugeBps = hook.gaugeBps(pairId);
        paid = held - input.balanceOf(address(this));
    }

    /// @notice Sells one side for ETH and buys the other with all of it, through the router, and reads the split
    ///         after: a switch by the ETH pools rather than the pool between the sides. `paid`, as for `simulate`.
    function simulateThroughEth(
        DuelRouter router,
        DuelHook hook,
        uint256 pairId,
        PoolKey calldata keyIn,
        PoolKey calldata keyOut,
        uint256 amountIn
    ) external returns (uint256 amountOut, uint256 gaugeBps, uint256 paid) {
        IERC20 token = IERC20(Currency.unwrap(keyIn.currency1));
        token.approve(address(router), amountIn);
        uint256 held = token.balanceOf(address(this));
        amountOut = router.swapThroughEth(keyIn, keyOut, amountIn, 0, address(this), block.timestamp);
        gaugeBps = hook.gaugeBps(pairId);
        paid = held - token.balanceOf(address(this));
    }

    /// @notice Sells one side for ETH through the router's `sell`, which takes what its own pool cannot buy back through
    ///         the pool between the sides into the other side's ETH pool, and reads the split after: `paid`, as for
    ///         `simulate`, and the other side's tokens the sale paid back, where that pool could not buy them all.
    function simulateSale(
        DuelRouter router,
        DuelHook hook,
        uint256 pairId,
        PoolKey calldata keyIn,
        PoolKey calldata keyCross,
        PoolKey calldata keyOther,
        uint256 amountIn
    ) external returns (uint256 amountOut, uint256 gaugeBps, uint256 paid, uint256 other) {
        IERC20 token = IERC20(Currency.unwrap(keyIn.currency1));
        IERC20 otherToken = IERC20(Currency.unwrap(keyOther.currency1));
        token.approve(address(router), amountIn);
        uint256 held = token.balanceOf(address(this));
        uint256 heldOther = otherToken.balanceOf(address(this));
        amountOut = router.sell(keyIn, keyCross, keyOther, amountIn, 0, address(this), block.timestamp);
        gaugeBps = hook.gaugeBps(pairId);
        paid = held - token.balanceOf(address(this));
        other = otherToken.balanceOf(address(this)) - heldOther;
    }

    /// @dev The router refunds unspent ETH to its caller.
    receive() external payable {}
}
