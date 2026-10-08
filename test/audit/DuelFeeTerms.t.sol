// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @notice The launch terms, anywhere the factory lets its owner set them: a duel keeps the terms of its launch for
///         good, on a hook nobody can change, so whatever terms are allowed must trade, and split every fee to the
///         wei. Two duels launched under different terms share the hook, as the testnet's will once its owner
///         proposes the terms of the launch (1.2%, shared 33%, 33% and 34%) beside the duels launched at 1%. Every
///         kind of trade is checked against the rule written out here, not against the hook's own arithmetic: what
///         the trader paid or received, the fee and the tax, the three shares, the pot, and the hook's books.
contract DuelFeeTermsTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    bytes32 internal constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256,uint256)");
    bytes32 internal constant SWITCH_FEE_BURNED = keccak256("SwitchFeeBurned(uint256,address,uint256)");

    /// @dev A duel, the terms it was launched under and whether its creator gave its share to the pot.
    struct Launched {
        PairInfo pair;
        DuelFactory.Config terms;
        bool supporter;
    }

    /// @dev What a trade did to a duel's accounts.
    struct Moved {
        uint256 gross; // the ETH the trade counts in the volume
        uint256 fee;
        uint256 tax;
        uint256 protocol;
        uint256 creator;
        uint256 pot;
        uint256 captured; // the realignment's profit, which goes to the pot too
    }

    function _apply(DuelFactory.Config memory c) internal {
        vm.prank(owner);
        factory.proposeConfig(c);
        vm.warp(factory.pendingConfigEta());
        factory.applyConfig();
    }

    /// @dev Terms within the factory's bounds, drawn from `r`: anywhere in them, or at their edges one time in four.
    function _draw(uint256 r) internal view returns (DuelFactory.Config memory c) {
        c = defaultConfig();
        bool edge = r % 4 == 0;
        r >>= 2;
        c.swapFeeBps = edge ? (r & 1 == 0 ? 25 : 200) : uint16(25 + (r % 176));
        c.switchFeeBps = edge ? ((r >> 1) & 1 == 0 ? 0 : 100) : uint16((r >> 8) % 101);
        c.protocolShareBps = edge ? ((r >> 2) & 1 == 0 ? 0 : 5000) : uint16((r >> 16) % 5001);
        c.potShareBps = edge ? ((r >> 3) & 1 == 0 ? 0 : 5000) : uint16((r >> 32) % 5001);
        c.snipeWindow = edge ? ((r >> 4) & 1 == 0 ? 0 : 60) : uint16((r >> 48) % 61);
        // the fee and the tax together stay under the whole trade
        c.snipeStartBps =
            edge ? ((r >> 5) & 1 == 0 ? 0 : uint16(BPS - 1 - c.swapFeeBps)) : uint16((r >> 56) % (BPS - c.swapFeeBps));
        c.startFdv =
            uint96(edge ? ((r >> 6) & 1 == 0 ? 0.1 ether : 1000 ether) : _bound(r >> 72, 0.1 ether, 1000 ether));
        c.crossShareBps = edge ? ((r >> 7) & 1 == 0 ? 200 : 2000) : uint16(200 + (r >> 100) % 1801);
        c.launchFee = uint96(edge ? ((r >> 8) & 1 == 0 ? 0 : 0.01 ether) : (r >> 120) % (0.01 ether + 1));
    }

    function _launch(DuelFactory.Config memory terms, bool supporter) internal returns (Launched memory l) {
        DuelFactory.CreateParams memory params = createParams(0, 0, supporter);
        vm.prank(creator);
        l.pair = _info(factory.createPair{value: terms.launchFee}(params));
        l.terms = terms;
        l.supporter = supporter;
        DuelHook.FeeConfig memory kept = hook.getPair(l.pair.id).fees;
        assertEq(
            abi.encode(kept),
            abi.encode(
                DuelHook.FeeConfig(
                    terms.swapFeeBps,
                    terms.switchFeeBps,
                    terms.protocolShareBps,
                    terms.potShareBps,
                    terms.snipeStartBps,
                    terms.snipeWindow
                )
            )
        );
    }

    /// @dev The rule: of a fee, the protocol's share as the terms set it, of which the protocol takes its rate and
    ///      leaves the rest to the pot; the pot's share; the creator the remainder, or the pot in a supporter duel.
    function _shares(Launched memory l, uint256 fee)
        internal
        view
        returns (uint256 protocol, uint256 creatorShare, uint256 pot)
    {
        uint256 protocolShare = fee * l.terms.protocolShareBps / BPS;
        protocol = protocolShare * hook.protocolRateBps() / BPS;
        pot = fee * l.terms.potShareBps / BPS;
        creatorShare = fee - protocolShare - pot;
        pot += protocolShare - protocol;
        if (l.supporter) {
            pot += creatorShare;
            creatorShare = 0;
        }
    }

    /// @dev The ETH an ETH pool holds: what its liquidity pays between its price and its launch price.
    function _ethIn(Launched memory l, PoolKey memory key) internal view returns (uint256) {
        uint160 launchPrice = TickMath.getSqrtPriceAtTick(hook.getPair(l.pair.id).startTick);
        uint160 price = _sqrtPrice(key);
        if (price >= launchPrice) return 0;
        return SqrtPriceMath.getAmount0Delta(price, launchPrice, manager.getLiquidity(key.toId()), false);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Runs one swap of the duel and reads what it did to its accounts, checked against the rule: the fee and
    ///      the tax share the cut at their rates, the three shares add up to the fee, the pot takes its share, the tax
    ///      and the realignment's profit, and nothing else moves.
    function _swapAndCheck(
        Launched memory l,
        address user,
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 value
    ) internal returns (Moved memory m) {
        DuelHook.Pair memory before = hook.getPair(l.pair.id);
        uint256 protocolBefore = hook.protocolFees();
        _approve(user, key);
        vm.recordLogs();
        _swap(user, key, zeroForOne, amountSpecified, value);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feesTaken;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || uint256(logs[i].topics[1]) != l.pair.id) continue;
            if (logs[i].topics[0] == FEE_TAKEN) {
                (m.fee, m.tax) = abi.decode(logs[i].data, (uint256, uint256));
                ++feesTaken;
            } else if (logs[i].topics[0] == ARBITRAGE_CAPTURED) {
                m.captured += abi.decode(logs[i].data, (uint256));
            }
        }
        assertLe(feesTaken, 1);
        DuelHook.Pair memory after_ = hook.getPair(l.pair.id);
        m.gross = after_.volume - before.volume;
        m.protocol = hook.protocolFees() - protocolBefore;
        m.creator = after_.creatorFees - before.creatorFees;
        m.pot = after_.pot - before.pot;

        (uint256 protocol, uint256 creatorShare, uint256 pot) = _shares(l, m.fee);
        assertEq(m.protocol, protocol, "the protocol's part");
        assertEq(m.creator, creatorShare, "the creator's part");
        assertEq(m.pot, pot + m.tax + m.captured, "the pot's part");
        assertEq(protocol + creatorShare + pot, m.fee, "the three parts are the fee");
    }

    function _assertBooks(Launched memory one, Launched memory two) internal view {
        DuelHook.Pair memory p = hook.getPair(one.pair.id);
        DuelHook.Pair memory q = hook.getPair(two.pair.id);
        assertEq(
            manager.balanceOf(address(hook), 0),
            hook.protocolFees() + p.pot + p.creatorFees + q.pot + q.creatorFees,
            "the hook holds what it owes, no more"
        );
        assertEq(address(hook).balance, 0);
        assertEq(address(factory).balance, 0);
    }

    /// @dev Every kind of trade on one duel, each checked: a buy and a sale by an exact amount of ETH or of tokens,
    ///      a switch through the pool between the sides by an exact amount in or out.
    function _everyTrade(Launched memory l, uint256 r) internal {
        uint256 fee = l.terms.swapFeeBps;
        PairInfo memory pair = l.pair;

        // a buy for an exact amount of ETH: the cut is on what is paid, the tax at its rate of the moment
        uint256 rate = fee + hook.snipeTaxBps(pair.id);
        uint256 eth = _bound(r, 0.0001 ether, 5 ether);
        uint256 paid = alice.balance;
        Moved memory m = _swapAndCheck(l, alice, pair.keyA, true, -int256(eth), eth);
        assertEq(paid - alice.balance, eth);
        assertEq(m.gross, eth);
        assertEq(m.fee + m.tax, eth * rate / BPS, "the cut of a buy by its ETH");
        assertEq(m.fee, m.fee + m.tax == 0 ? 0 : (m.fee + m.tax) * fee / rate);
        uint256 held = pair.a.balanceOf(alice);
        assertGt(held, 0);

        // a buy of an exact amount of tokens: the cut is grossed up on the ETH the pool takes, at the same rates
        rate = fee + hook.snipeTaxBps(pair.id);
        paid = bob.balance;
        m = _swapAndCheck(l, bob, pair.keyD, true, int256(held / 10 + 1), bob.balance);
        assertEq(paid - bob.balance, m.gross, "a buy by its tokens pays the pool's ETH and the cut");
        assertEq(m.gross, _ceilDiv((m.gross - m.fee - m.tax) * BPS, BPS - rate), "the cut of a buy by its tokens");
        assertEq(m.fee, m.fee + m.tax == 0 ? 0 : (m.fee + m.tax) * fee / rate);

        // a sale of an exact amount of tokens: the fee is on the ETH the pool pays, and no tax
        paid = alice.balance;
        m = _swapAndCheck(l, alice, pair.keyA, false, -int256(_bound(r >> 64, 1, held / 2)), 0);
        assertEq(m.tax, 0);
        assertEq(m.fee, m.gross * fee / BPS, "the fee of a sale by its tokens");
        assertEq(alice.balance - paid, m.gross - m.fee);

        // a sale for an exact amount of ETH: the fee is grossed up on it, and the pool, which holds more, fills it all
        // (a buy taxed at nearly everything can leave it a few wei: nothing to ask of it then)
        uint256 has = _ethIn(l, pair.keyA);
        if (has >= 3) {
            uint256 asked = _bound(r >> 128, 1, has / 3);
            paid = alice.balance;
            m = _swapAndCheck(l, alice, pair.keyA, false, int256(asked), 0);
            assertEq(m.tax, 0);
            assertEq(alice.balance - paid, asked);
            assertEq(m.gross, _ceilDiv(asked * BPS, BPS - fee), "the fee of a sale by its ETH");
            assertEq(m.fee, m.gross - asked);
        }

        // a switch through the pool between the sides by an exact amount in: no ETH fee, the switch fee burned
        bool zeroForOne = pair.keyX.currency0 == pair.keyA.currency1;
        uint256 amount = _bound(r >> 192, 1, pair.a.balanceOf(alice) / 2);
        uint256 supply = pair.a.totalSupply();
        m = _swapAndCheck(l, alice, pair.keyX, zeroForOne, -int256(amount), 0);
        assertEq(m.gross + m.fee + m.tax, 0);
        assertEq(supply - pair.a.totalSupply(), amount * l.terms.switchFeeBps / BPS, "the switch fee burned");

        // and by an exact amount out: the fee grossed up on what the pool takes
        held = pair.a.balanceOf(alice);
        supply = pair.a.totalSupply();
        uint256 got = pair.d.balanceOf(alice);
        m = _swapAndCheck(l, alice, pair.keyX, zeroForOne, int256(got / 4 + 1), 0);
        uint256 burned = supply - pair.a.totalSupply();
        uint256 taken = held - pair.a.balanceOf(alice) - burned;
        assertEq(m.gross + m.fee + m.tax, 0);
        assertEq(burned, _ceilDiv(taken * BPS, BPS - l.terms.switchFeeBps) - taken, "the switch fee grossed up");
        assertEq(pair.d.balanceOf(alice) - got, got / 4 + 1);
    }

    function testFuzz_terms_anyAllowedTerms_everyTradeSplitsToTheWei(uint256 seed, uint16 protocolRate) public {
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        // a duel under terms within the factory's bounds, then another under others, 48 hours later: one hook
        DuelFactory.Config memory first = _draw(uint256(keccak256(abi.encode(seed, 1))));
        _apply(first);
        Launched memory one = _launch(first, seed & 1 == 0);
        DuelFactory.Config memory second = _draw(uint256(keccak256(abi.encode(seed, 2))));
        _apply(second);
        Launched memory two = _launch(second, seed & 2 == 0);
        // the first keeps the terms of its launch
        DuelHook.FeeConfig memory kept = hook.getPair(one.pair.id).fees;
        assertEq(kept.swapFeeBps, first.swapFeeBps);
        assertEq(kept.protocolShareBps, first.protocolShareBps);
        assertEq(kept.potShareBps, first.potShareBps);
        // the protocol takes any part of its share, for both at once
        vm.prank(owner);
        factory.setProtocolRate(uint16(_bound(protocolRate, 0, BPS)));

        // the second trades inside its anti-snipe window when it has one, the first long after its own
        vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 4);
        _everyTrade(two, uint256(keccak256(abi.encode(seed, 3))));
        _everyTrade(one, uint256(keccak256(abi.encode(seed, 4))));
        vm.warp(vm.getBlockTimestamp() + (seed >> 16) % 70);
        // one time in two its creator gives its share of the fees to come to the pots: the same rule, from then on
        if (!two.supporter && seed & 4 == 0) {
            uint256 owed = hook.getPair(two.pair.id).creatorFees;
            vm.prank(creator);
            hook.giveUpCreatorFees(two.pair.id);
            two.supporter = true;
            assertEq(hook.getPair(two.pair.id).creatorFees, owed);
        }
        _everyTrade(two, uint256(keccak256(abi.encode(seed, 5))));
        _assertBooks(one, two);

        // each creator is paid its own duel's fees, the treasury the protocol's, and the pots keep theirs
        uint256 owedOne = hook.getPair(one.pair.id).creatorFees;
        uint256 owedTwo = hook.getPair(two.pair.id).creatorFees;
        uint256 owedProtocol = hook.protocolFees();
        uint256 creatorBefore = creator.balance;
        if (owedOne != 0) assertEq(hook.claimCreatorFees(one.pair.id), owedOne);
        if (owedTwo != 0) assertEq(hook.claimCreatorFees(two.pair.id), owedTwo);
        assertEq(creator.balance - creatorBefore, owedOne + owedTwo);
        uint256 treasuryBefore = treasury.balance;
        if (owedProtocol != 0) assertEq(hook.claimProtocolFees(), owedProtocol);
        assertEq(treasury.balance - treasuryBefore, owedProtocol);
        if (one.supporter) assertEq(owedOne, 0);
        _assertBooks(one, two);
    }

    /// @dev The testnet's path: its duels were launched at 1%, shared 30%, 50% and 20%; its owner then proposes the
    ///      launch's terms. The old duels keep theirs trade after trade, the new ones pay the new, and a sale through
    ///      the other side pays each pool's fee at its duel's rate.
    function test_terms_theOldTermsAndTheNew_onOneHook() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        DuelFactory.Config memory old = defaultConfig();
        old.swapFeeBps = 100;
        old.protocolShareBps = 3000;
        old.potShareBps = 2000;
        _apply(old);
        Launched memory before = _launch(old, false);
        _apply(defaultConfig());
        Launched memory after_ = _launch(defaultConfig(), false);
        vm.warp(vm.getBlockTimestamp() + 20);

        // 1 ETH into each: 0.01 ETH of fee shared 30/50/20, and 0.012 ETH shared 33/33/34
        Moved memory m = _swapAndCheck(before, alice, before.pair.keyA, true, -1 ether, 1 ether);
        assertEq(m.fee, 0.01 ether);
        assertEq(m.protocol, 0.003 ether);
        assertEq(m.creator, 0.005 ether);
        assertEq(m.pot - m.captured, 0.002 ether);
        m = _swapAndCheck(after_, alice, after_.pair.keyA, true, -1 ether, 1 ether);
        assertEq(m.fee, 0.012 ether);
        assertEq(m.protocol, 0.003_96 ether);
        assertEq(m.creator, 0.003_96 ether);
        assertEq(m.pot - m.captured, 0.004_08 ether);

        // the same, trade after trade
        _everyTrade(before, 1);
        _everyTrade(after_, 2);
        _everyTrade(before, 3);
        _assertBooks(before, after_);

        // a whole exit through the router, of the old duel then of the new: each pays its own rate on every pass
        _wholeExit(before);
        _wholeExit(after_);
        _assertBooks(before, after_);
    }

    /// @dev Alice sells all her A of a duel through the router's `sell`: every pass pays the fee at the duel's own
    ///      rate, shared as its own terms say.
    function _wholeExit(Launched memory l) internal {
        uint256 held = l.pair.a.balanceOf(alice);
        DuelHook.Pair memory before = hook.getPair(l.pair.id);
        vm.startPrank(alice);
        l.pair.a.approve(address(router), held);
        vm.recordLogs();
        uint256 out = router.sell(l.pair.keyA, l.pair.keyX, l.pair.keyD, held, 1, alice, type(uint256).max);
        vm.stopPrank();
        uint256 fees = _feesOf(l.pair.id, vm.getRecordedLogs());
        DuelHook.Pair memory after_ = hook.getPair(l.pair.id);
        uint256 gross = after_.volume - before.volume;
        assertEq(gross - fees, out);
        // each pass rounds its own fee down: a wei a pass at most under the rate on the whole
        assertApproxEqAbs(fees, gross * l.terms.swapFeeBps / BPS, 2 * router.SALE_PASSES());
        assertApproxEqAbs(
            after_.creatorFees - before.creatorFees,
            fees * (BPS - l.terms.protocolShareBps - l.terms.potShareBps) / BPS,
            4 * router.SALE_PASSES()
        );
        assertEq(l.pair.a.balanceOf(alice), 0);
    }

    /// @dev The fees the hook took in `logs`, all of them for the duel `pairId` and none of them a tax.
    function _feesOf(uint256 pairId, Vm.Log[] memory logs) internal view returns (uint256 fees) {
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].emitter != address(hook) || logs[k].topics[0] != FEE_TAKEN) continue;
            assertEq(uint256(logs[k].topics[1]), pairId);
            (uint256 fee, uint256 tax) = abi.decode(logs[k].data, (uint256, uint256));
            assertEq(tax, 0);
            fees += fee;
        }
    }
}
