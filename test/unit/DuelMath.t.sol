// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {DuelMath} from "../../src/libraries/DuelMath.sol";

/// @dev Exposes the library's internal functions.
contract DuelMathHarness {
    function startPrice(uint256 supply, uint256 fdv, int24 spacing) external pure returns (uint160, int24) {
        return DuelMath.startPrice(supply, fdv, spacing);
    }

    function liquidityForAmount1(uint160 a, uint160 b, uint256 amount1) external pure returns (uint128) {
        return DuelMath.liquidityForAmount1(a, b, amount1);
    }

    function liquidityForAmounts(uint160 p, uint160 a, uint160 b, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return DuelMath.liquidityForAmounts(p, a, b, amount0, amount1);
    }

    function virtualReserves(uint128 liquidity, uint160 sqrtPrice) external pure returns (uint256, uint256) {
        return DuelMath.virtualReserves(liquidity, sqrtPrice);
    }

    function optimalCycleInput(
        uint256 ri1,
        uint256 ro1,
        uint256 ri2,
        uint256 ro2,
        uint256 ri3,
        uint256 ro3,
        uint256 threshold
    ) external pure returns (uint256) {
        return DuelMath.optimalCycleInput(ri1, ro1, ri2, ro2, ri3, ro3, threshold);
    }

    function capCycleInput(uint256 input, uint256 ri1, uint256 ro1, uint256 ri2, uint256 ro2, uint256 maxSell)
        external
        pure
        returns (uint256)
    {
        return DuelMath.capCycleInput(input, ri1, ro1, ri2, ro2, maxSell);
    }

    function snipeTaxBps(uint256 startBps, uint256 window, uint256 elapsed) external pure returns (uint256) {
        return DuelMath.snipeTaxBps(startBps, window, elapsed);
    }

    function emaTick(int256 previous, int24 current, uint256 elapsed) external pure returns (int256) {
        return DuelMath.emaTick(previous, current, elapsed);
    }

    function emaToTick(int256 ema) external pure returns (int24) {
        return DuelMath.emaToTick(ema);
    }

    function emaDecayX128(uint256 elapsed) external pure returns (uint256) {
        return DuelMath.emaDecayX128(elapsed);
    }

    function ethRatioTick(int24 tickA, int24 tickD, bool aIsCurrency0) external pure returns (int24) {
        return DuelMath.ethRatioTick(tickA, tickD, aIsCurrency0);
    }

    function share0Bps(uint160 sqrtPrice) external pure returns (uint256) {
        return DuelMath.share0Bps(sqrtPrice);
    }
}

contract DuelMathTest is Test {
    DuelMathHarness internal math;
    uint256 internal constant Q96 = 1 << 96;

    function setUp() public {
        math = new DuelMathHarness();
    }

    function test_startPrice_roundsDownToTheSpacing() public view {
        (uint160 sqrtPrice, int24 tick) = math.startPrice(1_000_000_000 ether, 1.68 ether, 200);
        assertGt(tick, 0);
        assertEq(tick % 200, 0);
        assertEq(sqrtPrice, TickMath.getSqrtPriceAtTick(tick));
        uint256 priceX96 = FullMath.mulDiv(sqrtPrice, sqrtPrice, Q96);
        assertApproxEqRel(priceX96, FullMath.mulDiv(1_000_000_000 ether, Q96, 1.68 ether), 0.021e18);
    }

    function testFuzz_startPrice_staysBelowTheRequestedPriceAcrossAllowedFdvs(uint96 fdv) public view {
        fdv = uint96(bound(fdv, 0.1 ether, 1000 ether));
        (uint160 sqrtPrice, int24 tick) = math.startPrice(1_000_000_000 ether, fdv, 200);
        uint256 requested = FullMath.mulDiv(1_000_000_000 ether, Q96, fdv);
        uint256 rounded = FullMath.mulDiv(sqrtPrice, sqrtPrice, Q96);
        uint160 next = TickMath.getSqrtPriceAtTick(tick + 200);
        assertGt(tick, 0);
        assertEq(tick % 200, 0);
        assertLe(rounded, requested);
        assertGt(FullMath.mulDiv(next, next, Q96), requested);
    }

    function test_liquidityForAmount1_holdsTheAmount() public view {
        uint160 a = TickMath.getSqrtPriceAtTick(-887_200);
        uint160 b = TickMath.getSqrtPriceAtTick(202_000);
        uint128 liquidity = math.liquidityForAmount1(a, b, 900_000_000 ether);
        assertApproxEqRel(FullMath.mulDiv(liquidity, b - a, Q96), 900_000_000 ether, 1e9);
        // over a range whose lower price is not next to nothing too
        a = TickMath.getSqrtPriceAtTick(100_000);
        liquidity = math.liquidityForAmount1(a, b, 900_000_000 ether);
        assertApproxEqRel(FullMath.mulDiv(liquidity, b - a, Q96), 900_000_000 ether, 1e9);
    }

    function test_liquidityForAmounts_isLimitedByTheScarcerSide() public view {
        uint160 a = TickMath.getSqrtPriceAtTick(-887_220);
        uint160 b = TickMath.getSqrtPriceAtTick(887_220);
        uint128 balanced = math.liquidityForAmounts(uint160(Q96), a, b, 1e26, 1e26);
        uint128 less0 = math.liquidityForAmounts(uint160(Q96), a, b, 5e25, 1e26);
        uint128 less1 = math.liquidityForAmounts(uint160(Q96), a, b, 1e26, 5e25);
        assertApproxEqRel(balanced, 1e26, 1e12);
        assertApproxEqRel(less0, 5e25, 1e12);
        assertApproxEqRel(less1, 5e25, 1e12);
    }

    function test_virtualReserves_multiplyToLiquiditySquared() public view {
        uint128 liquidity = 3.7e22;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(150_000);
        (uint256 r0, uint256 r1) = math.virtualReserves(liquidity, sqrtPrice);
        assertApproxEqRel(FullMath.mulDiv(r0, r1, liquidity), liquidity, 1e9);
    }

    function test_optimalCycleInput_ignoresSmallEdges() public view {
        // a 0.05% edge is below the 10 bps threshold
        assertEq(math.optimalCycleInput(1e18, 1e18, 1e18, 1e18, 1e18, 1.0005e18, 10), 0);
        // no edge at all
        assertEq(math.optimalCycleInput(2e18, 1e18, 1e18, 1e18, 1e18, 2e18, 10), 0);
    }

    function test_optimalCycleInput_maximisesProfit() public view {
        uint256[6] memory r = [uint256(5e18), 3e27, 1e26, 1.3e26, 2.6e27, 6e18];
        uint256 best = math.optimalCycleInput(r[0], r[1], r[2], r[3], r[4], r[5], 10);
        assertGt(best, 0);
        int256 atBest = _profit(r, best);
        assertGt(atBest, 0);
        assertGe(atBest, _profit(r, (best * 99) / 100));
        assertGe(atBest, _profit(r, (best * 101) / 100));
    }

    function _profit(uint256[6] memory r, uint256 input) internal pure returns (int256) {
        uint256 out1 = r[1] * input / (r[0] + input);
        uint256 out2 = r[3] * out1 / (r[2] + out1);
        uint256 out3 = r[5] * out2 / (r[4] + out2);
        return int256(out3) - int256(input);
    }

    function test_capCycleInput_keepsOrLowersTheInput() public view {
        uint256[6] memory r = [uint256(5e18), 3e27, 1e26, 1.3e26, 2.6e27, 6e18];
        uint256 best = math.optimalCycleInput(r[0], r[1], r[2], r[3], r[4], r[5], 10);
        uint256 out1 = r[1] * best / (r[0] + best);
        uint256 sold = r[3] * out1 / (r[2] + out1);
        // room to sell it all: the input stays
        assertEq(math.capCycleInput(best, r[0], r[1], r[2], r[3], sold), best);
        // room for half of it: a smaller cycle that sells no more, and still pays
        uint256 capped = math.capCycleInput(best, r[0], r[1], r[2], r[3], sold / 2);
        assertLt(capped, best);
        out1 = r[1] * capped / (r[0] + capped);
        assertApproxEqRel(r[3] * out1 / (r[2] + out1), sold / 2, 1e9);
        assertLe(r[3] * out1 / (r[2] + out1), sold / 2);
        assertGt(_profit(r, capped), 0);
    }

    function testFuzz_capCycleInput_neverExceedsEitherLimit(
        uint128 input,
        uint128 ri1,
        uint128 ro1,
        uint128 ri2,
        uint128 ro2,
        uint128 maxSell
    ) public view {
        input = uint128(bound(input, 1, 20 ether));
        ri1 = uint128(bound(ri1, 0.01 ether, 1000 ether));
        ro1 = uint128(bound(ro1, 1 ether, 1_000_000_000 ether));
        ri2 = uint128(bound(ri2, 1 ether, 1_000_000_000 ether));
        ro2 = uint128(bound(ro2, 1 ether, 1_000_000_000 ether));
        maxSell = uint128(bound(maxSell, 0, ro2));
        uint256 capped = math.capCycleInput(input, ri1, ro1, ri2, ro2, maxSell);
        assertLe(capped, input);
        uint256 first = FullMath.mulDiv(ro1, capped, uint256(ri1) + capped);
        uint256 sold = FullMath.mulDiv(ro2, first, uint256(ri2) + first);
        assertLe(sold, maxSell);
    }

    function test_snipeTaxBps_curve() public view {
        assertEq(math.snipeTaxBps(9800, 10, 0), 9800);
        assertEq(math.snipeTaxBps(9800, 10, 1), 4900);
        assertEq(math.snipeTaxBps(9800, 10, 5), 76);
        assertEq(math.snipeTaxBps(9800, 10, 10), 0);
        assertEq(math.snipeTaxBps(9800, 10, 1000), 0);
        assertEq(math.snipeTaxBps(9800, 0, 0), 0);
    }

    int256 internal constant ONE = 65_536;

    function test_emaTick_closesItsDistanceExponentially() public view {
        // a 30-minute time constant: 1 - e^-1 of the distance in 30 minutes, 1 - e^-0.5 in 15, 1 - e^-2 in an hour
        assertEq(math.emaToTick(math.emaTick(1000 * ONE, 2000, 1800)), 1632);
        assertEq(math.emaToTick(math.emaTick(1000 * ONE, 2000, 900)), 1393);
        assertEq(math.emaToTick(math.emaTick(1000 * ONE, -1000, 3600)), -729);
        assertEq(math.emaTick(1000 * ONE, 1000, 10), 1000 * ONE);
        assertEq(math.emaTick(1000 * ONE, 2000, 0), 1000 * ONE);
        // past 2^16 seconds nothing of the distance is kept, from anywhere to anywhere
        assertEq(math.emaTick(887_272 * ONE, -887_272, 1 << 16), -887_272 * ONE);
        assertEq(math.emaTick(-887_272 * ONE, 887_272, 1 << 20), 887_272 * ONE);
    }

    function test_emaTick_losesNoMoveToRounding() public view {
        // one tick away, one second: 65536 * (1 - e^(-1/1800)) = 36.4 sixty-five-thousandths, where a whole-tick EMA
        // moved by nothing, however long the prices held one tick apart one second at a time
        assertEq(math.emaTick(0, 1, 1), 36);
        assertEq(math.emaTick(0, -1, 1), -36);
        int256 ema;
        for (uint256 i = 0; i < 1800; ++i) {
            ema = math.emaTick(ema, 1000, 1);
        }
        // 1800 updates of a second land within a tick of one update of 1800 seconds: 1000 * (1 - e^-1)
        assertApproxEqAbs(ema, math.emaTick(0, 1000, 1800), 1800 / 2);
        assertEq(math.emaToTick(ema), 632);
    }

    function testFuzz_emaTick_twoSpansAreOne(int24 previous, int24 current, uint16 a, uint16 b) public view {
        previous = int24(bound(previous, -887_272, 887_272));
        current = int24(bound(current, -887_272, 887_272));
        int256 first = math.emaTick(int256(previous) * ONE, current, a);
        int256 twice = math.emaTick(first, current, b);
        int256 once = math.emaTick(int256(previous) * ONE, current, uint256(a) + b);
        // a 65536th of a tick of rounding per update
        assertApproxEqAbs(twice, once, 2);
        // and never past either end of the distance it closes
        (int256 low, int256 high) = previous < current
            ? (int256(previous) * ONE, int256(current) * ONE)
            : (int256(current) * ONE, int256(previous) * ONE);
        assertGe(twice, low);
        assertLe(twice, high);
    }

    function test_emaDecay_isTheExponentialOfItsTimeConstant() public view {
        assertEq(math.emaDecayX128(0), 1 << 128);
        // e^-1 and e^-2, to 1e-30 of their value
        assertApproxEqRel(math.emaDecayX128(1800), 0x5e2d58d8b3bcdf1abadec7829054f90e, 1);
        assertApproxEqRel(math.emaDecayX128(3600), 0x22a555477f03973fb6edd5c25a052ae4, 1);
        assertEq(math.emaDecayX128((1 << 16) - 1) < 1 << 76, true);
        assertEq(math.emaDecayX128(1 << 16), 0);
        assertEq(math.emaDecayX128(type(uint256).max), 0);
    }

    function testFuzz_emaDecay_twoSpansMultiplyToBoth(uint16 a, uint16 b) public view {
        uint256 both = math.emaDecayX128(uint256(a) + b);
        uint256 product = FullMath.mulDiv(math.emaDecayX128(a), math.emaDecayX128(b), 1 << 128);
        if (uint256(a) + b >= 1 << 16) {
            // past the cutoff the product is not zero, but it keeps no 65536th of a tick of the widest distance
            assertEq(both, 0);
            assertLt(product * 2 * 887_272 * 65_536, 1 << 127);
            return;
        }
        // within 2^-110 of one, relative: the constants' last bits
        assertApproxEqAbs(product, both, (both >> 110) + 64);
    }

    function test_ethRatioTick_usesOnlyTheEthPricesInBothCurrencyOrders() public view {
        assertEq(math.ethRatioTick(1000, 1200, true), 200);
        assertEq(math.ethRatioTick(1000, 1200, false), -200);
        assertEq(math.ethRatioTick(1200, 1000, true), -200);
        assertEq(math.ethRatioTick(1000, 1000, false), 0);
        assertEq(math.ethRatioTick(-887_272, 887_272, true), 887_272 * 2);
    }

    function test_share0BpsAtTick_supportsRatiosBeyondOnePoolsRange() public pure {
        assertEq(DuelMath.share0BpsAtTick(0), 5000);
        assertEq(DuelMath.share0BpsAtTick(1), 5001);
        assertEq(DuelMath.share0BpsAtTick(-1), 4999);
        assertEq(DuelMath.share0BpsAtTick(887_273), 10_000);
        assertEq(DuelMath.share0BpsAtTick(-887_273), 0);
        assertEq(DuelMath.share0BpsAtTick(1_774_544), 10_000);
        assertEq(DuelMath.share0BpsAtTick(-1_774_544), 0);
    }

    function test_share0Bps_readsTheCrossPrice() public view {
        assertEq(math.share0Bps(uint160(Q96)), 5000);
        assertEq(math.share0Bps(uint160(2 * Q96)), 8000);
        assertEq(math.share0Bps(uint160(Q96 / 2)), 2000);
    }
}
