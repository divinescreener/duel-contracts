// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelHook} from "../../src/DuelHook.sol";

contract DuelHookTest is DuelTestBase {
    // ------------------------------------------------------------------
    // Deployment and permissions
    // ------------------------------------------------------------------

    function test_constructor_deploysAtMinedAddress() public {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(DuelHook).creationCode, abi.encode(address(manager), address(factory))));
        for (uint256 salt = 0; salt < 500_000; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), initCodeHash, address(this));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                DuelHook deployed = new DuelHook{salt: bytes32(salt)}(manager, address(factory));
                assertEq(address(deployed), predicted);
                assertEq(address(deployed.poolManager()), address(manager));
                assertEq(deployed.factory(), address(factory));
                return;
            }
        }
        revert("no salt found");
    }

    function test_constructor_revertsAtAddressWithoutFlags() public {
        vm.expectRevert();
        new DuelHook(manager, address(factory));
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeRemoveLiquidity && p.beforeDonate);
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.afterAddLiquidity || p.afterRemoveLiquidity || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    function test_callbacks_onlyPoolManager() public {
        PairInfo memory info = _createPair(0, 0, false);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), info.keyA, params, "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.afterSwap(address(this), info.keyA, params, toBalanceDelta(0, 0), "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.unlockCallback("");

        IPoolManager.ModifyLiquidityParams memory lp = IPoolManager.ModifyLiquidityParams(-200, 200, 1, 0);
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), info.keyA, 0);
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.afterInitialize(address(factory), info.keyA, 0, 0);
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(factory), info.keyA, lp, "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(factory), info.keyA, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(factory), info.keyA, lp, "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(factory), info.keyA, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.beforeDonate(address(factory), info.keyA, 0, 0, "");
        vm.expectRevert(DuelHook.NotPoolManager.selector);
        hook.afterDonate(address(factory), info.keyA, 0, 0, "");
    }

    function test_unimplementedCallbacksRevert() public {
        PairInfo memory info = _createPair(0, 0, false);
        IPoolManager.ModifyLiquidityParams memory lp = IPoolManager.ModifyLiquidityParams(-200, 200, 1, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(DuelHook.HookNotImplemented.selector);
        hook.afterInitialize(address(factory), info.keyA, 0, 0);
        vm.expectRevert(DuelHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(factory), info.keyA, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(DuelHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(factory), info.keyA, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(DuelHook.HookNotImplemented.selector);
        hook.afterDonate(address(factory), info.keyA, 0, 0, "");
        vm.stopPrank();
    }

    function test_registerPair_onlyFactory() public {
        DuelHook.FeeConfig memory fees;
        vm.expectRevert(DuelHook.NotFactory.selector);
        hook.registerPair(address(1), address(2), creator, false, 0, fees, 0);
    }

    function test_arbitrage_onlySelf() public {
        vm.expectRevert(DuelHook.NotSelf.selector);
        hook.arbitrage(1);
    }

    function test_beforeInitialize_rejectsOutsiders() public {
        PoolKey memory key = _foreignKey();
        vm.expectRevert(
            _hookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DuelHook.NotFactory.selector))
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_beforeInitialize_rejectsUnregisteredPools() public {
        PoolKey memory key = _foreignKey();
        vm.prank(address(factory));
        vm.expectRevert(
            _hookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DuelHook.UnknownPool.selector))
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_liquidity_cannotBeAddedByOthersNorRemoved() public {
        PairInfo memory info = _createPair(0, 0, false);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);

        vm.expectRevert(
            _hookError(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(DuelHook.NotFactory.selector))
        );
        lpRouter.modifyLiquidity(info.keyX, IPoolManager.ModifyLiquidityParams(-600, 600, 1e18, 0), "");

        vm.expectRevert(
            _hookError(IHooks.beforeRemoveLiquidity.selector, abi.encodeWithSelector(DuelHook.LiquidityLocked.selector))
        );
        lpRouter.modifyLiquidity(info.keyX, IPoolManager.ModifyLiquidityParams(-600, 600, -1e18, 0), "");
    }

    function test_donations_disabled() public {
        PairInfo memory info = _createPair(0, 0, false);
        PoolDonateTest donateRouter = new PoolDonateTest(manager);
        vm.expectRevert(
            _hookError(IHooks.beforeDonate.selector, abi.encodeWithSelector(DuelHook.DonationsDisabled.selector))
        );
        donateRouter.donate(info.keyX, 1, 1, "");
    }

    // ------------------------------------------------------------------
    // ETH swap fees and anti-snipe tax
    // ------------------------------------------------------------------

    /// @dev Turns the internal arbitrage off, so that the pot only holds fees.
    function _withoutArbitrage() internal {
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(DuelHook.arbitrage.selector), "off");
    }

    function test_buyExactIn_atLaunch_paysFeeAndSnipeTax() public {
        PairInfo memory info = _createPair(0, 0, false);
        assertEq(hook.snipeTaxBps(info.id), 9800);

        _approve(alice, info.keyA);
        vm.expectEmit(address(hook));
        emit DuelHook.FeeTaken(info.id, 0.012 ether, 0.98 ether);
        _buy(alice, info.keyA, 1 ether);

        DuelHook.Pair memory p = hook.getPair(info.id);
        assertEq(hook.protocolFees(), 0.003_96 ether);
        assertEq(p.creatorFees, 0.003_96 ether);
        assertGe(p.pot, 0.004_08 ether + 0.98 ether);
    }

    function test_buyExactIn_afterSnipeWindow_paysFeeOnly() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        assertEq(hook.snipeTaxBps(info.id), 0);

        uint256 before = alice.balance;
        _approve(alice, info.keyA);
        vm.expectEmit(address(hook));
        emit DuelHook.FeeTaken(info.id, 0.012 ether, 0);
        uint256 bought = _buy(alice, info.keyA, 1 ether);

        assertEq(before - alice.balance, 1 ether);
        assertEq(info.a.balanceOf(alice), bought);
        assertEq(hook.protocolFees(), 0.003_96 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0.003_96 ether);
        assertEq(hook.getPair(info.id).pot, 0.004_08 ether);
        assertEq(hook.getPair(info.id).volume, 1 ether);
    }

    function test_snipeTax_decaysToZero() public {
        PairInfo memory info = _createPair(0, 0, false);
        // read from storage: via-IR may re-read block.timestamp in place of a local copy
        uint256 launch = hook.getPair(info.id).launchTime;
        vm.warp(launch + 1);
        assertEq(hook.snipeTaxBps(info.id), 4900);
        vm.warp(launch + 3);
        assertEq(hook.snipeTaxBps(info.id), 612);
        vm.warp(launch + 5);
        assertEq(hook.snipeTaxBps(info.id), 76);
        vm.warp(launch + 9);
        assertEq(hook.snipeTaxBps(info.id), 2);
        vm.warp(launch + 10);
        assertEq(hook.snipeTaxBps(info.id), 0);
    }

    function test_buyExactOut_paysTheSameRatesAsExactIn() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 1); // tax = 49%
        _withoutArbitrage();
        uint256 before = alice.balance;
        BalanceDelta delta = _swap(alice, info.keyA, true, int256(1_000_000 ether), 1 ether);

        assertEq(info.a.balanceOf(alice), 1_000_000 ether);
        uint256 paid = before - alice.balance;
        assertEq(paid, uint256(int256(-delta.amount0())));
        // the hook kept 1.2% + 49% of what alice paid, as on an exact-input buy
        DuelHook.Pair memory p = hook.getPair(info.id);
        uint256 kept = hook.protocolFees() + p.creatorFees + p.pot;
        assertApproxEqAbs(kept, (paid * 5020) / 10_000, 1);
        assertApproxEqAbs(hook.protocolFees(), ((paid * 120) / 10_000) * 33 / 100, 1);
        assertEq(p.volume, paid);
    }

    /// @dev The tokens a sniper gets at launch cost the same, whichever way the swap is specified.
    function test_snipeTax_exactOutputDoesNotEscapeIt() public {
        PairInfo memory one = _createPair(0, 0, false);
        PairInfo memory two = _createPair(0, 0, false);

        uint256 before = alice.balance;
        uint256 tokens = _buy(alice, one.keyA, 1 ether);
        assertEq(before - alice.balance, 1 ether);

        before = bob.balance;
        _swap(bob, two.keyA, true, int256(tokens), 2 ether);
        assertApproxEqRel(before - bob.balance, 1 ether, 0.0001e18);
    }

    function test_sellExactIn_paysFeeOnEthOutput() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 bought = _buy(alice, info.keyA, 1 ether);
        uint256 protocolBefore = hook.protocolFees();

        uint256 before = alice.balance;
        uint256 ethOut = _sell(alice, info.keyA, bought / 2);
        assertEq(alice.balance - before, ethOut);
        // gross ETH out = ethOut / 0.988; the protocol gets 33% of 1.2% of it
        uint256 fee = (ethOut * 120) / 9880;
        assertApproxEqAbs(hook.protocolFees() - protocolBefore, (fee * 3300) / 10_000, 1e6);
    }

    function test_sellExactOut_paysTheSameRateAsExactIn() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 1 ether);
        uint256 protocolBefore = hook.protocolFees();

        // 0.1 ETH out is 98.8% of the ETH the pool pays: 1.2% of 0.10121… ETH goes to the hook
        uint256 gross = 0.101_214_574_898_785_426 ether;
        uint256 fee = gross - 0.1 ether;
        uint256 before = alice.balance;
        _approve(alice, info.keyA);
        vm.expectEmit(address(hook));
        emit DuelHook.FeeTaken(info.id, fee, 0);
        _swap(alice, info.keyA, false, int256(0.1 ether), 0);
        assertEq(alice.balance - before, 0.1 ether);
        assertEq(hook.protocolFees() - protocolBefore, (fee * 3300) / 10_000);
        assertEq(hook.getPair(info.id).volume, 1 ether + gross);
    }

    function test_tinySwap_takesNothing() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 protocolBefore = hook.protocolFees();
        // 1.2% of 83 wei is under a wei
        _buy(alice, info.keyA, 83);
        assertEq(hook.protocolFees(), protocolBefore);
        assertEq(hook.getPair(info.id).creatorFees, 0);
        // the volume still counts it
        assertEq(hook.getPair(info.id).volume, 83);
    }

    function test_volume_countsEthTradesOnly() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 bought = _buy(alice, info.keyA, 1 ether);
        // the internal arbitrage that follows the buy is not volume
        assertEq(hook.getPair(info.id).volume, 1 ether);

        // switching sides trades no ETH
        _approve(alice, info.keyX);
        _switch(alice, info, address(info.a), bought / 4);
        assertEq(hook.getPair(info.id).volume, 1 ether);

        // a sell counts the ETH out before the fee
        uint256 ethOut = _sell(alice, info.keyA, info.a.balanceOf(alice));
        assertApproxEqAbs(hook.getPair(info.id).volume - 1 ether, (ethOut * 10_000) / 9880, 1e6);
    }

    function test_supporterPair_sendsCreatorShareToPot() public {
        PairInfo memory info = _createPair(0, 0, true);
        vm.warp(block.timestamp + 10);
        _withoutArbitrage();
        _buy(alice, info.keyA, 1 ether);
        DuelHook.Pair memory p = hook.getPair(info.id);
        assertTrue(p.supporter);
        assertEq(p.creatorFees, 0);
        assertEq(hook.protocolFees(), 0.003_96 ether);
        assertEq(p.pot, 0.008_04 ether);
    }

    // ------------------------------------------------------------------
    // Switch fee in the cross pool
    // ------------------------------------------------------------------

    function test_switchExactIn_burnsFeeInTheTokenLeft() public {
        PairInfo memory info = _createPair(0.05 ether, 0.05 ether, false);
        uint256 amount = info.a.balanceOf(creator) / 2;
        uint256 supplyBefore = info.a.totalSupply();

        _approve(creator, info.keyX);
        vm.expectEmit(address(hook));
        emit DuelHook.SwitchFeeBurned(info.id, address(info.a), amount / 200);
        _switch(creator, info, address(info.a), amount);
        assertEq(supplyBefore - info.a.totalSupply(), amount / 200);

        // and the other way round
        uint256 amountD = info.d.balanceOf(creator) / 2;
        uint256 supplyDBefore = info.d.totalSupply();
        _switch(creator, info, address(info.d), amountD);
        assertEq(supplyDBefore - info.d.totalSupply(), amountD / 200);
    }

    /// @dev A swap a price limit stops short, in a branch whose fee is taken before the swap on the amount asked.
    function _expectPartialFill(address user, PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit)
        internal
    {
        _approve(user, key);
        uint256 value = zeroForOne && Currency.unwrap(key.currency0) == address(0) ? uint256(-amount) : 0;
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, abi.encodeWithSelector(DuelHook.PartialFill.selector)));
        vm.prank(user);
        swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_partialFill_ofAFeeTakenBeforeTheSwap_reverts() public {
        PairInfo memory info = _createPair(0.05 ether, 0.05 ether, false);
        vm.warp(block.timestamp + 10);
        // an exact-input buy its limit stops ten ticks down would pay 1.2% of the whole ETH asked
        _expectPartialFill(alice, info.keyA, true, -1 ether, TickMath.getSqrtPriceAtTick(_tick(info.keyA) - 10));
        // an exact-output sell asking for more ETH than the pool holds
        _expectPartialFill(alice, info.keyA, false, 10 ether, TickMath.MAX_SQRT_PRICE - 1);
        // an exact-input switch its limit stops short burns the switch fee on the whole amount
        bool zeroForOne = Currency.unwrap(info.keyX.currency0) == address(info.a);
        int24 tick = _tick(info.keyX);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? tick - 5 : tick + 5);
        _expectPartialFill(creator, info.keyX, zeroForOne, -int256(info.a.balanceOf(creator)), limit);
    }

    function test_partialFill_ofAFeeTakenOnWhatTraded_goesThrough() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        uint256 bought = _buy(alice, info.keyA, 0.1 ether);
        // an exact-input sell of more than the pool pays for: the fee is on the ETH paid out, the rest stays
        deal(address(info.a), alice, bought * 2);
        uint256 before = alice.balance;
        BalanceDelta delta = _swap(alice, info.keyA, false, -int256(bought * 2), 0);
        assertLt(uint256(int256(-delta.amount1())), bought * 2);
        assertGt(alice.balance, before);
        // an exact-output buy its limit stops short pays the fee on the ETH it spent
        int24 tick = _tick(info.keyD);
        _swapTo(bob, info.keyD, true, int256(100_000_000 ether), 1 ether, TickMath.getSqrtPriceAtTick(tick - 10));
        assertLe(_tick(info.keyD), tick - 9);
    }

    function test_switchExactOut_burnsFeeInTheTokenLeft() public {
        PairInfo memory info = _createPair(0.05 ether, 0.05 ether, false);
        uint256 supplyA = info.a.totalSupply();
        uint256 supplyD = info.d.totalSupply();
        bool aIsCurrency0 = hook.getPair(info.id).aIsCurrency0;

        // receive exactly 1M D, paying with A: 0.5% of what the creator paid is burned, as on an exact-input switch
        BalanceDelta delta = _swap(creator, info.keyX, aIsCurrency0, int256(1_000_000 ether), 0);
        int128 paidA = aIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 feeA = supplyA - info.a.totalSupply();
        assertGt(feeA, 0);
        assertApproxEqAbs(feeA, (uint256(int256(-paidA)) * 50) / 10_000, 1);

        // receive exactly 1M A, paying with D
        _swap(creator, info.keyX, !aIsCurrency0, int256(1_000_000 ether), 0);
        assertGt(supplyD - info.d.totalSupply(), 0);
    }

    function test_switch_tinyAmount_burnsNothing() public {
        PairInfo memory info = _createPair(0.05 ether, 0, false);
        uint256 supplyBefore = info.a.totalSupply();
        _switch(creator, info, address(info.a), 199);
        assertEq(info.a.totalSupply(), supplyBefore);
        // from 200 on, half a percent of the amount is a wei at least: it is burned
        _switch(creator, info, address(info.a), 200);
        assertEq(info.a.totalSupply(), supplyBefore - 1);
    }

    // ------------------------------------------------------------------
    // Claims and views
    // ------------------------------------------------------------------

    function test_claimCreatorFees_paysCreator() public {
        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 1 ether);

        uint256 before = creator.balance;
        vm.prank(bob); // anyone can trigger it, the creator gets paid
        uint256 amount = hook.claimCreatorFees(info.id);
        assertEq(amount, 0.003_96 ether);
        assertEq(creator.balance - before, 0.003_96 ether);
        assertEq(hook.getPair(info.id).creatorFees, 0);

        vm.expectRevert(DuelHook.NothingToClaim.selector);
        hook.claimCreatorFees(info.id);
    }

    function test_claimProtocolFees_paysTreasury() public {
        vm.expectRevert(DuelHook.NothingToClaim.selector);
        hook.claimProtocolFees();

        PairInfo memory info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        _buy(alice, info.keyA, 1 ether);

        uint256 before = treasury.balance;
        uint256 amount = hook.claimProtocolFees();
        assertEq(amount, 0.003_96 ether);
        assertEq(treasury.balance - before, 0.003_96 ether);
        assertEq(hook.protocolFees(), 0);
    }

    function test_gaugeBps_startsEvenAndFollowsTheCrossPool() public {
        PairInfo memory aFirst = _createPairOriented(true);
        PairInfo memory dFirst = _createPairOriented(false);
        assertEq(hook.gaugeBps(aFirst.id), 5000);
        assertEq(hook.gaugeBps(dFirst.id), 5000);

        vm.warp(block.timestamp + 10);
        _buy(alice, aFirst.keyA, 0.2 ether);
        _buy(alice, aFirst.keyD, 0.1 ether);
        _buy(alice, dFirst.keyA, 0.2 ether);
        _buy(alice, dFirst.keyD, 0.1 ether);
        // A received more ETH: A leads in both orientations
        assertGt(hook.gaugeBps(aFirst.id), 5000);
        assertGt(hook.gaugeBps(dFirst.id), 5000);
    }

    function test_poolKeys_useTheHookAndSpacings() public {
        PairInfo memory info = _createPair(0, 0, false);
        assertEq(address(info.keyA.hooks), address(hook));
        assertEq(Currency.unwrap(info.keyA.currency0), address(0));
        assertEq(Currency.unwrap(info.keyA.currency1), address(info.a));
        assertEq(info.keyA.tickSpacing, 200);
        assertEq(info.keyX.tickSpacing, 60);
        assertEq(info.keyX.fee, 0);
    }

    function _foreignKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}
