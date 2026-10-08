// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";

/// @notice What a transaction costs however busy a duel is, against what Robinhood Chain allows one. Nothing in the
///         hook loops, and what it keeps of a duel has one size: a trade cannot cost more for the trades before it. A
///         pool has one position, the factory's, for good (nobody adds liquidity, nobody removes any): a swap crosses
///         no tick somebody put in its way. These tests hold that by measure: hundreds of trades in one round, some
///         in one second, through the router as the app sends them, then the round's settlement, the largest launch
///         the factory takes, and the lens on the largest duels.
///
///         The chain's limits were read from its own accounts (ArbGasInfo `getGasAccountingParams`, the same on its
///         testnet) on October 5, 2026: 32,000,000 gas a transaction and a block, 7,000,000 a second aimed at. Its
///         public nodes give a read 50,000,000 (a call that answers the gas it was given).
contract DuelGasUnderLoadTest is DuelTestBase {
    /// @dev What Robinhood Chain allows one transaction.
    uint256 internal constant TX_GAS_LIMIT = 32_000_000;
    /// @dev What its nodes allow one read.
    uint256 internal constant READ_GAS_CAP = 50_000_000;
    /// @dev A trade's ceiling here: a thirty-second of a transaction's limit. They cost a quarter of it.
    uint256 internal constant TRADE_GAS = TX_GAS_LIMIT / 32;

    uint256 internal constant NEVER = type(uint256).max;
    uint256 internal constant TRADES = 600;
    uint256 internal constant BUCKET = 100;
    uint256 internal constant BUY = 0;
    uint256 internal constant SELL = 1;
    uint256 internal constant SWITCH = 2;

    address[] internal traders;

    struct Stat {
        uint256 n;
        uint256 sum;
    }

    /// @dev The trades' gas, by kind and by hundred of trades.
    mapping(uint256 kind => mapping(uint256 bucket => Stat)) internal stats;
    uint256 internal highest;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < 6; ++i) {
            address trader = makeAddr(string.concat("trader", vm.toString(i)));
            vm.deal(trader, 1_000_000 ether);
            traders.push(trader);
        }
    }

    function _average(uint256 kind, uint256 bucket) internal view returns (uint256) {
        Stat memory s = stats[kind][bucket];
        assertGt(s.n, 10, "too few trades of a kind in a hundred to compare");
        return s.sum / s.n;
    }

    /// @dev What the lens spends describing a duel, inside the call: a read has no caller to copy its answer.
    function _lensGas(uint256 id) internal returns (uint256) {
        lens.getPair(id);
        return vm.lastCallGas().gasTotalUsed;
    }

    /// @dev One trade through the router, as the app sends it: a buy of a side, a sale of part of what the trader
    ///      holds of it by the sale route, or a switch to the other side. Its kind and its gas.
    function _trade(PairInfo memory info, uint256 seed) internal returns (uint256 kind, uint256 gas) {
        address user = traders[seed % traders.length];
        bool sideA = (seed >> 8) % 2 == 0;
        uint256 pick = (seed >> 16) % 10;
        IERC20 token = IERC20(address(sideA ? info.a : info.d));
        IERC20 otherToken = IERC20(address(sideA ? info.d : info.a));
        uint256 held = token.balanceOf(user);
        if (pick < 5 || held == 0) {
            uint256 eth = 0.001 ether + ((seed >> 32) % 0.3 ether);
            vm.prank(user);
            router.swapExactIn{value: eth}(sideA ? info.keyA : info.keyD, true, eth, 0, user, NEVER);
            return (BUY, vm.lastCallGas().gasTotalUsed);
        }
        uint256 amount = (held * (10 + ((seed >> 32) % 60))) / 100;
        if (pick < 8) {
            vm.prank(user);
            router.sell(sideA ? info.keyA : info.keyD, info.keyX, sideA ? info.keyD : info.keyA, amount, 0, user, NEVER);
            return (SELL, vm.lastCallGas().gasTotalUsed);
        }
        vm.prank(user);
        router.swapExactIn(info.keyX, address(token) < address(otherToken), amount, 0, user, NEVER);
        return (SWITCH, vm.lastCallGas().gasTotalUsed);
    }

    /// @dev Six hundred trades in one round of one duel, two seconds apart but for a hundred of them in one second:
    ///      the sixth hundred costs what the second did, of each kind, those of one second no more, and none a
    ///      thirty-second of what a transaction may use. The lens spends the same on the duel after ten trades and
    ///      after them all. A buy then settles the round, its pot spent on the winner, well within a trade's ceiling.
    function test_underLoad_sixHundredTradesInARound_costWhatTheFirstOnesDid() public {
        PairInfo memory info = _createPair(0, 0, false);
        DuelHook.Pair memory p = hook.getPair(info.id);
        // the test's own clock: past the launch's anti-snipe window, then two seconds a trade
        uint256 clock = uint256(p.launchTime) + 10;
        vm.warp(clock);
        for (uint256 i = 0; i < traders.length; ++i) {
            vm.startPrank(traders[i]);
            info.a.approve(address(router), type(uint256).max);
            info.d.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        uint256 seed = 0xd0e1;
        uint256 lensEarly;
        for (uint256 i = 0; i < TRADES; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            // the fourth hundred all in one second, as a crowd in one block would be
            if (i / BUCKET != 3) vm.warp(clock += 2);
            (uint256 kind, uint256 gas) = _trade(info, seed);
            Stat storage s = stats[kind][i / BUCKET];
            s.n++;
            s.sum += gas;
            if (gas > highest) highest = gas;
            if (i == 9) lensEarly = _lensGas(info.id);
        }
        assertLt(clock, p.roundEnd, "the trades went past the round");

        assertLt(highest, TRADE_GAS, "a trade's gas");
        for (uint256 kind = BUY; kind <= SWITCH; ++kind) {
            uint256 early = _average(kind, 1);
            // 2% either way: the trades differ in size and in the realignment they set off, not in what came before
            assertApproxEqRel(_average(kind, 5), early, 0.02e18, "the sixth hundred against the second");
            assertLt(_average(kind, 3), early, "a hundred trades in one second cost less: nothing accrues between");
        }
        assertApproxEqRel(_lensGas(info.id), lensEarly, 0.01e18, "the lens on a duel, after its trades");

        // a round later, the price at rest all that time: the first trade settles the round and spends its pot
        vm.warp(uint256(p.roundEnd) + hook.ROUND_LENGTH() - 1);
        vm.recordLogs();
        vm.prank(traders[2]);
        router.swapExactIn{value: 0.05 ether}(info.keyD, true, 0.05 ether, 0, traders[2], NEVER);
        uint256 settling = vm.lastCallGas().gasTotalUsed;
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertTrue(s.found);
        assertGt(s.spent, 0, "the settlement bought the winner back");
        assertLt(settling, TRADE_GAS, "a buy that settles a busy round");
    }

    function _text(uint256 length, bytes1 char) internal pure returns (string memory) {
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = char;
        }
        return string(out);
    }

    /// @dev The largest launch the factory takes: the longest names, tickers and metadata, both sides bought.
    function _largest() internal view returns (DuelFactory.CreateParams memory params) {
        params = createParams(0.01 ether, 0.01 ether, false);
        params.nameA = _text(factory.MAX_NAME_BYTES(), "A");
        params.nameD = _text(factory.MAX_NAME_BYTES(), "D");
        params.symbolA = _text(factory.MAX_SYMBOL_BYTES(), "A");
        params.symbolD = _text(factory.MAX_SYMBOL_BYTES(), "D");
        params.metadataURI = _text(factory.MAX_METADATA_BYTES(), "m");
    }

    /// @dev A launch is the heaviest thing anyone sends: two tokens, three pools, and both tokens keep the metadata.
    ///      The largest one takes under a third of what a transaction may use.
    function test_underLoad_theLargestLaunch_fitsInATransaction() public {
        DuelFactory.CreateParams memory params = _largest();
        vm.prank(creator);
        factory.createPair{value: LAUNCH_FEE + 0.02 ether}(params);
        uint256 gas = vm.lastCallGas().gasTotalUsed;
        assertLt(gas, TX_GAS_LIMIT / 3);
        // and it is no small one: the names and the metadata are most of it
        assertGt(gas, 3 * 3_000_000);
    }

    /// @dev The lens describes duels by the page, and a duel with the longest metadata costs it four times a plain
    ///      one. Twenty of the largest fit a read five times over: the page Duel's site and alerts fall back to when
    ///      a node refuses the hundred they ask first, which a hundred of the largest would be (50,493,973 gas,
    ///      measured, of the 50,000,000 a read is given).
    function test_underLoad_twentyOfTheLargestDuels_fitInARead() public {
        DuelFactory.CreateParams memory params = _largest();
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(creator);
            factory.createPair{value: LAUNCH_FEE + 0.02 ether}(params);
        }
        lens.getPairs(0, 20);
        uint256 page = vm.lastCallGas().gasTotalUsed;
        assertLt(page, READ_GAS_CAP / 5);
        // twenty duels cost twenty times one, and a little for the page: nothing a longer page would hide
        assertGt(page, 20 * _lensGas(1));
        assertLt(page, 21 * _lensGas(1));
    }
}
