// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DuelMath
/// @notice Pure math shared by the Duel contracts: launch prices, liquidity sizing, the closed-form optimal size of
///         the internal triangle arbitrage, the anti-snipe tax curve, tick EMAs and the gauge.
library DuelMath {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = FixedPoint96.Q96;

    /// @notice Launch price of an ETH pool, rounded down to a usable tick.
    /// @dev ETH (address zero) is always currency0, so the pool price is "tokens per wei". The factory bounds the
    ///      starting FDV so that this tick is always positive, which makes truncating division a floor.
    /// @param supply Token supply the FDV refers to.
    /// @param startFdvWei Fully diluted valuation of `supply` at launch, in wei.
    /// @param tickSpacing Tick spacing of the ETH pool.
    /// @return sqrtPriceX96 Square root price at the rounded tick.
    /// @return tick Rounded launch tick, which is also the upper bound of the single-sided position.
    function startPrice(uint256 supply, uint256 startFdvWei, int24 tickSpacing)
        internal
        pure
        returns (uint160 sqrtPriceX96, int24 tick)
    {
        uint256 priceX96 = FullMath.mulDiv(supply, Q96, startFdvWei);
        uint160 rawSqrtPrice = (Math.sqrt(priceX96) << 48).toUint160();
        tick = (TickMath.getTickAtSqrtPrice(rawSqrtPrice) / tickSpacing) * tickSpacing;
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Liquidity of a position that only holds currency1 over [sqrtPriceA, sqrtPriceB].
    function liquidityForAmount1(uint160 sqrtPriceA, uint160 sqrtPriceB, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        return FullMath.mulDiv(amount1, Q96, sqrtPriceB - sqrtPriceA).toUint128();
    }

    /// @notice Liquidity of a two-sided position when the current price lies inside [sqrtPriceA, sqrtPriceB].
    function liquidityForAmounts(
        uint160 sqrtPrice,
        uint160 sqrtPriceA,
        uint160 sqrtPriceB,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        uint256 intermediate = FullMath.mulDiv(sqrtPrice, sqrtPriceB, Q96);
        uint256 liquidity0 = FullMath.mulDiv(amount0, intermediate, sqrtPriceB - sqrtPrice);
        uint256 liquidity1 = FullMath.mulDiv(amount1, Q96, sqrtPrice - sqrtPriceA);
        return Math.min(liquidity0, liquidity1).toUint128();
    }

    /// @notice Virtual reserves of a constant-liquidity range: x = L / sqrtP, y = L * sqrtP.
    /// @return reserve0 Virtual reserve of currency0.
    /// @return reserve1 Virtual reserve of currency1.
    function virtualReserves(uint128 liquidity, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 reserve0, uint256 reserve1)
    {
        reserve0 = FullMath.mulDiv(liquidity, Q96, sqrtPriceX96);
        reserve1 = FullMath.mulDiv(liquidity, sqrtPriceX96, Q96);
    }

    /// @notice Optimal input of a three-hop arbitrage cycle through constant-product ranges, with no fee.
    /// @dev Each hop maps `in` to `out = rOut * in / (rIn + in)`. The composition is `K * e / (M + N * e)` with
    ///      K = ro1 * ro2 * ro3, M = ri1 * ri2 * ri3 and N = ri2 * ri3 + ri3 * ro1 + ro1 * ro2, so the profit
    ///      peaks at e* = (M / N) * (sqrt(K / M) - 1). Everything is computed as WAD ratios to avoid overflow.
    /// @param thresholdBps Edge (K / M - 1) at or under which the cycle is ignored: it must be exceeded.
    /// @return input Optimal input of the first hop, or 0 when the cycle is not worth running.
    function optimalCycleInput(
        uint256 ri1,
        uint256 ro1,
        uint256 ri2,
        uint256 ro2,
        uint256 ri3,
        uint256 ro3,
        uint256 thresholdBps
    ) internal pure returns (uint256 input) {
        uint256 ratio = FullMath.mulDiv(ro1, WAD, ri1);
        ratio = FullMath.mulDiv(ratio, ro2, ri2);
        ratio = FullMath.mulDiv(ratio, ro3, ri3);
        if (ratio <= WAD + (WAD * thresholdBps) / BPS) return 0;

        uint256 q1 = FullMath.mulDiv(ro1, WAD, ri2);
        uint256 q2 = FullMath.mulDiv(q1, ro2, ri3);
        uint256 scale = FullMath.mulDiv(ri1, WAD, WAD + q1 + q2);
        // sqrt(ratio * 1e18) == sqrt(ratio) * 1e9: keeps a WAD result without risking an overflow on wild ratios.
        input = FullMath.mulDiv(scale, Math.sqrt(ratio) * 1e9 - WAD, WAD);
    }

    /// @notice A cycle's input, lowered so that its last hop sells at most `maxSell` tokens: the first two hops of
    ///         `optimalCycleInput`, inverted (`in = rIn * out / (rOut - out)`). A smaller input than the optimum is still
    ///         profitable, just less so.
    function capCycleInput(uint256 input, uint256 ri1, uint256 ro1, uint256 ri2, uint256 ro2, uint256 maxSell)
        internal
        pure
        returns (uint256)
    {
        uint256 out1 = FullMath.mulDiv(ro1, input, ri1 + input);
        if (FullMath.mulDiv(ro2, out1, ri2 + out1) <= maxSell) return input;
        out1 = FullMath.mulDiv(ri2, maxSell, ro2 - maxSell);
        return FullMath.mulDiv(ri1, out1, ro1 - out1);
    }

    /// @notice Anti-snipe tax: `startBps` at launch, halved once more each `window / 14` seconds (whole seconds: over a
    ///         10-second window, 98% reads 49% after one, 6% after three, under 1% from five), zero from `window` on.
    function snipeTaxBps(uint256 startBps, uint256 window, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= window) return 0;
        return startBps >> ((elapsed * 14) / window);
    }

    /// @notice Fractional bits of an EMA: it is kept in 1/65536 of a tick, so that no update loses what it moves.
    uint256 internal constant EMA_FRACTION_BITS = 16;

    /// @notice The EMA of a tick after `elapsed` seconds at the tick `current`, in 1/65536 of a tick: it closes
    ///         1 - e^(-elapsed / 30 minutes) of its distance to `current`, rounded to the nearest 65536th. A price held
    ///         30 minutes weighs 63% of it, an hour 86%; two updates over `a` and `b` seconds land where one over
    ///         `a + b` does, to a 65536th of a tick each.
    function emaTick(int256 previous, int24 current, uint256 elapsed) internal pure returns (int256) {
        int256 target = int256(current) << EMA_FRACTION_BITS;
        int256 kept = (previous - target) * int256(emaDecayX128(elapsed));
        return target + ((kept + (1 << 127)) >> 128);
    }

    /// @notice An EMA as a tick, rounded to the nearest.
    function emaToTick(int256 ema) internal pure returns (int24) {
        return int24((ema + int256(1 << (EMA_FRACTION_BITS - 1))) >> EMA_FRACTION_BITS);
    }

    /// @notice e^(-elapsed / 1800) as a Q128 fraction: the share of its distance to the price an EMA with a 30-minute
    ///         time constant keeps after `elapsed` seconds. The product of e^(-2^i / 1800) for each bit of `elapsed`, as
    ///         TickMath multiplies powers of sqrt(1.0001): the shares of two spans multiply to the share of both. From
    ///         2^16 seconds on it is zero, below 1.6e-16: no EMA keeps a 65536th of a tick of any distance.
    function emaDecayX128(uint256 elapsed) internal pure returns (uint256 ratio) {
        if (elapsed >= 1 << 16) return 0;
        ratio = elapsed & 0x1 != 0 ? 0xffdb99e9bd1811128e505b2955619a9b : 1 << 128;
        if (elapsed & 0x2 != 0) ratio = (ratio * 0xffb739005928b2a0b327607406ceae37) >> 128;
        if (elapsed & 0x4 != 0) ratio = (ratio * 0xff6e86b13ccfb3bfc54176e69fd260f8) >> 128;
        if (elapsed & 0x8 != 0) ratio = (ratio * 0xfedd600d1e5410f5199b45970063bd4e) >> 128;
        if (elapsed & 0x10 != 0) ratio = (ratio * 0xfdbc0a0902df0636cad7afdb6d6ba98f) >> 128;
        if (elapsed & 0x20 != 0) ratio = (ratio * 0xfb7d35f48d4dbe640d9b3479cc3e6501) >> 128;
        if (elapsed & 0x40 != 0) ratio = (ratio * 0xf70ec50b49479d63fb6aba2a95d01836) >> 128;
        if (elapsed & 0x80 != 0) ratio = (ratio * 0xee6d8115ec4e94d3bf74c6401b0d9882) >> 128;
        if (elapsed & 0x100 != 0) ratio = (ratio * 0xde0fcadbf12471ac4550f6468e66f021) >> 128;
        if (elapsed & 0x200 != 0) ratio = (ratio * 0xc09f64cedcc14cf0154c87f81ddb6591) >> 128;
        if (elapsed & 0x400 != 0) ratio = (ratio * 0x90ef7a74abca6f24bbbd723ce21dee69) >> 128;
        if (elapsed & 0x800 != 0) ratio = (ratio * 0x520e49c921afe9edee77790929a9ac74) >> 128;
        if (elapsed & 0x1000 != 0) ratio = (ratio * 0x1a4d281100d8b45640e07b6cb6de58f4) >> 128;
        if (elapsed & 0x2000 != 0) ratio = (ratio * 0x2b3c36494abd862d6343f47e9846c85) >> 128;
        if (elapsed & 0x4000 != 0) ratio = (ratio * 0x74d48661cf9b46dcf2325a20d2169) >> 128;
        if (elapsed & 0x8000 != 0) ratio = (ratio * 0x35514a377caf1c1b23a640d778) >> 128;
    }

    /// @notice Tick of the ratio of the two ETH prices, expressed as currency1 per currency0. Both ETH pool ticks
    ///         are tokens per ETH and capped at their common launch tick. The A/D pool price is not an input.
    function ethRatioTick(int24 tickA, int24 tickD, bool aIsCurrency0) internal pure returns (int24) {
        return aIsCurrency0 ? tickD - tickA : tickA - tickD;
    }

    /// @notice Share of currency0 at a price-ratio tick. A ratio of two valid pool prices can exceed one pool's tick
    ///         range; its share is then already 0 or 10000 at basis-point precision.
    function share0BpsAtTick(int24 tick) internal pure returns (uint256) {
        if (tick <= TickMath.MIN_TICK) return 0;
        if (tick >= TickMath.MAX_TICK) return BPS;
        uint256 share = share0Bps(TickMath.getSqrtPriceAtTick(tick));
        // Preserve the oracle's side of 50% at basis-point precision: a positive average of one tick has a winner,
        // even when its fractional share would floor to 5000. Negative ticks already floor below 5000.
        return tick > 0 && share == BPS / 2 ? share + 1 : share;
    }

    /// @notice Share of currency0 in the pair's value, in basis points, for two tokens of equal supply.
    /// @dev The cross pool price P is "currency1 per currency0", so the share of currency0 is P / (1 + P).
    function share0Bps(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        return FullMath.mulDiv(priceX96, BPS, priceX96 + Q96);
    }
}
