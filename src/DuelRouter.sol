// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DuelVersion} from "./libraries/DuelVersion.sol";

/// @title DuelRouter
/// @notice Minimal exact-input router used by the Duel app to join a side, leave it or switch sides.
/// @dev Works with any Uniswap V4 pool. Duel pools also trade through the Universal Router and any other V4 router:
///      the hook applies the same rules whoever routes the swap.
///      A sale into a Duel ETH pool stops at the pool's launch price once its ETH is spent: its holders can hold more
///      than it can buy back, since the hook's realignment after a purchase sells into it tokens taken from the pool
///      between the sides. After a sale, the realignment buys them back from it, and this router sells what is left
///      again (`SALE_PASSES`). What the realignment can no longer buy back, its other side's pool short of ETH too,
///      `sell` takes through the pool between the sides into the other side's ETH pool, which holds the ETH paying
///      for it: a holder leaves in one transaction.
contract DuelRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @dev What `unlockCallback` runs: one swap, a token sold for ETH and that ETH spent on another token, or a sale
    ///      that ends through the pool between the sides.
    enum Route {
        Single,
        ThroughEth,
        Sale
    }

    struct SwapData {
        address payer;
        address recipient;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    struct ThroughEthData {
        address payer;
        address recipient;
        PoolKey keyIn;
        PoolKey keyOut;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    struct SaleData {
        address payer;
        address recipient;
        PoolKey keyIn;
        PoolKey keyCross;
        PoolKey keyOther;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    /// @notice An EIP-2612 permit the caller signed for this router, for exactly the amount a swap sells.
    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error Expired();
    error InsufficientValue();
    error TooLittleReceived();
    error NotPoolManager();
    error RefundFailed();
    error NotAnEthPool();
    error NotAToken();
    error NotACrossPool();

    /// @notice The most swaps a sale into an ETH pool makes: the first, then one more for what is left after each
    ///         realignment, while the pool's price is under the swaps' limit.
    uint256 public constant SALE_PASSES = 8;
    /// @notice Version of the launchpad this contract is part of (DuelVersion).
    uint256 public constant VERSION = DuelVersion.NUMBER;
    /// @notice Code name of the launchpad's version.
    string public constant CODENAME = DuelVersion.CODENAME;
    /// @notice Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Swaps `amountIn` of the input currency for at least `minAmountOut` of the output currency.
    /// @dev Native ETH input is paid with `msg.value`; what is left of it is refunded to the caller, and only that: ETH
    ///      the router held before the call (it accepts none: sent by force) stays where it is. ERC-20 input is pulled
    ///      from the caller, who must have approved this router.
    /// @return amountOut Amount received by `recipient`, net of the hook's fees.
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (input.isAddressZero() && msg.value < amountIn) revert InsufficientValue();
        // ETH the router held before this call is not this caller's to be sent: a caller that cannot take ETH would
        // fail on a wei someone forced here
        uint256 held = address(this).balance - msg.value;

        SwapData memory d = SwapData(msg.sender, recipient, key, zeroForOne, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.Single, abi.encode(d))), (uint256));

        uint256 leftover = address(this).balance - held;
        if (leftover > 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice Sells `amountIn` of `keyIn`'s token for ETH and spends all of that ETH on `keyOut`'s token, for at least
    ///         `minAmountOut` of it: a switch between two sides through their ETH pools, deeper than a pool between
    ///         them.
    /// @dev Both pools pair ETH (currency0) with a token (currency1), as Duel's ETH pools do. The ETH never leaves the
    ///      PoolManager: the sale's output is the purchase's input. The token sold is pulled from the caller, who must
    ///      have approved this router; ETH the purchase could not spend (its pool out of tokens) is paid to the caller.
    /// @return amountOut Amount of `keyOut`'s token received by `recipient`, net of the hook's fees.
    function swapThroughEth(
        PoolKey calldata keyIn,
        PoolKey calldata keyOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!keyIn.currency0.isAddressZero() || !keyOut.currency0.isAddressZero()) revert NotAnEthPool();
        ThroughEthData memory d = ThroughEthData(msg.sender, recipient, keyIn, keyOut, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.ThroughEth, abi.encode(d))), (uint256));
    }

    /// @notice Sells `amountIn` of `keyIn`'s token for at least `minAmountOut` ETH: into its own ETH pool first, in passes
    ///         (`SALE_PASSES`), then what that pool cannot buy back through the pool between the sides (`keyCross`)
    ///         into the other side's ETH pool (`keyOther`), in passes too. The realignments may leave the ETH paying for
    ///         a side's tokens in the other side's pool: the sale reaches it there, as they would.
    /// @dev Both ETH pools pair ETH (currency0) with a token (currency1), and the pool between the sides pairs their two
    ///      tokens, as Duel's pools do. The token sold is pulled from the caller, who must have approved this router:
    ///      all of it, the pool between the sides, full range, taking whatever the side's own pool left. What the other
    ///      side's pool cannot buy back of the tokens it gave, its ETH spent too, is paid to `recipient` in that token.
    /// @return amountOut ETH received by `recipient`, net of the hook's fees.
    function sell(
        PoolKey calldata keyIn,
        PoolKey calldata keyCross,
        PoolKey calldata keyOther,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        _checkSale(keyIn, keyCross, keyOther);
        SaleData memory d = SaleData(msg.sender, recipient, keyIn, keyCross, keyOther, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.Sale, abi.encode(d))), (uint256));
    }

    /// @notice `sell` with the token sold approved by the caller's permit in the same transaction (see
    ///         `swapExactInWithPermit`).
    function sellWithPermit(
        PoolKey calldata keyIn,
        PoolKey calldata keyCross,
        PoolKey calldata keyOther,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        _checkSale(keyIn, keyCross, keyOther);
        _permit(keyIn.currency1, amountIn, permit);
        SaleData memory d = SaleData(msg.sender, recipient, keyIn, keyCross, keyOther, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.Sale, abi.encode(d))), (uint256));
    }

    /// @notice `swapExactIn` of a token approved by the caller's permit in the same transaction: a sale or a switch in
    ///         one go, with no approval sent before.
    /// @dev The permit is used first, and its failure ignored: anyone may send it ahead once it is public, and the
    ///      allowance it sets is then already there. A permit that fails changes nothing: the swap takes what the
    ///      allowance already standing covers, and reverts if it falls short. A swap that fills only in part leaves the
    ///      rest of the permit's allowance standing (its deadline bounds when it can be used, not the allowance it
    ///      sets). The router only ever pulls tokens from its caller.
    function swapExactInWithPermit(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        _permit(zeroForOne ? key.currency0 : key.currency1, amountIn, permit);
        SwapData memory d = SwapData(msg.sender, recipient, key, zeroForOne, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.Single, abi.encode(d))), (uint256));
    }

    /// @notice `swapThroughEth` with the token sold approved by the caller's permit in the same transaction (see
    ///         `swapExactInWithPermit`).
    function swapThroughEthWithPermit(
        PoolKey calldata keyIn,
        PoolKey calldata keyOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!keyIn.currency0.isAddressZero() || !keyOut.currency0.isAddressZero()) revert NotAnEthPool();
        _permit(keyIn.currency1, amountIn, permit);
        ThroughEthData memory d = ThroughEthData(msg.sender, recipient, keyIn, keyOut, amountIn, minAmountOut);
        amountOut = abi.decode(poolManager.unlock(abi.encode(Route.ThroughEth, abi.encode(d))), (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Route route, bytes memory swap) = abi.decode(data, (Route, bytes));
        uint256 amountOut;
        if (route == Route.Single) amountOut = _single(abi.decode(swap, (SwapData)));
        else if (route == Route.ThroughEth) amountOut = _throughEth(abi.decode(swap, (ThroughEthData)));
        else amountOut = _sale(abi.decode(swap, (SaleData)));
        return abi.encode(amountOut);
    }

    function _single(SwapData memory d) internal returns (uint256 amountOut) {
        uint256 paid;
        (paid, amountOut) = _swapIn(d.key, d.zeroForOne, d.amountIn);
        if (amountOut < d.minAmountOut) revert TooLittleReceived();

        (Currency input, Currency output) =
            d.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);
        // ETH too is synced before it is settled: `sync` is open to anyone, and a token left synced earlier in the
        // transaction (another party's call in a bundle) would make the PoolManager refuse the ETH (NonzeroNativeValue)
        poolManager.sync(input);
        if (input.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            IERC20(Currency.unwrap(input)).safeTransferFrom(d.payer, address(poolManager), paid);
            poolManager.settle();
        }
        poolManager.take(output, d.recipient, amountOut);
    }

    function _throughEth(ThroughEthData memory d) internal returns (uint256 amountOut) {
        // the token sold for ETH: of an ETH pool out of ETH, only what it can pay for
        (uint256 sold, uint256 eth) = _swapIn(d.keyIn, false, d.amountIn);
        if (eth == 0) revert TooLittleReceived();

        // all of that ETH for the other token
        BalanceDelta bought = poolManager.swap(
            d.keyOut,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -eth.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        amountOut = uint256(int256(bought.amount1()));
        if (amountOut < d.minAmountOut) revert TooLittleReceived();

        Currency input = d.keyIn.currency1;
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransferFrom(d.payer, address(poolManager), sold);
        poolManager.settle();
        poolManager.take(d.keyOut.currency1, d.recipient, amountOut);
        uint256 spent = uint256(int256(-bought.amount0()));
        if (spent < eth) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, d.payer, eth - spent);
    }

    function _sale(SaleData memory d) internal returns (uint256 amountOut) {
        // into the side's own ETH pool, as far as its ETH and the realignments after each pass let it pay
        (uint256 sold, uint256 eth) = _swapIn(d.keyIn, false, d.amountIn);
        uint256 left;
        if (sold < d.amountIn) {
            // the rest through the pool between the sides, which takes it all, then into the other side's ETH pool
            (uint256 across, uint256 other) =
                _swapOnce(d.keyCross, d.keyCross.currency0 == d.keyIn.currency1, d.amountIn - sold);
            sold += across;
            (uint256 soldOther, uint256 ethOther) = _swapIn(d.keyOther, false, other);
            eth += ethOther;
            left = other - soldOther;
        }
        amountOut = eth;
        if (amountOut < d.minAmountOut) revert TooLittleReceived();

        Currency input = d.keyIn.currency1;
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransferFrom(d.payer, address(poolManager), sold);
        poolManager.settle();
        if (amountOut > 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, d.recipient, amountOut);
        if (left > 0) poolManager.take(d.keyOther.currency1, d.recipient, left);
    }

    /// @dev Two ETH pools, and the pool between their tokens.
    function _checkSale(PoolKey calldata keyIn, PoolKey calldata keyCross, PoolKey calldata keyOther) internal pure {
        if (!keyIn.currency0.isAddressZero() || !keyOther.currency0.isAddressZero()) revert NotAnEthPool();
        Currency token = keyIn.currency1;
        Currency other = keyOther.currency1;
        if (
            token == other || !(keyCross.currency0 == token && keyCross.currency1 == other)
                && !(keyCross.currency0 == other && keyCross.currency1 == token)
        ) revert NotACrossPool();
    }

    /// @dev Swaps `amountIn` of the input currency, as much of it as fills: what was paid of it, and what was received.
    ///      A sale into an ETH pool (a token for ETH, its currency0) that stops short is sent again for what is left,
    ///      once the hook has realigned the pools after it: up to `SALE_PASSES` swaps in all, while the pool's price
    ///      is under the swaps' limit (a pass that took nothing left it there, unless the realignment after it
    ///      brought the pool back). Each pass pays the hook's fee on its own ETH, as separate sales would.
    function _swapIn(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 paid, uint256 received)
    {
        uint256 passes = !zeroForOne && key.currency0.isAddressZero() ? SALE_PASSES : 1;
        for (uint256 pass; pass < passes && paid < amountIn; ++pass) {
            // a pool left at the price limit, its ETH spent and nothing realigned since, takes no more (and a swap
            // from there would revert)
            if (passes > 1 && _atLimit(key)) break;
            (uint256 paidNow, uint256 receivedNow) = _swapOnce(key, zeroForOne, amountIn - paid);
            paid += paidNow;
            received += receivedNow;
        }
    }

    /// @dev One exact-input swap to the far price limit: what it took of `amountIn`, and what it gave.
    function _swapOnce(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 paid, uint256 received)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        paid = uint256(int256(-inDelta));
        received = uint256(int256(outDelta));
    }

    /// @dev Whether a sale's pool sits at the limit of the price a sale's swap can take it to.
    function _atLimit(PoolKey memory key) internal view returns (bool) {
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        return price >= TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev Approves this router for `amount` of `token` with the caller's permit, if it still can (see
    ///      `swapExactInWithPermit`). ETH needs none: it is paid with the call.
    function _permit(Currency token, uint256 amount, Permit calldata p) internal {
        if (token.isAddressZero()) revert NotAToken();
        try IERC20Permit(Currency.unwrap(token)).permit(msg.sender, address(this), amount, p.deadline, p.v, p.r, p.s) {}
            catch {}
    }
}
