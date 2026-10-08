// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {BoundedGasRouter} from "../utils/BoundedGasRouter.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @dev A launcher that launches a second duel from the refund of its first one.
contract Relauncher {
    DuelFactory internal immutable factory;
    DuelFactory.CreateParams internal params;
    bool internal again = true;

    constructor(DuelFactory _factory, DuelFactory.CreateParams memory _params) {
        factory = _factory;
        params = _params;
    }

    function launch() external payable {
        factory.createPair{value: msg.value}(params);
    }

    receive() external payable {
        if (!again) return;
        again = false;
        factory.createPair{value: factory.config().launchFee}(params);
    }
}

/// @dev One transaction that carries several parties' calls, as an ERC-4337 bundle or a relayer's multicall does:
///      first a stranger's, one call to `PoolManager.sync`, which is open to anyone; then a trader's.
contract Bundle {
    function syncThenBuy(IPoolManager manager, Currency synced, DuelRouter router, PoolKey calldata key, address to)
        external
        payable
        returns (uint256)
    {
        manager.sync(synced);
        return router.swapExactIn{value: msg.value}(key, true, msg.value, 1, to, block.timestamp);
    }

    function syncThenSell(
        IPoolManager manager,
        Currency synced,
        DuelRouter router,
        PoolKey calldata key,
        uint256 amount,
        address to
    ) external returns (uint256) {
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), amount);
        manager.sync(synced);
        return router.swapExactIn(key, false, amount, 1, to, block.timestamp);
    }

    function syncThenSwitch(
        IPoolManager manager,
        Currency synced,
        DuelRouter router,
        PoolKey calldata keyIn,
        PoolKey calldata keyOut,
        uint256 amount,
        address to
    ) external returns (uint256) {
        IERC20(Currency.unwrap(keyIn.currency1)).approve(address(router), amount);
        manager.sync(synced);
        return router.swapThroughEth(keyIn, keyOut, amount, 1, to, block.timestamp);
    }

    function syncThenLaunch(
        IPoolManager manager,
        Currency synced,
        DuelFactory factory,
        DuelFactory.CreateParams calldata params
    ) external payable returns (uint256) {
        manager.sync(synced);
        return factory.createPair{value: msg.value}(params);
    }

    receive() external payable {}
}

/// @notice Attacks found or tried during the security review, each kept as a test of the defence.
contract DuelAttacksTest is DuelTestBase {
    /// @dev A pair past its anti-snipe window where both sides have buyers, A far ahead.
    function _busyPair() internal returns (PairInfo memory info) {
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 3 ether);
        _buy(alice, info.keyD, 1 ether);
    }

    function _winnerIn(Vm.Log[] memory logs) internal view returns (address winner, uint256 spent) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == ROUND_SETTLED) {
                (, winner, spent,) = abi.decode(logs[i].data, (int24, address, uint256, uint256));
            }
        }
    }

    /// @dev Sniping at launch with an exact-output buy used to cost 1.99% of an exact-input buy of the same tokens:
    ///      the tax was taken on the pool's input instead of on what the sniper paid.
    function test_attack_exactOutputSnipe_paysTheWholeTax() public {
        PairInfo memory one = _createPair(0, 0, false);
        PairInfo memory two = _createPair(0, 0, false);

        uint256 before = alice.balance;
        uint256 tokens = _buy(alice, one.keyA, 1 ether);
        uint256 exactIn = before - alice.balance;

        before = bob.balance;
        _swap(bob, two.keyA, true, int256(tokens), 2 ether);
        assertApproxEqRel(before - bob.balance, exactIn, 0.0001e18);
    }

    /// @dev A swap sent with just enough gas to finish, hoping the arbitrage runs out. The router's own work after the
    ///      swap leaves the arbitrage 63 times what that work needs, but a caller that bounds the gas of
    ///      `PoolManager.swap` itself, and keeps its own for the settlement, could starve it: a sell, an exact-output
    ///      buy or a switch then went through without their realignment. Such a swap now reverts (`ArbitrageStarved`):
    ///      with the least gas a swap goes through with, the arbitrage ran, and below it the swap fails.
    function test_attack_gasStarvedSwap_cannotSkipTheArbitrage() public {
        PairInfo memory info = _busyPair();
        BoundedGasRouter bounded = new BoundedGasRouter(manager);
        vm.startPrank(alice);
        info.a.approve(address(bounded), type(uint256).max);
        info.d.approve(address(bounded), type(uint256).max);
        vm.stopPrank();
        bool dIn = !hook.getPair(info.id).aIsCurrency0;
        _starvedSwap(bounded, info.keyA, false, -int256(info.a.balanceOf(alice) / 2), 0);
        _starvedSwap(bounded, info.keyD, true, int256(info.d.balanceOf(alice)), 20 ether);
        _starvedSwap(bounded, info.keyX, dIn, -int256(info.d.balanceOf(alice) / 2), 0);
    }

    function _starvedSwap(BoundedGasRouter bounded, PoolKey memory key, bool zeroForOne, int256 amount, uint256 value)
        internal
    {
        bytes memory call = abi.encodeCall(BoundedGasRouter.swap, (key, zeroForOne, amount, 0));
        // the least gas for PoolManager.swap with which the whole swap succeeds
        uint256 low = 20_000;
        uint256 high = 3_000_000;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            uint256 state = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(bounded).call{value: value}(_withGas(call, mid));
            vm.revertToState(state);
            if (ok) high = mid;
            else low = mid;
        }
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(alice);
        (bool success,) = address(bounded).call{value: value}(_withGas(call, high));
        assertTrue(success);
        assertEq(_count(vm.getRecordedLogs(), ARBITRAGE_CAPTURED), 1, "the arbitrage ran with the least gas");
        vm.revertToState(snapshot);
        // less gas, down to half: no swap goes through, and the ones that starve the arbitrage say so
        bool starved;
        for (uint256 given = high - 1; given > high / 2; given -= high / 100) {
            snapshot = vm.snapshotState();
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(bounded).call{value: value}(_withGas(call, given));
            vm.revertToState(snapshot);
            assertFalse(ok, "a swap went through below the least gas");
            if (_mentions(reason, DuelHook.ArbitrageStarved.selector)) starved = true;
        }
        assertTrue(starved, "no swap reverted for starving the arbitrage");
    }

    /// @dev The router's call with another gas for PoolManager.swap: its last word.
    function _withGas(bytes memory data, uint256 swapGas) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            mstore(add(data, mload(data)), swapGas)
        }
        return data;
    }

    /// @dev Whether a revert's data carries an error (the PoolManager wraps the hook's with its own).
    function _mentions(bytes memory data, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= data.length; ++i) {
            bytes4 word =
                bytes4(data[i]) | bytes4(data[i + 1]) >> 8 | bytes4(data[i + 2]) >> 16 | bytes4(data[i + 3]) >> 24;
            if (word == selector) return true;
        }
        return false;
    }

    /// @dev A settlement sent with just enough gas: the buyback ran, and the realignment after it could be starved
    ///      the same way. The settlement now reverts instead; with the least gas it goes through with, both ran.
    function test_attack_gasStarvedSettle_cannotSkipTheRealignment() public {
        PairInfo memory info = _createPair(0, 0, false);
        _buy(bob, info.keyD, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buy(alice, info.keyA, 15 ether);
        _buy(alice, info.keyD, 0.05 ether);
        vm.warp(hook.getPair(info.id).roundEnd);
        bytes memory call = abi.encodeCall(DuelHook.settle, (info.id));
        uint256 low = 20_000;
        uint256 high = 3_000_000;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            uint256 state = vm.snapshotState();
            (bool ok,) = address(hook).call{gas: mid}(call);
            vm.revertToState(state);
            if (ok) high = mid;
            else low = mid;
        }
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        (bool settled,) = address(hook).call{gas: high}(call);
        Settlement memory least = _settlementIn(vm.getRecordedLogs());
        assertTrue(settled && least.found);
        assertGt(least.spent, 0, "no buyback");
        assertGt(least.captured, 0, "the realignment did not run with the least gas");
        vm.revertToState(snapshot);
        bool starved;
        for (uint256 given = high - 1; given > high / 2; given -= high / 100) {
            snapshot = vm.snapshotState();
            (bool ok, bytes memory reason) = address(hook).call{gas: given}(call);
            vm.revertToState(snapshot);
            assertFalse(ok, "a settlement went through below the least gas");
            if (_mentions(reason, DuelHook.ArbitrageStarved.selector)) starved = true;
        }
        assertTrue(starved, "no settlement reverted for starving the realignment");
    }

    /// @dev Everyone buys A and nobody buys D: the split used to stay at 50/50, and a dust switch could decide the
    ///      round. The cross pool now follows the ETH prices from the first buy.
    function test_attack_oneSidedLaunch_splitFollowsTheBuying() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        for (uint256 i = 0; i < 5; ++i) {
            _buy(alice, info.keyA, 1 ether);
        }
        assertGt(hook.gaugeBps(info.id), 8000);
        // a dust switch into D changes nothing
        uint256 dust = _buy(bob, info.keyA, 0.0001 ether);
        _switch(bob, info, address(info.a), dust);
        assertGt(hook.gaugeBps(info.id), 8000);
        _warpToRoundEnd(info.id);
        vm.recordLogs();
        hook.settle(info.id);
        (address winner,) = _winnerIn(vm.getRecordedLogs());
        assertEq(winner, address(info.a));
    }

    /// @dev With the arbitrage waiting for both sides, the first buyer of the side nobody bought triggered one big
    ///      realignment that pumped that side right after their buy: a free round trip. Now nothing piles up.
    function test_attack_firstBuyerOfTheOtherSide_getsNoWindfall() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        for (uint256 i = 0; i < 5; ++i) {
            _buy(alice, info.keyA, 1 ether);
        }

        uint256 before = bob.balance;
        uint256 dogs = _buy(bob, info.keyD, 1 ether);
        _sell(bob, info.keyD, dogs);
        assertLt(bob.balance, before);
    }

    /// @dev A holder of the winner pumps it just before the close and sells right after it: the pump takes the
    ///      price out of the buyback's band, so the pot does not buy, and the round trip costs the fees.
    function test_attack_buybackSandwich_loses() public {
        PairInfo memory info = _busyPair();
        // a busy round fills the pot, ten minutes apart, before its close. The time is the pair's, read from storage:
        // via-IR reuses an earlier block.timestamp after a warp, and time did not move here in the optimized build
        uint256 time = hook.getPair(info.id).launchTime + 10;
        for (uint256 i = 0; i < 10; ++i) {
            time += 10 minutes;
            vm.warp(time);
            uint256 got = _buy(alice, info.keyA, 2 ether);
            _sell(alice, info.keyA, got);
        }
        assertEq(hook.getPair(info.id).roundIndex, 0);
        assertGt(hook.getPair(info.id).pot, 0.5 ether);
        vm.warp(hook.getPair(info.id).roundEnd - 5);
        uint256 before = bob.balance;
        uint256 tokens = _buy(bob, info.keyA, 2 ether);
        vm.warp(hook.getPair(info.id).roundEnd);
        _sell(bob, info.keyA, tokens);
        assertLt(bob.balance, before);
    }

    /// @dev The swap that settles a round runs right after the buyback, which moves the winner's ETH price: a detour
    ///      through the cross pool finds no gap to make up for its extra fee (the settlement realigns the pools).
    function test_attack_settlingSwap_findsThePoolsAligned() public {
        PairInfo memory info = _createPair(0, 0, false);
        // a sniper's taxed buy fills the pot: the buyback will move A by the whole 10% band
        _buy(bob, info.keyA, 5 ether);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 3 ether);
        _buy(alice, info.keyD, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        _buy(alice, info.keyA, 2 ether);
        _warpToRoundEnd(info.id);
        uint256 dogs = info.d.balanceOf(alice) / 4;

        // selling D straight for ETH, and settling the round with it
        uint256 snapshot = vm.snapshotState();
        uint256 before = alice.balance;
        _sell(alice, info.keyD, dogs);
        uint256 direct = alice.balance - before;
        vm.revertToState(snapshot);

        // or switching D into A in the cross pool, which settles the round and buys A back, then selling that A
        before = alice.balance;
        vm.recordLogs();
        uint256 cats = _switch(alice, info, address(info.d), dogs);
        (address winner, uint256 spent) = _winnerIn(vm.getRecordedLogs());
        assertEq(winner, address(info.a));
        assertGt(spent, 0);
        _sell(alice, info.keyA, cats);
        uint256 viaCross = alice.balance - before;
        // the detour pays one more fee and finds no gap to make up for it
        assertLt(viaCross, direct);
    }

    /// @dev Selling more tokens than an ETH pool can pay for left its price at the swap's limit: the app showed a
    ///      price of zero and the buyback reference drifted away. The arbitrage now brings such a pool back.
    function test_attack_oversell_cannotBreakThePrice() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 bought = _buy(alice, info.keyA, 0.1 ether);
        _buy(bob, info.keyD, 0.1 ether);
        deal(address(info.a), alice, bought * 2);
        _sell(alice, info.keyA, bought * 2);
        int24 start = hook.getPair(info.id).startTick;
        assertLt(_tick(info.keyA), start);
        vm.warp(block.timestamp + 1 hours);
        _buy(bob, info.keyD, 0.001 ether);
        assertLe(hook.getPair(info.id).emaA, int40(start) * 65_536);
        uint256 launchPrice = lens.getPair(_createPair(0, 0, false).id).a.priceWad;
        assertGe(lens.getPair(info.id).a.priceWad, launchPrice);
    }

    /// @dev Buying one side makes the arbitrage buy some of the other: a holder of D pumps A to lift D, then sells
    ///      everything. The arbitrage's profit goes to the pot, so the round trip loses.
    function test_attack_pumpOneSideToLiftTheOther_loses() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 1 ether);
        _buy(alice, info.keyD, 1 ether);

        uint256 before = bob.balance;
        uint256 dogs = _buy(bob, info.keyD, 2 ether);
        uint256 cats = _buy(bob, info.keyA, 20 ether);
        _sell(bob, info.keyD, dogs);
        _sell(bob, info.keyA, cats);
        assertLt(bob.balance, before);
        emit log_named_decimal_int("round trip P&L (ETH)", int256(bob.balance) - int256(before), 18);
    }

    /// @dev The triangle over and over: A bought with ETH, switched whole into D through the A/D pool, all of D sold
    ///      through the router. Each sale takes ETH out of D's pool, and the realignment after it buys D back with ETH
    ///      from A's: the loop cannot empty D's pool, its holders still leave with as much, and nearly all the attacker
    ///      loses goes to the pot, which buys the next round's winner back.
    function test_attack_triangleOverAndOver_drainsNothingAndPaysThePot() public {
        PairInfo memory info = _busyPair();
        uint256 reserveD = lens.getPair(info.id).d.ethReserve;
        vm.prank(alice);
        info.d.approve(address(router), type(uint256).max);
        uint256 dogsHeld = info.d.balanceOf(alice);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 exitD = router.swapExactIn(info.keyD, false, dogsHeld, 0, alice, block.timestamp);
        vm.revertToState(snapshot);
        uint256 pot = hook.getPair(info.id).pot;
        uint256 before = bob.balance;

        vm.prank(bob);
        info.d.approve(address(router), type(uint256).max);
        for (uint256 i; i < 20; ++i) {
            uint256 dogs = _switch(bob, info, address(info.a), _buy(bob, info.keyA, 0.5 ether));
            vm.prank(bob);
            router.swapExactIn(info.keyD, false, dogs, 0, bob, block.timestamp);
        }

        uint256 lost = before - bob.balance;
        assertGt(lost, 5 ether);
        assertGe(lens.getPair(info.id).d.ethReserve, reserveD);
        vm.prank(alice);
        assertGe(router.swapExactIn(info.keyD, false, dogsHeld, 0, alice, block.timestamp), exitD);
        assertGt(hook.getPair(info.id).pot - pot, (lost * 9) / 10);
        emit log_named_decimal_uint("lost by the attacker (ETH)", lost, 18);
        emit log_named_decimal_uint("to the pot (ETH)", hook.getPair(info.id).pot - pot, 18);
    }

    /// @dev `PoolManager.sync` is open to anyone, and the currency it leaves synced lasts until the transaction ends: a
    ///      token synced by a stranger's call earlier in a shared transaction made the PoolManager refuse the ETH of
    ///      every buy the router settled after it (`NonzeroNativeValue`), the buyer's gas spent for nothing. The router
    ///      syncs what it settles, ETH included; sales, switches and launches, which always synced a token first, go
    ///      through as before.
    function test_attack_aTokenSyncedEarlierInTheTransaction_blocksNoTrade() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        Bundle bundle = new Bundle();
        Currency synced = Currency.wrap(address(info.d));

        vm.prank(alice);
        uint256 held = bundle.syncThenBuy{value: 1 ether}(manager, synced, router, info.keyA, alice);
        assertGt(held, 0);
        assertEq(info.a.balanceOf(alice), held);

        vm.prank(alice);
        info.a.transfer(address(bundle), held);
        assertGt(bundle.syncThenSell(manager, synced, router, info.keyA, held / 4, alice), 0);
        assertGt(bundle.syncThenSwitch(manager, synced, router, info.keyA, info.keyD, held / 4, alice), 0);
        vm.deal(address(this), 1 ether);
        assertEq(
            bundle.syncThenLaunch{value: LAUNCH_FEE + 0.02 ether}(
                manager, synced, factory, createParams(0.01 ether, 0.01 ether, false)
            ),
            2
        );
    }

    function test_attack_relaunchFromTheRefund_keepsTheLaunchesInOrder() public {
        // a launcher that overpays gets a refund, and launches again from it
        Relauncher launcher = new Relauncher(factory, createParams(0, 0, false));
        vm.deal(address(launcher), 1 ether);
        vm.recordLogs();
        launcher.launch{value: 2 * LAUNCH_FEE}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory announced = new uint256[](2);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == DuelFactory.PairCreated.selector) {
                announced[count++] = uint256(logs[i].topics[1]);
            }
        }
        // the logs announce the duels in the order of their ids
        assertEq(count, 2);
        assertEq(announced[0], 1);
        assertEq(announced[1], 2);
    }
}
