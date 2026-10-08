// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelSimulator} from "../../src/DuelSimulator.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @dev A recipient that, paid its ETH in the middle of a sale, tries to sell again and to claim a creator's fees,
///      and takes the sale's payment whatever those attempts answer.
contract GreedyRecipient {
    DuelRouter internal immutable router;
    DuelHook internal immutable hook;
    PoolKey internal keyIn;
    PoolKey internal keyCross;
    PoolKey internal keyOther;
    uint256 internal pairId;
    uint256 public payments;
    uint256 public attempts;
    uint256 public refused;

    constructor(DuelRouter _router, DuelHook _hook) {
        router = _router;
        hook = _hook;
    }

    function arm(PoolKey memory _keyIn, PoolKey memory _keyCross, PoolKey memory _keyOther, uint256 _pairId) external {
        (keyIn, keyCross, keyOther, pairId) = (_keyIn, _keyCross, _keyOther, _pairId);
        DuelToken(Currency.unwrap(_keyIn.currency1)).approve(address(router), type(uint256).max);
    }

    receive() external payable {
        ++payments;
        uint256 held = DuelToken(Currency.unwrap(keyIn.currency1)).balanceOf(address(this));
        ++attempts;
        try router.sell(keyIn, keyCross, keyOther, held, 0, address(this), type(uint256).max) {}
        catch {
            ++refused;
        }
        ++attempts;
        try hook.claimCreatorFees(pairId) {}
        catch {
            ++refused;
        }
    }
}

/// @dev A recipient that refuses ETH.
contract DeafRecipient {}

/// @notice The sale that ends through the other side (DuelRouter.sell, sellWithPermit), in states nobody chose: random
///         hostile histories of a duel (buys, sales, switches both ways, pools parked past their launch price by a
///         swap's own price limit, rounds closing in between), then what the route owes whoever calls it. It takes
///         every token asked, never gives less ETH than the side's own pool alone, answers what its quote said, keeps
///         nothing, lets every holder out, and only ever spends its caller's tokens.
contract DuelSaleRouteTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant NEVER = type(uint256).max;

    PairInfo internal info;
    int24 internal startTick;
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address[4] internal holders;
    /// @dev How many steps of a history did something, and how many of them were sales through the other side.
    uint256 internal acted;
    uint256 internal sales;

    function setUp() public override {
        super.setUp();
        info = _createPair(0, 0, false);
        startTick = hook.getPair(info.id).startTick;
        holders = [alice, bob, carol, dave];
        for (uint256 i; i < holders.length; ++i) {
            vm.deal(holders[i], 1000 ether);
            vm.startPrank(holders[i]);
            info.a.approve(address(router), type(uint256).max);
            info.d.approve(address(router), type(uint256).max);
            info.a.approve(address(swapRouter), type(uint256).max);
            info.d.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------
    // The histories
    // ------------------------------------------------------------------

    function _side(bool isA) internal view returns (PoolKey memory own, PoolKey memory other, DuelToken token) {
        return isA ? (info.keyA, info.keyD, info.a) : (info.keyD, info.keyA, info.d);
    }

    /// @dev A sale through the other side, which must go whatever the state: every token asked taken, the ETH it
    ///      answers paid, nothing kept.
    function _sale(address who, bool isA, uint256 amount) internal returns (uint256 out, uint256 back) {
        (PoolKey memory own, PoolKey memory other, DuelToken token) = _side(isA);
        DuelToken otherToken = isA ? info.d : info.a;
        uint256 held = token.balanceOf(who);
        uint256 heldOther = otherToken.balanceOf(who);
        uint256 eth = who.balance;
        vm.prank(who);
        out = router.sell(own, info.keyX, other, amount, 0, who, NEVER);
        assertEq(held - token.balanceOf(who), amount, "the sale left tokens it was asked to sell");
        assertEq(who.balance - eth, out, "the ETH paid is not the ETH answered");
        back = otherToken.balanceOf(who) - heldOther;
        _assertNothingLeftBehind();
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(address(router).balance, 0, "ETH left in the router");
        assertEq(info.a.balanceOf(address(router)), 0, "A left in the router");
        assertEq(info.d.balanceOf(address(router)), 0, "D left in the router");
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + p.pot + p.creatorFees, "the hook's books");
    }

    /// @dev Whether an ETH pool has no ETH left: its price at or past its launch price.
    function _soldOut(PoolKey memory key) internal view returns (bool) {
        return _tick(key) >= startTick;
    }

    /// @dev `steps` moves of a hostile history, drawn from `seed`: small buys of both sides, then whole exits into a
    ///      side's own pool, which sell it out and leave the holders after them with tokens it cannot buy back, among
    ///      switches both ways, pools parked, sales through the other side and rounds closing. Every sale through the
    ///      other side in it must go; the other moves may be refused by the pools (a switch through ETH out of a pool
    ///      without any, a price limit already passed), which is their own business.
    function _stir(uint256 seed, uint256 steps) internal {
        // some histories start inside the anti-snipe window
        vm.warp(vm.getBlockTimestamp() + seed % 15);
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = holders[r % holders.length];
            bool isA = (r >> 8) & 1 == 0;
            uint256 action = (r >> 16) % 12;
            uint256 size = r >> 32;
            (PoolKey memory own, PoolKey memory other, DuelToken token) = _side(isA);
            uint256 held = token.balanceOf(who);
            // the first moves are buys: there is something to sell
            if (i < 3 || action < 3 || (held == 0 && action < 11)) {
                // against a pool that opens at 1.68 ETH for its whole supply: small, and now and then large
                uint256 eth = _bound(size, 0.0001 ether, (r >> 24) % 8 == 0 ? 20 ether : 0.5 ether);
                vm.prank(who);
                try router.swapExactIn{value: eth}(own, true, eth, 0, who, NEVER) {
                    ++acted;
                } catch {}
            } else if (action < 6) {
                // a whole exit into the side's own pool alone, as far as it pays
                vm.prank(who);
                try router.swapExactIn(own, false, held, 0, who, NEVER) {
                    ++acted;
                } catch {}
            } else if (action == 6) {
                // a switch through the pool between the sides
                bool zeroForOne = info.keyX.currency0 == own.currency1;
                vm.prank(who);
                try router.swapExactIn(info.keyX, zeroForOne, _bound(size, 1, held), 0, who, NEVER) {
                    ++acted;
                } catch {}
            } else if (action == 7) {
                // a switch through ETH
                vm.prank(who);
                try router.swapThroughEth(own, other, _bound(size, 1, held), 0, who, NEVER) {
                    ++acted;
                } catch {}
            } else if (action == 8) {
                // a sale that stops at a price limit of its own, past the pool's launch price: the pool is left
                // parked in the void above its liquidity, neither in its range nor at the far limit
                int24 parked = startTick + int24(int256(_bound(size, 1, 3000))) * 200;
                vm.prank(who);
                try swapRouter.swap(
                    own,
                    IPoolManager.SwapParams({
                        zeroForOne: false,
                        amountSpecified: -int256(held),
                        sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(parked)
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                ) {
                    ++acted;
                } catch {}
            } else if (action < 11) {
                // a sale through the other side, of a part or of everything: it must go
                _sale(who, isA, size % 3 == 0 ? held : _bound(size, 1, held));
                ++acted;
                ++sales;
            } else {
                // time passes: seconds, or past the round's close
                vm.warp(vm.getBlockTimestamp() + _bound(size, 1, 5 hours));
                ++acted;
            }
        }
    }

    /// @dev A run on the duel, drawn from `seed`: a few buys of both sides, of any size, a switch or two, time passing
    ///      or not, then every holder but the last ones leaves into its side's own pool, in any order. The first out
    ///      take the ETH; the last hold tokens their pool cannot buy back, which is what `sell` is for.
    function _run(uint256 seed) internal {
        vm.warp(vm.getBlockTimestamp() + seed % 15);
        uint256 buys = 2 + (seed >> 4) % 6;
        for (uint256 i; i < buys; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "buy", i)));
            address who = holders[r % holders.length];
            (PoolKey memory own,,) = _side((r >> 8) & 1 == 0);
            // from a thousandth of an ETH to a few, as likely small as large
            uint256 eth = 0.001 ether * 2 ** ((r >> 16) % 13) + (r >> 32) % 0.001 ether;
            vm.prank(who);
            router.swapExactIn{value: eth}(own, true, eth, 0, who, NEVER);
            ++acted;
        }
        for (uint256 i; i < (seed >> 8) % 3; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "switch", i)));
            address who = holders[r % holders.length];
            (PoolKey memory own, PoolKey memory other, DuelToken token) = _side((r >> 8) & 1 == 0);
            uint256 held = token.balanceOf(who);
            if (held == 0) continue;
            vm.prank(who);
            if ((r >> 9) & 1 == 0) {
                bool zeroForOne = info.keyX.currency0 == own.currency1;
                try router.swapExactIn(info.keyX, zeroForOne, _bound(r >> 16, 1, held), 0, who, NEVER) {} catch {}
            } else {
                try router.swapThroughEth(own, other, _bound(r >> 16, 1, held), 0, who, NEVER) {} catch {}
            }
        }
        if ((seed >> 12) & 1 == 0) vm.warp(vm.getBlockTimestamp() + _bound(seed >> 16, 1, 9 hours));

        // who leaves, in which order: all but the last one or two
        uint256 keep = 1 + (seed >> 13) % 2;
        uint256 n = 2 * holders.length;
        uint256 start = uint256(keccak256(abi.encode(seed, "order"))) % n;
        uint256 step = [uint256(1), 3, 5, 7][(seed >> 14) % 4];
        for (uint256 i; i + keep < n; ++i) {
            uint256 at = (start + i * step) % n;
            address who = holders[at / 2];
            (PoolKey memory own,, DuelToken token) = _side(at % 2 == 0);
            uint256 held = token.balanceOf(who);
            if (held == 0) continue;
            vm.prank(who);
            router.swapExactIn(own, false, held, 0, who, NEVER);
            ++acted;
        }
    }

    /// @dev A state to sell in: a run on the duel, or a random history.
    function _state(uint256 seed) internal {
        if (seed & 1 == 0) _run(seed >> 1);
        else _stir(seed >> 1, 12);
    }

    /// @dev A holder and a side it holds, from `pick` on; alice buys some of A if nobody holds anything.
    function _holder(uint256 pick) internal returns (address who, bool isA, uint256 held) {
        pick %= 2 * holders.length;
        for (uint256 i; i < 2 * holders.length; ++i) {
            uint256 at = (pick + i) % (2 * holders.length);
            who = holders[at / 2];
            isA = at % 2 == 0;
            held = (isA ? info.a : info.d).balanceOf(who);
            if (held != 0) return (who, isA, held);
        }
        vm.prank(alice);
        held = router.swapExactIn{value: 0.05 ether}(info.keyA, true, 0.05 ether, 0, alice, NEVER);
        return (alice, true, held);
    }

    // ------------------------------------------------------------------
    // What the route owes its caller, in any state
    // ------------------------------------------------------------------

    function testFuzz_sale_inAnyState_takesEveryTokenAsked(uint256 seed, uint256 pick, uint256 share) public {
        _state(seed);
        (address who, bool isA, uint256 held) = _holder(pick);
        _sale(who, isA, bound(share, 1, held));
        assertGt(acted, 0);
    }

    function testFuzz_sale_inAnyState_neverGivesLessThanItsOwnPoolAlone(uint256 seed, uint256 pick, uint256 share)
        public
    {
        _state(seed);
        (address who, bool isA, uint256 held) = _holder(pick);
        uint256 amount = bound(share, 1, held);
        (PoolKey memory own,, DuelToken token) = _side(isA);

        uint256 snapshot = vm.snapshotState();
        vm.prank(who);
        uint256 alone = router.swapExactIn(own, false, amount, 0, who, NEVER);
        uint256 soldAlone = held - token.balanceOf(who);
        vm.revertToState(snapshot);

        (uint256 out,) = _sale(who, isA, amount);
        assertGe(out, alone, "less ETH than the side's own pool alone gives");
        assertLe(soldAlone, amount);
    }

    function testFuzz_sale_inAnyState_theQuoteIsTheSale(uint256 seed, uint256 pick, uint256 share) public {
        _state(seed);
        (address who, bool isA, uint256 held) = _holder(pick);
        uint256 amount = bound(share, 1, held);
        (PoolKey memory own, PoolKey memory other,) = _side(isA);

        // the quote, as the app asks for it: the simulator's code on the trader's own address, for one call
        uint256 snapshot = vm.snapshotState();
        vm.etch(who, type(DuelSimulator).runtimeCode);
        (uint256 quoted, uint256 gauge, uint256 paid, uint256 quotedBack) =
            DuelSimulator(payable(who)).simulateSale(router, hook, info.id, own, info.keyX, other, amount);
        vm.revertToState(snapshot);

        (uint256 out, uint256 back) = _sale(who, isA, amount);
        assertEq(out, quoted, "the sale's ETH is not its quote's");
        assertEq(back, quotedBack, "the other side's tokens paid back are not the quote's");
        assertEq(paid, amount);
        assertEq(hook.gaugeBps(info.id), gauge);
    }

    function testFuzz_sale_ofDust_goesAndKeepsNothing(uint256 seed, uint256 pick, uint256 dust) public {
        _state(seed);
        (address who, bool isA, uint256 held) = _holder(pick);
        _sale(who, isA, bound(dust, 1, held < 1e6 ? held : 1e6));
    }

    /// @dev Every holder leaves, sale after sale, until nobody holds a token or neither ETH pool has ETH left to pay
    ///      for one: no state strands a holder beside ETH the route could reach.
    function testFuzz_sale_everyHolderGetsOut(uint256 seed) public {
        _state(seed);
        for (uint256 round; round < 12; ++round) {
            bool anyone;
            for (uint256 i; i < holders.length; ++i) {
                for (uint256 side; side < 2; ++side) {
                    uint256 held = (side == 0 ? info.a : info.d).balanceOf(holders[i]);
                    if (held == 0) continue;
                    anyone = true;
                    _sale(holders[i], side == 0, held);
                }
            }
            if (!anyone || (_soldOut(info.keyA) && _soldOut(info.keyD))) break;
        }
        bool empty = _soldOut(info.keyA) && _soldOut(info.keyD);
        for (uint256 i; i < holders.length; ++i) {
            if (empty) break;
            assertEq(info.a.balanceOf(holders[i]), 0, "a holder of A is left beside ETH a sale could reach");
            assertEq(info.d.balanceOf(holders[i]), 0, "a holder of D is left beside ETH a sale could reach");
        }
    }

    function testFuzz_sale_inAnyState_aWholeExitStaysWithinItsGas(uint256 seed, uint256 pick) public {
        _state(seed);
        (address who, bool isA, uint256 held) = _holder(pick);
        (PoolKey memory own, PoolKey memory other,) = _side(isA);
        vm.prank(who);
        uint256 gasBefore = gasleft();
        router.sell(own, info.keyX, other, held, 0, who, NEVER);
        // at most eight passes into each ETH pool and one swap between them, each with its realignment
        assertLt(gasBefore - gasleft(), 4_000_000);
    }

    // ------------------------------------------------------------------
    // Pools parked, rounds closing
    // ------------------------------------------------------------------

    /// @dev Parks A's pool at `parked`, past its launch price: carol sells into it tokens enough to take all its ETH,
    ///      with a price limit of her own.
    function _park(int24 parked) internal {
        deal(address(info.a), carol, 100_000_000 ether);
        vm.prank(carol);
        swapRouter.swap(
            info.keyA,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(100_000_000 ether),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(parked)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev A sale may stop at a price limit of its own past the pool's launch price, and leave the pool parked in the
    ///      void above its liquidity. While the other side's pool holds ETH, the realignment after that very sale buys
    ///      the pool back into its range: the price does not stay there.
    function test_sale_aPoolParkedPastItsLaunchPrice_isBoughtBackAtOnce_whileTheOtherSideHoldsEth() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        uint256 heldA = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        vm.prank(bob);
        router.swapExactIn{value: 1 ether}(info.keyD, true, 1 ether, 0, bob, NEVER);

        int24 parked = startTick + 4000;
        vm.recordLogs();
        _park(parked);
        assertEq(_count(vm.getRecordedLogs(), ARBITRAGE_CAPTURED), 1);
        assertFalse(_soldOut(info.keyA));
        assertLt(_sqrtPrice(info.keyA), TickMath.getSqrtPriceAtTick(startTick));

        // and a holder still leaves whole
        (uint256 out,) = _sale(alice, true, heldA);
        assertGt(out, 0);
        assertEq(info.a.balanceOf(alice), 0);
    }

    /// @dev With no ETH on either side nothing buys a parked pool back: it stays there. No sale reverts for it, and
    ///      a buy finds it trading from its launch price.
    function test_sale_aPoolParkedPastItsLaunchPrice_isNoTrap_whenNeitherSideHoldsEth() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        int24 parked = startTick + 4000;
        _park(parked);
        // neither in its range nor at the far limit, where a sale that ran out of ETH would have left it
        assertEq(_sqrtPrice(info.keyA), TickMath.getSqrtPriceAtTick(parked));
        assertTrue(_soldOut(info.keyA));
        assertEq(hook.gaugeBps(info.id), 5000);
        uint256 held = info.a.balanceOf(carol);
        assertGt(held, 0);

        // a sale into that pool alone takes nothing, and does not revert
        uint256 snapshot = vm.snapshotState();
        vm.prank(carol);
        assertEq(router.swapExactIn(info.keyA, false, held, 0, carol, NEVER), 0);
        assertEq(info.a.balanceOf(carol), held);
        assertEq(_sqrtPrice(info.keyA), TickMath.MAX_SQRT_PRICE - 1);
        vm.revertToState(snapshot);

        // and the app's quote of it answers that nothing sells, rather than failing
        vm.etch(carol, type(DuelSimulator).runtimeCode);
        (uint256 quoted,, uint256 taken) =
            DuelSimulator(payable(carol)).simulate(router, hook, info.id, info.keyA, false, held);
        assertEq(quoted, 0);
        assertEq(taken, 0);
        vm.revertToState(snapshot);

        // the sale through the other side finds no ETH there either: the other side's tokens come back, less the
        // switch fee
        (uint256 out, uint256 back) = _sale(carol, true, held);
        assertEq(out, 0);
        assertGt(back, 0);
        assertEq(info.a.balanceOf(carol), 0);

        // a buy finds the pool trading from its launch price
        vm.prank(dave);
        assertGt(router.swapExactIn{value: 0.1 ether}(info.keyA, true, 0.1 ether, 0, dave, NEVER), 0);
        assertLt(_tick(info.keyA), startTick);
        _assertNothingLeftBehind();
    }

    /// @dev D led the round and its holders sold it out before the close: the first trade after it is a sale of D that
    ///      finds D's pool without ETH, skips it, and settles the round on its way through the pool between the sides.
    ///      The buyback then puts the pot's ETH into D's pool, behind the sale. The sale still goes and the books hold;
    ///      settling first is worth more to the seller, by what the buyback paid for.
    function test_sale_thatSettlesTheRoundOnItsWay_goes_andSettlingFirstPaysMore() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        router.swapExactIn{value: 0.05 ether}(info.keyA, true, 0.05 ether, 0, alice, NEVER);
        vm.prank(alice);
        uint256 heldD = router.swapExactIn{value: 2 ether}(info.keyD, true, 2 ether, 0, alice, NEVER);
        // D leads all round; in its last minute its pool is sold out, alice keeping what it could not buy back
        _warpToRoundEnd(info.id);
        vm.warp(vm.getBlockTimestamp() - 60);
        vm.startPrank(alice);
        router.swapExactIn(info.keyA, false, info.a.balanceOf(alice), 0, alice, NEVER);
        router.swapExactIn(info.keyD, false, heldD, 0, alice, NEVER);
        vm.stopPrank();
        uint256 residue = info.d.balanceOf(alice);
        assertGt(residue, 0);
        assertEq(_sqrtPrice(info.keyD), TickMath.MAX_SQRT_PRICE - 1);
        uint256 pot = hook.getPair(info.id).pot;
        assertGt(pot, 0);
        _warpToRoundEnd(info.id);
        vm.warp(vm.getBlockTimestamp() + 1);

        // the sale settles the round itself: D won, the pot bought it back, and the sale went through A's pool
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        (uint256 direct,) = _sale(alice, false, residue);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertTrue(s.found);
        assertEq(s.winner, address(info.d));
        assertGt(s.spent, 0);
        assertFalse(_soldOut(info.keyD));
        vm.revertToState(snapshot);

        // settled first, the same sale finds the buyback's ETH in its own pool
        hook.settle(info.id);
        (uint256 settledFirst,) = _sale(alice, false, residue);
        assertGt(settledFirst, direct);
        // never more than the buyback spent
        assertLe(settledFirst - direct, s.spent);
        emit log_named_decimal_uint("sold directly, ETH", direct, 18);
        emit log_named_decimal_uint("settled first, ETH", settledFirst, 18);
        emit log_named_decimal_uint("the buyback spent, ETH", s.spent, 18);
    }

    /// @dev The smallest payments are made: a sale worth one wei of ETH pays it, and one that gets one wei of the other
    ///      side's token back pays it. Either left unpaid would be a debt the PoolManager refuses the whole sale for.
    function test_sale_worthOneWei_paysIt() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        // one of two amounts a factor two apart is worth exactly one wei of ETH
        bool paidOneWei;
        for (uint256 k; k < 60 && !paidOneWei; ++k) {
            uint256 snapshot = vm.snapshotState();
            (uint256 out,) = _sale(alice, true, 1 << k);
            paidOneWei = out == 1;
            vm.revertToState(snapshot);
        }
        assertTrue(paidOneWei, "no sale worth one wei of ETH");

        // a duel nobody bought: no ETH on either side, and what the pool between the sides gives comes back
        PairInfo memory quiet = _createPair(0, 0, false);
        deal(address(quiet.a), alice, 1 ether);
        vm.prank(alice);
        quiet.a.approve(address(router), type(uint256).max);
        bool backOneWei;
        for (uint256 k; k < 20 && !backOneWei; ++k) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(alice);
            assertEq(router.sell(quiet.keyA, quiet.keyX, quiet.keyD, 1 << k, 0, alice, NEVER), 0);
            backOneWei = quiet.d.balanceOf(alice) == 1;
            assertEq(quiet.a.balanceOf(alice), 1 ether - (1 << k));
            vm.revertToState(snapshot);
        }
        assertTrue(backOneWei, "no sale that gets one wei of the other side back");
    }

    /// @dev A sale that gives no ETH sends none: a recipient that cannot take ETH still gets the other side's tokens.
    function test_sale_thatGivesNoEth_callsNoRecipientForIt() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        address deaf = address(new DeafRecipient());
        deal(address(info.a), alice, 1000 ether);
        vm.prank(alice);
        assertEq(router.sell(info.keyA, info.keyX, info.keyD, 1000 ether, 0, deaf, NEVER), 0);
        assertEq(info.a.balanceOf(alice), 0);
        assertGt(info.d.balanceOf(deaf), 0);
        _assertNothingLeftBehind();
    }

    /// @dev The least gas carol's sale of `held` D through the other side goes through with, and what it pays: what a
    ///      wallet's estimate looks for.
    function _leastGas(uint256 held) internal returns (uint256 least, uint256 out) {
        bytes memory sale = abi.encodeCall(router.sell, (info.keyD, info.keyX, info.keyA, held, 0, carol, NEVER));
        uint256 low = 21_000;
        least = 20_000_000;
        while (least - low > 100) {
            uint256 mid = (low + least) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.prank(carol);
            (bool ok, bytes memory answer) = address(router).call{gas: mid}(sale);
            vm.revertToState(snapshot);
            if (ok) (least, out) = (mid, abi.decode(answer, (uint256)));
            else low = mid;
        }
    }

    /// @dev The app sends a trade with its estimate and a headroom (500,000 gas, test/audit/DuelMev.t.sol): a
    ///      trade estimated before a round's close and landing after it settles the round on its way. A sale that finds
    ///      its side's pool at the swaps' limit is the one the close adds most to: the buyback goes to the other side,
    ///      and the realignment after it buys the seller's side out of its pool, back down from that limit. What the
    ///      sale then needs more than its estimate (the least gas it goes through with, more than the gas it uses) is
    ///      a little over 300,000, which the headroom did not cover while it was 300,000: it must stay under it.
    function test_sale_estimatedBeforeTheClose_landingAfterIt_staysUnderTheAppsHeadroom() public {
        uint256 headroom = 500_000;
        vm.warp(vm.getBlockTimestamp() + 20);
        // the testnet's duel #1 in small: A leads its round; alice leaves both sides a minute before the close, then
        // carol D, whose pool is left at the swaps' limit, and carol with the D only A's pool pays for
        vm.startPrank(alice);
        router.swapExactIn{value: 0.5 ether}(info.keyA, true, 0.5 ether, 0, alice, NEVER);
        router.swapExactIn{value: 0.2 ether}(info.keyD, true, 0.2 ether, 0, alice, NEVER);
        vm.stopPrank();
        vm.prank(carol);
        uint256 bought = router.swapExactIn{value: 0.02 ether}(info.keyD, true, 0.02 ether, 0, carol, NEVER);
        _warpToRoundEnd(info.id);
        vm.warp(vm.getBlockTimestamp() - 60);
        uint256 heldA = info.a.balanceOf(alice);
        uint256 heldD = info.d.balanceOf(alice);
        vm.startPrank(alice);
        router.swapExactIn(info.keyA, false, heldA, 0, alice, NEVER);
        router.swapExactIn(info.keyD, false, heldD, 0, alice, NEVER);
        vm.stopPrank();
        vm.prank(carol);
        router.swapExactIn(info.keyD, false, bought, 0, carol, NEVER);
        uint256 held = info.d.balanceOf(carol);
        assertGt(held, 0);
        assertEq(_sqrtPrice(info.keyD), TickMath.MAX_SQRT_PRICE - 1);

        (uint256 estimate, uint256 quoted) = _leastGas(held);
        assertGt(quoted, 0);
        _warpToRoundEnd(info.id);
        (uint256 needed,) = _leastGas(held);
        emit log_named_uint("least gas before the close", estimate);
        emit log_named_uint("least gas after the close", needed);
        assertGt(needed, estimate);
        assertLt(needed - estimate, headroom);

        // sent with its estimate and the headroom, it settles the round for A and goes through
        vm.recordLogs();
        vm.prank(carol);
        router.sell{gas: estimate + headroom}(info.keyD, info.keyX, info.keyA, held, 0, carol, NEVER);
        Settlement memory s = _settlementIn(vm.getRecordedLogs());
        assertEq(s.winner, address(info.a));
        assertGt(s.spent, 0);
        assertEq(info.d.balanceOf(carol), 0);
        _assertNothingLeftBehind();
    }

    // ------------------------------------------------------------------
    // Whose tokens
    // ------------------------------------------------------------------

    function _signed(DuelToken token, uint256 key, address holder, uint256 amount)
        internal
        view
        returns (DuelRouter.Permit memory p)
    {
        p.deadline = NEVER;
        bytes32 hash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(router), amount, token.nonces(holder), p.deadline));
        (p.v, p.r, p.s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), hash)));
    }

    function test_sale_spendsOnlyItsCallersTokens_whoeverApprovedTheRouter() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        uint256 held = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        assertEq(info.a.allowance(alice, address(router)), type(uint256).max);

        // bob names alice's amount and himself as the recipient: the router pulls from bob, who holds none
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, held));
        router.sell(info.keyA, info.keyX, info.keyD, held, 0, bob, NEVER);
        assertEq(info.a.balanceOf(alice), held);
        _assertNothingLeftBehind();
    }

    function test_sellWithPermit_anotherHoldersPermitMovesNothing() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        (address trader, uint256 key) = makeAddrAndKey("permit trader");
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 held = router.swapExactIn{value: 0.5 ether}(info.keyA, true, 0.5 ether, 0, trader, NEVER);
        DuelRouter.Permit memory permit = _signed(info.a, key, trader, held);

        // bob sends the trader's permit as his own: it is no permit of his, and the router pulls from him, who holds
        // nothing to sell
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, held));
        router.sellWithPermit(info.keyA, info.keyX, info.keyD, held, 0, bob, NEVER, permit);
        assertEq(info.a.nonces(trader), 0);
        assertEq(info.a.allowance(trader, address(router)), 0);
        assertEq(info.a.balanceOf(trader), held);

        // bob sends the permit ahead to the token itself: the allowance is the one the trader signed, and the sale
        // the trader then sends goes through under it
        vm.prank(bob);
        info.a.permit(trader, address(router), held, permit.deadline, permit.v, permit.r, permit.s);
        assertEq(info.a.allowance(trader, address(router)), held);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, held));
        router.sell(info.keyA, info.keyX, info.keyD, held, 0, bob, NEVER);
        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 out = router.sellWithPermit(info.keyA, info.keyX, info.keyD, held, 1, trader, NEVER, permit);
        assertEq(trader.balance - before, out);
        assertEq(info.a.balanceOf(trader), 0);
        assertEq(info.a.allowance(trader, address(router)), 0);
        _assertNothingLeftBehind();
    }

    function test_sale_aRecipientThatSellsAgainAndClaims_isPaidOnce() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        GreedyRecipient greedy = new GreedyRecipient(router, hook);
        vm.deal(address(this), 10 ether);
        // the recipient holds A of its own, approved, and is the duel's creator-to-be of nothing: it only tries
        uint256 own = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, address(greedy), NEVER);
        greedy.arm(info.keyA, info.keyX, info.keyD, info.id);
        vm.prank(alice);
        uint256 held = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        uint256 creatorFees = hook.getPair(info.id).creatorFees;
        assertGt(creatorFees, 0);

        vm.prank(alice);
        uint256 out = router.sell(info.keyA, info.keyX, info.keyD, held, 1, address(greedy), NEVER);
        // paid once, its sale and its claim refused while the PoolManager is unlocked for alice's
        assertEq(greedy.payments(), 1);
        assertEq(greedy.attempts(), 2);
        assertEq(greedy.refused(), 2);
        assertEq(address(greedy).balance, out);
        assertEq(info.a.balanceOf(address(greedy)), own);
        assertEq(info.a.balanceOf(alice), 0);
        assertGe(hook.getPair(info.id).creatorFees, creatorFees);
        _assertNothingLeftBehind();
    }

    function test_sale_toARecipientThatRefusesEth_movesNothing() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        uint256 held = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        address deaf = address(new DeafRecipient());
        uint256 priceBefore = _sqrtPrice(info.keyA);
        uint256 pot = hook.getPair(info.id).pot;

        vm.prank(alice);
        vm.expectRevert();
        router.sell(info.keyA, info.keyX, info.keyD, held, 0, deaf, NEVER);
        assertEq(info.a.balanceOf(alice), held);
        assertEq(_sqrtPrice(info.keyA), priceBefore);
        assertEq(hook.getPair(info.id).pot, pot);
        _assertNothingLeftBehind();
    }

    /// @dev The pool named between the sides pairs the two tokens of the ETH pools named, and nothing else: one that
    ///      pairs either of them with a third token is refused, whichever comes first in it.
    function test_sale_refusesAPoolBetweenOneOfItsTokensAndAThird() public {
        PairInfo memory third = _createPair(0, 0, false);
        Currency a = info.keyA.currency1;
        Currency d = info.keyD.currency1;
        Currency[2] memory strangers = [third.keyA.currency1, third.keyD.currency1];
        vm.startPrank(alice);
        for (uint256 i; i < 2; ++i) {
            Currency x = strangers[i];
            Currency[2][4] memory pairs = [[a, x], [x, a], [d, x], [x, d]];
            for (uint256 k; k < 4; ++k) {
                PoolKey memory cross = info.keyX;
                (cross.currency0, cross.currency1) = (pairs[k][0], pairs[k][1]);
                vm.expectRevert(DuelRouter.NotACrossPool.selector);
                router.sell(info.keyA, cross, info.keyD, 1, 0, alice, NEVER);
                vm.expectRevert(DuelRouter.NotACrossPool.selector);
                router.sell(info.keyD, cross, info.keyA, 1, 0, alice, NEVER);
            }
        }
        // nor the two tokens of the same side, nor the pool of the right tokens with an ETH pool of another duel
        PoolKey memory same = info.keyX;
        (same.currency0, same.currency1) = (a, a);
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sell(info.keyA, same, info.keyD, 1, 0, alice, NEVER);
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sell(info.keyA, info.keyX, third.keyD, 1, 0, alice, NEVER);
        vm.stopPrank();
    }

    /// @dev Anyone may open a pool between a duel's two tokens without the hook, and name it in a sale: the router
    ///      checks currencies, not hooks. It trades the caller's tokens there, pays no switch fee to burn, and touches
    ///      nobody else's.
    function test_sale_throughAPoolOfTheCallersMaking_movesOnlyTheCallersTokens() public {
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        uint256 heldAlice = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, alice, NEVER);
        vm.prank(bob);
        uint256 heldA = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 0, bob, NEVER);
        vm.prank(bob);
        uint256 heldD = router.swapExactIn{value: 1 ether}(info.keyD, true, 1 ether, 0, bob, NEVER);

        // bob's own pool between A and D, without a hook, seeded with a little of each
        PoolKey memory mine = PoolKey({
            currency0: info.keyX.currency0,
            currency1: info.keyX.currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        manager.initialize(mine, _sqrtPrice(info.keyX));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.startPrank(bob);
        info.a.approve(address(lp), type(uint256).max);
        info.d.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            mine,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_272, tickUpper: 887_272, liquidityDelta: int256(heldD / 4), salt: 0
            }),
            ""
        );
        vm.stopPrank();
        uint256 leftA = info.a.balanceOf(bob);
        assertLt(leftA, heldA);

        // A's pool sold out, so that the sale has a rest to send across
        _park(startTick + 4000);
        uint256 supply = info.a.totalSupply();
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        uint256 out = router.sell(info.keyA, mine, info.keyD, leftA, 0, bob, NEVER);
        assertEq(bob.balance - ethBefore, out);
        assertEq(info.a.balanceOf(bob), 0);
        // no switch fee burned: the duel's own pool between the sides was not the one traded
        assertEq(info.a.totalSupply(), supply);
        // alice, who approved the router for everything, lost nothing
        assertEq(info.a.balanceOf(alice), heldAlice);
        _assertNothingLeftBehind();
    }
}
