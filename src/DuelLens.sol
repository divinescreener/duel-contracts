// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {DuelHook} from "./DuelHook.sol";
import {DuelToken} from "./DuelToken.sol";
import {DuelMath} from "./libraries/DuelMath.sol";
import {DuelVersion} from "./libraries/DuelVersion.sol";

/// @title DuelLens
/// @notice Read-only aggregation of a pair's state for the Duel app: prices, reserves, gauge, round and pot.
contract DuelLens {
    using StateLibrary for IPoolManager;

    /// @notice One side of a pair.
    struct SideView {
        address token;
        string name;
        string symbol;
        uint256 totalSupply;
        uint160 sqrtPriceX96; // ETH pool price, tokens per wei
        int24 tick;
        uint256 priceWad; // ETH per token, 18 decimals; the launch price while the pool holds no ETH
        uint256 ethReserve; // real ETH held by the side's ETH pool
    }

    /// @notice Everything the app shows about a pair.
    struct PairView {
        uint256 pairId;
        address creator;
        string metadataURI;
        SideView a;
        SideView d;
        PoolKey keyA;
        PoolKey keyD;
        PoolKey keyX;
        uint256 gaugeBps; // live share of side A
        uint256 roundGaugeBps; // share of side A averaged over the current round so far
        uint256 pot;
        uint256 creatorFees;
        uint256 volume; // ETH traded against the ETH pools since launch
        uint256 buybacks; // ETH spent buying back winners since launch
        uint256 snipeTaxBps;
        uint32 roundIndex;
        uint40 roundStart;
        uint40 roundEnd;
        uint40 launchTime;
        bool roundTraded;
        bool supporter;
        DuelHook.FeeConfig fees;
        int24 startTick; // launch tick of both ETH pools: a side never trades there below its launch price
        uint8 category; // what the duel is about, as the app numbers its categories (0: none)
        uint16 protocolRateBps; // the part of the protocol's fee share it takes, for every pair (DuelHook)
    }

    /// @notice Version of the launchpad this contract is part of (DuelVersion).
    uint256 public constant VERSION = DuelVersion.NUMBER;
    /// @notice Code name of the launchpad's version.
    string public constant CODENAME = DuelVersion.CODENAME;
    /// @notice Hook holding the pairs.
    DuelHook public immutable hook;
    /// @notice Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;

    constructor(DuelHook _hook) {
        hook = _hook;
        poolManager = _hook.poolManager();
    }

    /// @notice State of one pair.
    function getPair(uint256 pairId) public view returns (PairView memory v) {
        DuelHook.Pair memory p = hook.getPair(pairId);
        (v.keyA, v.keyD, v.keyX) = hook.poolKeys(pairId);
        v.pairId = pairId;
        v.creator = p.creator;
        v.metadataURI = DuelToken(p.tokenA).metadataURI();
        v.a = _side(p.tokenA, v.keyA, p.startTick);
        v.d = _side(p.tokenD, v.keyD, p.startTick);
        v.startTick = p.startTick;
        // The side views already read both ETH ticks: use that same snapshot for the live and round gauges.
        int24 ratio = DuelMath.ethRatioTick(
            v.a.tick < p.startTick ? v.a.tick : p.startTick,
            v.d.tick < p.startTick ? v.d.tick : p.startTick,
            p.aIsCurrency0
        );
        uint256 share0 = DuelMath.share0BpsAtTick(ratio);
        v.gaugeBps = p.aIsCurrency0 ? share0 : DuelMath.BPS - share0;
        v.roundGaugeBps = _roundGaugeBps(p, ratio);
        v.pot = p.pot;
        v.creatorFees = p.creatorFees;
        v.volume = p.volume;
        v.buybacks = p.buybacks;
        v.snipeTaxBps = hook.snipeTaxBps(pairId);
        v.roundIndex = p.roundIndex;
        v.roundStart = p.roundStart;
        v.roundEnd = p.roundEnd;
        v.launchTime = p.launchTime;
        v.roundTraded = p.roundTraded;
        v.supporter = p.supporter;
        v.fees = p.fees;
        v.category = p.category;
        v.protocolRateBps = hook.protocolRateBps();
    }

    /// @notice States of up to `limit` pairs, from id `offset + 1` upwards.
    function getPairs(uint256 offset, uint256 limit) external view returns (PairView[] memory views) {
        uint256 count = hook.pairCount();
        if (offset >= count) return views;
        uint256 remaining = count - offset;
        views = new PairView[](limit < remaining ? limit : remaining);
        for (uint256 i = 0; i < views.length; ++i) {
            views[i] = getPair(offset + i + 1);
        }
    }

    function _side(address token, PoolKey memory key, int24 startTick) internal view returns (SideView memory s) {
        s.token = token;
        s.name = IERC20Metadata(token).name();
        s.symbol = IERC20Metadata(token).symbol();
        s.totalSupply = IERC20Metadata(token).totalSupply();
        PoolId id = key.toId();
        (s.sqrtPriceX96, s.tick,,) = poolManager.getSlot0(id);
        uint160 launchPrice = TickMath.getSqrtPriceAtTick(startTick);
        // a pool without ETH trades from its launch price, wherever an oversized sell left its own price
        uint160 sqrtPrice = s.tick < startTick ? s.sqrtPriceX96 : launchPrice;
        s.priceWad = FullMath.mulDiv(FullMath.mulDiv(DuelMath.Q96, DuelMath.WAD, sqrtPrice), DuelMath.Q96, sqrtPrice);
        if (s.tick < startTick) {
            s.ethReserve =
                SqrtPriceMath.getAmount0Delta(s.sqrtPriceX96, launchPrice, poolManager.getLiquidity(id), false);
        }
    }

    /// @dev Average share of side A since the start of the round, from the hook's tick accumulator and the ratio of
    ///      the two ETH price ticks since its last accrual. A round past its close that
    ///      nobody settled yet is averaged up to its close, as its settlement will be.
    function _roundGaugeBps(DuelHook.Pair memory p, int24 ratio) internal view returns (uint256) {
        int256 averageTick = ratio;
        uint256 to = block.timestamp < p.roundEnd ? block.timestamp : p.roundEnd;
        uint256 elapsed = to - p.roundStart;
        if (elapsed > 0) {
            int256 cumulative = int256(p.tickCumulative) + int256(ratio) * int256(to - p.lastAccrual);
            averageTick = (cumulative - int256(p.roundStartCumulative)) / int256(elapsed);
        }
        uint256 share0 = DuelMath.share0BpsAtTick(int24(averageTick));
        return p.aIsCurrency0 ? share0 : DuelMath.BPS - share0;
    }
}
