// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelToken} from "../../src/DuelToken.sol";

/// @dev Calls the router with extra ETH but cannot take the refund back.
contract NoReceive {
    function buy(DuelRouter router, PoolKey calldata key, uint256 amountIn) external payable {
        router.swapExactIn{value: msg.value}(key, true, amountIn, 0, address(this), block.timestamp);
    }

    function switchThroughEth(DuelRouter router, PoolKey calldata keyIn, PoolKey calldata keyOut, uint256 amountIn)
        external
        returns (uint256)
    {
        IERC20(Currency.unwrap(keyIn.currency1)).approve(address(router), amountIn);
        return router.swapThroughEth(keyIn, keyOut, amountIn, 1, address(this), block.timestamp);
    }
}

/// @dev A pool's hook that buys a little of its token back after every sale but its own: whatever a sale leaves, the
///      next one finds a little ETH to take, without end. The router must stop after `SALE_PASSES` swaps.
contract RefillHook {
    IPoolManager internal immutable manager;
    uint256 internal constant REFILL = 0.001 ether;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, int128) {
        // the hook's own swap skips its callbacks (v4-core's noSelfCall)
        if (!params.zeroForOne) {
            BalanceDelta bought = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -int256(REFILL), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            manager.settle{value: uint256(int256(-bought.amount0()))}();
            // as claims: the PoolManager holds none of the token before the router pays the sale in
            manager.mint(
                address(this), uint256(uint160(Currency.unwrap(key.currency1))), uint256(int256(bought.amount1()))
            );
        }
        return (IHooks.afterSwap.selector, 0);
    }

    receive() external payable {}
}

contract DuelRouterTest is DuelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PairInfo internal info;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    /// @dev What v4's liquidity router pays back of the ETH sent with a position.
    receive() external payable {}

    function setUp() public override {
        super.setUp();
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
    }

    function test_buy_sell_and_switch() public {
        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        assertEq(info.a.balanceOf(alice), bought);

        uint256 boughtD = router.swapExactIn{value: 0.5 ether}(info.keyD, true, 0.5 ether, 1, alice, block.timestamp);
        assertEq(info.d.balanceOf(alice), boughtD);

        // switch half of A into D through the cross pool
        info.a.approve(address(router), type(uint256).max);
        bool aIsCurrency0 = Currency.unwrap(info.keyX.currency0) == address(info.a);
        uint256 switched = router.swapExactIn(info.keyX, aIsCurrency0, bought / 2, 1, alice, block.timestamp);
        assertEq(info.d.balanceOf(alice), boughtD + switched);

        // sell the rest of A for ETH
        uint256 ethBefore = alice.balance;
        uint256 ethOut = router.swapExactIn(info.keyA, false, info.a.balanceOf(alice), 1, alice, block.timestamp);
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(info.a.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_buy_refundsUnusedEth() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        router.swapExactIn{value: 2 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        assertEq(before - alice.balance, 1 ether);
        assertEq(address(router).balance, 0);
    }

    /// @dev A trade that spends all the ETH it was sent, or that receives none, sends none back: a contract that cannot
    ///      take ETH buys with the exact amount, and switches through ETH.
    function test_aContractThatCannotTakeEth_tradesWhenNoneComesBack() public {
        NoReceive caller = new NoReceive();
        caller.buy{value: 1 ether}(router, info.keyA, 1 ether);
        uint256 held = info.a.balanceOf(address(caller));
        assertGt(held, 0);
        uint256 switched = caller.switchThroughEth(router, info.keyA, info.keyD, held / 2);
        assertEq(info.d.balanceOf(address(caller)), switched);
        assertEq(info.a.balanceOf(address(caller)), held - held / 2);
        assertEq(address(router).balance, 0);
    }

    function test_buy_forAnotherRecipient() public {
        vm.prank(alice);
        uint256 bought = router.swapExactIn{value: 0.1 ether}(info.keyA, true, 0.1 ether, 1, bob, block.timestamp);
        assertEq(info.a.balanceOf(bob), bought);
        assertEq(info.a.balanceOf(alice), 0);
    }

    function test_revertsWhenExpired() public {
        vm.prank(alice);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp - 1);
    }

    function test_revertsWithoutEnoughEth() public {
        vm.prank(alice);
        vm.expectRevert(DuelRouter.InsufficientValue.selector);
        router.swapExactIn{value: 0.5 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
    }

    function test_revertsBelowMinimumOut() public {
        vm.prank(alice);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, type(uint256).max, alice, block.timestamp);
    }

    function test_revertsWhenTheRefundIsRejected() public {
        NoReceive caller = new NoReceive();
        vm.expectRevert(DuelRouter.RefundFailed.selector);
        caller.buy{value: 2 ether}(router, info.keyA, 1 ether);
    }

    function test_aWeiForcedOntoTheRouter_stopsNoCaller() public {
        // the router takes no ETH of its own accord; a wei forced onto it (a self-destruct pays it all the same) stays
        // there, nobody's
        vm.deal(address(router), 1);
        NoReceive caller = new NoReceive();
        caller.buy{value: 1 ether}(router, info.keyA, 1 ether);
        assertGt(info.a.balanceOf(address(caller)), 0);
        assertEq(address(router).balance, 1);

        // a caller that takes ETH gets its own change back, and not that wei
        uint256 before = alice.balance;
        vm.prank(alice);
        router.swapExactIn{value: 2 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        assertEq(before - alice.balance, 1 ether);
        assertEq(address(router).balance, 1);

        // change of its own still fails a caller that cannot take it
        vm.expectRevert(DuelRouter.RefundFailed.selector);
        caller.buy{value: 2 ether}(router, info.keyA, 1 ether);
    }

    function test_switchThroughEth_sellsOneSideAndBuysTheOtherInOneGo() public {
        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // the same two trades one after the other, from the same state
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(alice);
        uint256 eth = router.swapExactIn(info.keyA, false, bought / 2, 1, alice, block.timestamp);
        uint256 twoTrades = router.swapExactIn{value: eth}(info.keyD, true, eth, 1, alice, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        // in one go: the same tokens, and no ETH in or out of the wallet or left in the router
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 switched = router.swapThroughEth(info.keyA, info.keyD, bought / 2, 1, alice, block.timestamp);
        assertEq(switched, twoTrades);
        assertEq(info.d.balanceOf(alice), switched);
        assertEq(info.a.balanceOf(alice), bought - bought / 2);
        assertEq(alice.balance, ethBefore);
        assertEq(address(router).balance, 0);
        assertEq(info.a.balanceOf(address(router)) + info.d.balanceOf(address(router)), 0);

        // and back, for another recipient: D's pool holds less ETH than all of it is worth (the realignment sent some
        // to the pot), so its first pass takes what it can pay for; the realignment refills it after, and the next
        // passes take the rest
        vm.startPrank(alice);
        info.d.approve(address(router), type(uint256).max);
        vm.recordLogs();
        uint256 back = router.swapThroughEth(info.keyD, info.keyA, switched, 1, bob, block.timestamp);
        vm.stopPrank();
        assertGt(_passes(vm.getRecordedLogs(), info.keyD), 1);
        assertEq(info.a.balanceOf(bob), back);
        assertEq(info.d.balanceOf(alice), 0);
        assertEq(info.d.balanceOf(address(router)), 0);
    }

    function test_switchThroughEth_revertsWhenExpired() public {
        vm.prank(alice);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.swapThroughEth(info.keyA, info.keyD, 1 ether, 1, alice, block.timestamp - 1);
    }

    function test_switchThroughEth_onlyBetweenEthPools() public {
        vm.startPrank(alice);
        vm.expectRevert(DuelRouter.NotAnEthPool.selector);
        router.swapThroughEth(info.keyX, info.keyD, 1 ether, 1, alice, block.timestamp);
        vm.expectRevert(DuelRouter.NotAnEthPool.selector);
        router.swapThroughEth(info.keyA, info.keyX, 1 ether, 1, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_switchThroughEth_revertsBelowMinimumOut() public {
        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.swapThroughEth(info.keyA, info.keyD, bought, type(uint256).max, alice, block.timestamp);
        // a sale too small to be worth any ETH buys nothing
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.swapThroughEth(info.keyA, info.keyD, 1, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @dev The minimum is a floor the switch may meet: exactly what it gives goes through.
    function test_switchThroughEth_meetsAMinimumOfExactlyWhatItGives() public {
        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        uint256 snapshot = vm.snapshotState();
        uint256 switched = router.swapThroughEth(info.keyA, info.keyD, bought / 2, 1, alice, block.timestamp);
        vm.revertToState(snapshot);
        assertEq(router.swapThroughEth(info.keyA, info.keyD, bought / 2, switched, alice, block.timestamp), switched);
        vm.stopPrank();
    }

    /// @dev Another token's pool, holding a little of it in a narrow range under its price.
    function _thinPool() internal returns (MockERC20 thin, PoolKey memory keyThin) {
        thin = new MockERC20("Thin", "THIN", 18);
        keyThin = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(thin)), 3000, 60, IHooks(address(0)));
        manager.initialize(keyThin, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidity = new PoolModifyLiquidityTest(manager);
        thin.mint(address(this), 1000 ether);
        thin.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity(
            keyThin,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: -60, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    function test_switchThroughEth_paysBackTheEthAPoolOutOfTokensLeaves() public {
        (MockERC20 thin, PoolKey memory keyThin) = _thinPool();

        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, alice, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        uint256 ethBefore = alice.balance;
        uint256 got = router.swapThroughEth(info.keyA, keyThin, bought, 1, alice, block.timestamp);
        vm.stopPrank();
        // all the pool had, and the ETH it could not take, back to the seller
        assertEq(thin.balanceOf(alice), got);
        assertLe(thin.balanceOf(address(manager)), 1); // a wei of rounding
        assertGt(alice.balance, ethBefore);
        assertEq(address(router).balance, 0);
    }

    /// @dev A buy bigger than its pool takes all the pool has in one swap (only a sale makes more), and pays the ETH
    ///      it did not spend back.
    function test_buy_biggerThanItsPool_takesItAllAndPaysTheRestBack() public {
        (MockERC20 thin, PoolKey memory keyThin) = _thinPool();
        uint256 before = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 got = router.swapExactIn{value: 1 ether}(keyThin, true, 1 ether, 1, alice, block.timestamp);
        assertEq(_passes(vm.getRecordedLogs(), keyThin), 1);
        assertEq(thin.balanceOf(alice), got);
        assertLe(thin.balanceOf(address(manager)), 1);
        assertGt(before - alice.balance, 0);
        assertLt(before - alice.balance, 1 ether);
        assertEq(address(router).balance, 0);
    }

    /// @dev A permit for the router, for `amount` of `token`, signed with `key` as its holder `holder`.
    function _permit(DuelToken token, uint256 key, address holder, uint256 amount, uint256 deadline)
        internal
        view
        returns (DuelRouter.Permit memory)
    {
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                holder,
                address(router),
                amount,
                token.nonces(holder),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), permitHash)));
        return DuelRouter.Permit(deadline, v, r, s);
    }

    /// @dev A trader with a key of its own, holding the A side bought with 1 ETH.
    function _holder() internal returns (address trader, uint256 key, uint256 held) {
        (trader, key) = makeAddrAndKey("trader");
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        held = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, trader, block.timestamp);
    }

    function test_sellWithPermit_inOneTransaction() public {
        (address trader, uint256 key, uint256 held) = _holder();
        uint256 sold = held / 2;
        assertEq(info.a.allowance(trader, address(router)), 0);

        // the same sale with an approval sent before, for comparison
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(trader);
        info.a.approve(address(router), sold);
        uint256 approved = router.swapExactIn(info.keyA, false, sold, 1, trader, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        uint256 ethBefore = trader.balance;
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, sold, block.timestamp);
        vm.prank(trader);
        uint256 ethOut = router.swapExactInWithPermit(info.keyA, false, sold, 1, trader, block.timestamp, permit);
        assertEq(ethOut, approved);
        assertEq(trader.balance - ethBefore, ethOut);
        assertEq(info.a.balanceOf(trader), held - sold);
        // the permit was for exactly the sale, and is spent
        assertEq(info.a.allowance(trader, address(router)), 0);
        assertEq(info.a.nonces(trader), 1);
    }

    function test_sellWithPermit_goesThroughWhenItsPermitWasSentAhead() public {
        (address trader, uint256 key, uint256 held) = _holder();
        uint256 sold = held / 2;
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, sold, block.timestamp);
        // anyone may send a permit seen in the mempool first: it sets the allowance the sale needs all the same
        vm.prank(bob);
        info.a.permit(trader, address(router), sold, permit.deadline, permit.v, permit.r, permit.s);
        vm.prank(trader);
        router.swapExactInWithPermit(info.keyA, false, sold, 1, trader, block.timestamp, permit);
        assertEq(info.a.balanceOf(trader), held - sold);
        assertEq(info.a.allowance(trader, address(router)), 0);
    }

    function test_sellWithPermit_revertsWithoutAPermitThatApprovesIt() public {
        (address trader, uint256 key, uint256 held) = _holder();
        uint256 sold = held / 2;
        (, uint256 otherKey) = makeAddrAndKey("other");
        // signed by someone else, for another amount than the sale's (the router asks for exactly that), or past its own
        // deadline: no allowance, no sale
        DuelRouter.Permit[3] memory refused = [
            _permit(info.a, otherKey, trader, sold, block.timestamp),
            _permit(info.a, key, trader, sold / 2, block.timestamp),
            _permit(info.a, key, trader, sold, block.timestamp - 1)
        ];
        for (uint256 i; i < refused.length; i++) {
            vm.prank(trader);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, sold)
            );
            router.swapExactInWithPermit(info.keyA, false, sold, 1, trader, block.timestamp, refused[i]);
        }
        assertEq(info.a.nonces(trader), 0);
    }

    function test_sellWithPermit_onlyForATokenAndBeforeTheTradesDeadline() public {
        (address trader, uint256 key, uint256 held) = _holder();
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, held, block.timestamp);
        vm.startPrank(trader);
        // ETH is paid with the call: a buy has nothing to permit
        vm.expectRevert(DuelRouter.NotAToken.selector);
        router.swapExactInWithPermit(info.keyA, true, 1 ether, 1, trader, block.timestamp, permit);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.swapExactInWithPermit(info.keyA, false, held, 1, trader, block.timestamp - 1, permit);
        vm.stopPrank();
    }

    function test_switchWithPermit_acrossAndThroughEth() public {
        (address trader, uint256 key, uint256 held) = _holder();
        // across: the token left is the cross pool's input
        uint256 first = held / 4;
        bool aIsCurrency0 = Currency.unwrap(info.keyX.currency0) == address(info.a);
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, first, block.timestamp);
        vm.prank(trader);
        uint256 across =
            router.swapExactInWithPermit(info.keyX, aIsCurrency0, first, 1, trader, block.timestamp, permit);
        assertEq(info.d.balanceOf(trader), across);
        assertEq(info.a.allowance(trader, address(router)), 0);

        // through ETH: the same as with an approval sent before
        uint256 second = held / 4;
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(trader);
        info.a.approve(address(router), second);
        uint256 approved = router.swapThroughEth(info.keyA, info.keyD, second, 1, trader, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        permit = _permit(info.a, key, trader, second, block.timestamp);
        vm.startPrank(trader);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.swapThroughEthWithPermit(info.keyA, info.keyD, second, 1, trader, block.timestamp - 1, permit);
        vm.expectRevert(DuelRouter.NotAnEthPool.selector);
        router.swapThroughEthWithPermit(info.keyX, info.keyD, second, 1, trader, block.timestamp, permit);
        uint256 through =
            router.swapThroughEthWithPermit(info.keyA, info.keyD, second, 1, trader, block.timestamp, permit);
        vm.stopPrank();
        assertEq(through, approved);
        assertEq(info.d.balanceOf(trader), across + through);
        assertEq(info.a.balanceOf(trader), held - first - second);
        assertEq(info.a.allowance(trader, address(router)), 0);
    }

    function test_sellWithPermit_partialFillLeavesTheRestApprovedForTheCallerAlone() public {
        (address trader, uint256 key, uint256 held) = _holder();
        // all of it back: the ETH pool stops at its launch price, and its passes leave the dust the realignment does
        // not take
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, held, block.timestamp);
        vm.prank(trader);
        router.swapExactInWithPermit(info.keyA, false, held, 1, trader, block.timestamp, permit);
        uint256 left = info.a.balanceOf(trader);
        assertGt(left, 0);
        assertLt(left, held / 10_000);
        // what the sale did not take stays approved: the permit's deadline bounded when it could be used, not this
        vm.warp(block.timestamp + 1 days);
        assertEq(info.a.allowance(trader, address(router)), left);
        // a buyer gives the pool ETH again
        _buy(alice, info.keyA, 0.1 ether);
        // nobody else can spend it through the router, which takes tokens from its caller alone
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, left)
        );
        router.swapExactIn(info.keyA, false, left, 1, bob, block.timestamp);
        assertEq(info.a.balanceOf(trader), left);
        // and the next permit replaces it
        permit = _permit(info.a, key, trader, left / 2, block.timestamp);
        vm.prank(trader);
        router.swapExactInWithPermit(info.keyA, false, left / 2, 1, trader, block.timestamp, permit);
        assertEq(info.a.allowance(trader, address(router)), 0);
    }

    function test_switchThroughEthWithPermit_partialFillLeavesTheRestApproved() public {
        (address trader, uint256 key, uint256 held) = _holder();
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, held, block.timestamp);
        vm.prank(trader);
        router.swapThroughEthWithPermit(info.keyA, info.keyD, held, 1, trader, block.timestamp, permit);
        uint256 left = info.a.balanceOf(trader);
        assertGt(left, 0);
        assertEq(info.a.allowance(trader, address(router)), left);
        assertGt(info.d.balanceOf(trader), 0);
    }

    // ------------------------------------------------------------------
    // A sale bigger than its ETH pool can buy in one swap
    // ------------------------------------------------------------------

    /// @dev The router's swaps in `key`'s pool, among `logs`.
    function _passes(Vm.Log[] memory logs, PoolKey memory key) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(router))))
            ) ++n;
        }
    }

    /// @dev The ETH the hook holds against everything it owes for `pairId`.
    function _assertBooksExact(uint256 pairId) internal view {
        DuelHook.Pair memory p = hook.getPair(pairId);
        assertEq(manager.balanceOf(address(hook), 0), hook.protocolFees() + p.pot + p.creatorFees);
    }

    /// @dev Alice alone buys A with `eth`, and approves the router for all of it.
    function _loneBuyer(uint256 eth) internal returns (uint256 held) {
        vm.startPrank(alice);
        held = router.swapExactIn{value: eth}(info.keyA, true, eth, 1, alice, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_sell_aLoneBuyerLeavesInOneTransaction() public {
        uint256 held = _loneBuyer(1 ether);
        // in one swap, the pool runs out of ETH at its launch price: the realignment after the purchase sold into it
        // tokens taken from the pool between the sides
        uint256 snapshot = vm.snapshotState();
        uint256 oneSwap = _sell(alice, info.keyA, held);
        uint256 leftByOneSwap = info.a.balanceOf(alice);
        assertGt(leftByOneSwap, held / 1000);
        vm.revertToState(snapshot);

        // the router sells again what the realignment after each pass lets the pool take
        uint256 before = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = router.swapExactIn(info.keyA, false, held, 1, alice, block.timestamp);
        uint256 passes = _passes(vm.getRecordedLogs(), info.keyA);
        assertGt(passes, 1);
        assertLe(passes, router.SALE_PASSES());
        assertEq(alice.balance - before, out);
        assertGt(out, oneSwap);
        // all but the dust the realignment leaves, under its threshold
        assertLt(info.a.balanceOf(alice), held / 10_000);
        assertEq(address(router).balance, 0);
        assertEq(info.a.balanceOf(address(router)), 0);
        _assertBooksExact(info.id);
    }

    function test_sell_inOnePassWhenThePoolTakesItAll() public {
        uint256 held = _loneBuyer(1 ether);
        vm.recordLogs();
        vm.prank(alice);
        router.swapExactIn(info.keyA, false, held / 2, 1, alice, block.timestamp);
        assertEq(_passes(vm.getRecordedLogs(), info.keyA), 1);
        assertEq(info.a.balanceOf(alice), held - held / 2);
        // a purchase and a switch make one swap too
        vm.recordLogs();
        vm.prank(alice);
        router.swapExactIn{value: 0.1 ether}(info.keyA, true, 0.1 ether, 1, alice, block.timestamp);
        assertEq(_passes(vm.getRecordedLogs(), info.keyA), 1);
    }

    function test_sell_passesAddUpAsSeparateSales_feesAndAll() public {
        uint256 held = _loneBuyer(1 ether);
        // the same sale as separate single swaps: all that is left each time, until the pool takes no more
        uint256 snapshot = vm.snapshotState();
        uint256 separately;
        for (uint256 i; i < router.SALE_PASSES() && info.a.balanceOf(alice) > 0; ++i) {
            (uint160 price,,,) = manager.getSlot0(info.keyA.toId());
            if (price >= TickMath.MAX_SQRT_PRICE - 1) break;
            uint256 got = _sell(alice, info.keyA, info.a.balanceOf(alice));
            if (got == 0) break;
            separately += got;
        }
        uint256 leftSeparately = info.a.balanceOf(alice);
        DuelHook.Pair memory paidSeparately = hook.getPair(info.id);
        uint256 protocolSeparately = hook.protocolFees();
        vm.revertToState(snapshot);

        vm.prank(alice);
        uint256 together = router.swapExactIn(info.keyA, false, held, 1, alice, block.timestamp);
        // the same ETH, the same tokens left, the same fees to the creator, the protocol and the pot
        assertEq(together, separately);
        assertEq(info.a.balanceOf(alice), leftSeparately);
        DuelHook.Pair memory paid = hook.getPair(info.id);
        assertEq(paid.creatorFees, paidSeparately.creatorFees);
        assertEq(paid.pot, paidSeparately.pot);
        assertEq(hook.protocolFees(), protocolSeparately);
        _assertBooksExact(info.id);
    }

    function test_sell_theMinimumCountsEveryPass() public {
        uint256 held = _loneBuyer(1 ether);
        uint256 snapshot = vm.snapshotState();
        uint256 oneSwap = _sell(alice, info.keyA, held);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 all = router.swapExactIn(info.keyA, false, held, 1, alice, block.timestamp);
        vm.revertToState(snapshot);
        assertGt(all, oneSwap);

        // a minimum above what one swap gives, met by the passes together
        vm.prank(alice);
        assertEq(router.swapExactIn(info.keyA, false, held, oneSwap + 1, alice, block.timestamp), all);
        vm.revertToState(snapshot);
        // and one above them all: nothing sold
        vm.prank(alice);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.swapExactIn(info.keyA, false, held, all + 1, alice, block.timestamp);
        assertEq(info.a.balanceOf(alice), held);
    }

    function test_sell_intoAPoolSoldOut_stopsWithoutAnotherSwap() public {
        PairInfo memory quiet = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        // tokens that never came out of the ETH pool: it has no ETH to pay for them, and the sale leaves its price at
        // the swaps' limit
        deal(address(quiet.a), alice, 1_000_000 ether);
        vm.startPrank(alice);
        quiet.a.approve(address(router), type(uint256).max);
        vm.recordLogs();
        assertEq(router.swapExactIn(quiet.keyA, false, 1_000_000 ether, 0, alice, block.timestamp), 0);
        assertEq(_passes(vm.getRecordedLogs(), quiet.keyA), 1);
        (uint160 price,,,) = manager.getSlot0(quiet.keyA.toId());
        assertEq(price, TickMath.MAX_SQRT_PRICE - 1);
        // the pool at the limit: the next sale makes no swap at all (one would revert), and sells nothing
        vm.recordLogs();
        assertEq(router.swapExactIn(quiet.keyA, false, 1_000_000 ether, 0, alice, block.timestamp), 0);
        assertEq(_passes(vm.getRecordedLogs(), quiet.keyA), 0);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.swapExactIn(quiet.keyA, false, 1_000_000 ether, 1, alice, block.timestamp);
        vm.stopPrank();
        assertEq(quiet.a.balanceOf(alice), 1_000_000 ether);
        // a buy takes the pool down from there, through the router like anywhere else
        vm.prank(bob);
        uint256 bought = router.swapExactIn{value: 0.01 ether}(quiet.keyA, true, 0.01 ether, 1, bob, block.timestamp);
        assertEq(quiet.a.balanceOf(bob), bought);
        assertLt(_tick(quiet.keyA), hook.getPair(quiet.id).startTick);
    }

    function test_sell_passesAreBounded_whateverRefillsThePool() public {
        // a pool of ETH alone above its price, whose hook buys a little back after every sale, forever
        MockERC20 token = new MockERC20("Endless", "END", 18);
        address hookAddress = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0xbeef) << 144));
        deployCodeTo("DuelRouter.t.sol:RefillHook", abi.encode(address(manager)), hookAddress);
        vm.deal(hookAddress, 10 ether);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(hookAddress));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidity = new PoolModifyLiquidityTest(manager);
        liquidity.modifyLiquidity{value: 1 ether}(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), ""
        );

        token.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        uint256 out = router.swapExactIn(key, false, 1_000_000 ether, 0, alice, block.timestamp);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        // eight swaps (SALE_PASSES), and no more
        assertEq(_passes(vm.getRecordedLogs(), key), 8);
        assertGt(out, 0);
        assertGt(token.balanceOf(alice), 0);
        emit log_named_uint("gas of a sale making every pass", gasUsed);
    }

    function test_sellWithPermit_aWholeExitLeavesOnlyTheDustApproved() public {
        (address trader, uint256 key, uint256 held) = _holder();
        DuelRouter.Permit memory permit = _permit(info.a, key, trader, held, block.timestamp);
        vm.recordLogs();
        vm.prank(trader);
        router.swapExactInWithPermit(info.keyA, false, held, 1, trader, block.timestamp, permit);
        assertGt(_passes(vm.getRecordedLogs(), info.keyA), 1);
        uint256 left = info.a.balanceOf(trader);
        assertLt(left, held / 10_000);
        assertEq(info.a.allowance(trader, address(router)), left);
    }

    function test_switchThroughEth_aWholeSideSoldInPasses() public {
        uint256 held = _loneBuyer(1 ether);
        uint256 snapshot = vm.snapshotState();
        // in one swap, the sale stops at the launch price
        uint256 oneSwap = _sell(alice, info.keyA, held);
        vm.revertToState(snapshot);
        assertGt(oneSwap, 0);

        vm.recordLogs();
        vm.prank(alice);
        uint256 got = router.swapThroughEth(info.keyA, info.keyD, held, 1, alice, block.timestamp);
        assertGt(_passes(vm.getRecordedLogs(), info.keyA), 1);
        assertEq(info.d.balanceOf(alice), got);
        assertLt(info.a.balanceOf(alice), held / 10_000);
        assertEq(address(router).balance, 0);
        _assertBooksExact(info.id);
    }

    function test_sell_aWholeExitStaysWithinItsGas() public {
        uint256 held = _loneBuyer(10 ether);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        router.swapExactIn(info.keyA, false, held, 1, alice, block.timestamp);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("gas of a whole exit", gasUsed);
        assertLt(gasUsed, 2_500_000);
    }

    /// @dev Alice buys both sides, sells all of A, then sells D: the sale of D through `swapExactIn` leaves what D's pool
    ///      cannot buy back, the ETH paying for it in A's pool (testnet's duel #1, in small).
    function _bothSidesThenA() internal returns (uint256 heldD) {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        info.a.approve(address(router), type(uint256).max);
        info.d.approve(address(router), type(uint256).max);
        router.swapExactIn{value: 0.05 ether}(info.keyA, true, 0.05 ether, 1, alice, block.timestamp);
        router.swapExactIn{value: 0.05 ether}(info.keyD, true, 0.05 ether, 1, alice, block.timestamp);
        router.swapExactIn(info.keyA, false, info.a.balanceOf(alice), 0, alice, block.timestamp);
        vm.stopPrank();
        heldD = info.d.balanceOf(alice);
    }

    function test_sell_whatItsPoolCannotBuyBack_throughTheOtherSide() public {
        uint256 held = _bothSidesThenA();
        // through `swapExactIn`, D's pool runs out of ETH at its launch price, and the realignment can no longer refill
        // it: A's pool, sold off, has too little ETH left to pay for a cycle
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 alone = router.swapExactIn(info.keyD, false, held, 0, alice, block.timestamp);
        uint256 residue = info.d.balanceOf(alice);
        assertGt(residue, 0);
        assertEq(_sqrtPrice(info.keyD), TickMath.MAX_SQRT_PRICE - 1);
        vm.revertToState(snapshot);

        // `sell` takes that rest through the pool between the sides into A's pool, where its ETH is: all of it sold
        uint256 before = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = router.sell(info.keyD, info.keyX, info.keyA, held, 1, alice, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_passes(logs, info.keyX), 1);
        assertGe(_passes(logs, info.keyA), 1);
        assertEq(alice.balance - before, out);
        assertGt(out, alone);
        assertEq(info.d.balanceOf(alice), 0);
        assertEq(info.a.balanceOf(alice), 0);
        assertEq(address(router).balance, 0);
        assertEq(info.d.balanceOf(address(router)), 0);
        assertEq(info.a.balanceOf(address(router)), 0);
        _assertBooksExact(info.id);

        // the residue alone, sold after `swapExactIn` left it: the same way out, for what it is worth
        vm.revertToState(snapshot);
        vm.startPrank(alice);
        router.swapExactIn(info.keyD, false, held, 0, alice, block.timestamp);
        assertGt(router.sell(info.keyD, info.keyX, info.keyA, residue, 1, alice, block.timestamp), 0);
        vm.stopPrank();
        assertEq(info.d.balanceOf(alice), 0);
        _assertBooksExact(info.id);
    }

    function test_sell_whenItsPoolTakesItAll_asSwapExactIn() public {
        uint256 held = _loneBuyer(1 ether);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 single = router.swapExactIn(info.keyA, false, held, 1, alice, block.timestamp);
        uint256 left = info.a.balanceOf(alice);
        vm.revertToState(snapshot);

        // a whole exit its pool pays for after its passes, all but the dust: the same ETH, then the dust across
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = router.sell(info.keyA, info.keyX, info.keyD, held / 2, 1, alice, block.timestamp);
        assertEq(_passes(vm.getRecordedLogs(), info.keyX), 0);
        vm.revertToState(snapshot);
        vm.prank(alice);
        assertEq(router.swapExactIn(info.keyA, false, held / 2, 1, alice, block.timestamp), out);
        vm.revertToState(snapshot);
        vm.prank(alice);
        assertGe(router.sell(info.keyA, info.keyX, info.keyD, held, 1, alice, block.timestamp), single);
        // the dust `swapExactIn` leaves, gone too: the pool between the sides takes whatever is left
        assertGt(left, 0);
        assertEq(info.a.balanceOf(alice), 0);
        _assertBooksExact(info.id);
    }

    function test_sell_paysBackTheOtherSideItsPoolCannotBuy() public {
        PairInfo memory quiet = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        // tokens that never came out of an ETH pool, and two ETH pools without ETH: nothing pays for them in ETH, and
        // what the pool between the sides gave for them comes back as the other side's token
        deal(address(quiet.a), alice, 1000 ether);
        vm.startPrank(alice);
        quiet.a.approve(address(router), type(uint256).max);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.sell(quiet.keyA, quiet.keyX, quiet.keyD, 1000 ether, 1, alice, block.timestamp);
        assertEq(router.sell(quiet.keyA, quiet.keyX, quiet.keyD, 1000 ether, 0, alice, block.timestamp), 0);
        vm.stopPrank();
        assertEq(quiet.a.balanceOf(alice), 0);
        // less the switch fee, burned
        assertGt(quiet.d.balanceOf(alice), 0);
        assertLt(quiet.d.balanceOf(alice), 1000 ether);
        assertEq(quiet.d.balanceOf(address(router)), 0);
    }

    function test_sell_onlyBetweenTwoEthPoolsAndThePoolBetweenThem() public {
        uint256 held = _loneBuyer(0.1 ether);
        PairInfo memory other = _createPair(0, 0, false);
        vm.startPrank(alice);
        vm.expectRevert(DuelRouter.NotAnEthPool.selector);
        router.sell(info.keyX, info.keyA, info.keyD, held, 0, alice, block.timestamp);
        vm.expectRevert(DuelRouter.NotAnEthPool.selector);
        router.sell(info.keyA, info.keyX, info.keyX, held, 0, alice, block.timestamp);
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sell(info.keyA, info.keyD, info.keyD, held, 0, alice, block.timestamp);
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sell(info.keyA, info.keyX, info.keyA, held, 0, alice, block.timestamp);
        // another pair's pool between its sides
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sell(info.keyA, other.keyX, info.keyD, held, 0, alice, block.timestamp);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.sell(info.keyA, info.keyX, info.keyD, held, 0, alice, block.timestamp - 1);
        vm.stopPrank();
        assertEq(info.a.balanceOf(alice), held);
    }

    function test_sell_theMinimumCountsBothWays() public {
        uint256 held = _bothSidesThenA();
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 all = router.sell(info.keyD, info.keyX, info.keyA, held, 1, alice, block.timestamp);
        vm.revertToState(snapshot);
        vm.prank(alice);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.sell(info.keyD, info.keyX, info.keyA, held, all + 1, alice, block.timestamp);
        assertEq(info.d.balanceOf(alice), held);
        vm.prank(alice);
        assertEq(router.sell(info.keyD, info.keyX, info.keyA, held, all, alice, block.timestamp), all);
    }

    function test_sellWithPermit_aWholeExitThroughTheOtherSide() public {
        (address trader, uint256 key,) = _holder();
        // the trader holds both sides, and sells A off first: D is left, more than its pool can buy back
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        router.swapExactIn{value: 0.05 ether}(info.keyD, true, 0.05 ether, 1, trader, block.timestamp);
        info.a.approve(address(router), type(uint256).max);
        router.swapExactIn(info.keyA, false, info.a.balanceOf(trader), 0, trader, block.timestamp);
        vm.stopPrank();
        uint256 held = info.d.balanceOf(trader);
        DuelRouter.Permit memory permit = _permit(info.d, key, trader, held, block.timestamp);
        vm.prank(trader);
        uint256 out = router.sellWithPermit(info.keyD, info.keyX, info.keyA, held, 1, trader, block.timestamp, permit);
        assertGt(out, 0);
        assertEq(info.d.balanceOf(trader), 0);
        assertEq(info.d.allowance(trader, address(router)), 0);
        // and checked before its permit is used
        DuelRouter.Permit memory unused = _permit(info.d, key, trader, 1, block.timestamp);
        vm.prank(trader);
        vm.expectRevert(DuelRouter.NotACrossPool.selector);
        router.sellWithPermit(info.keyD, info.keyA, info.keyA, 1, 0, trader, block.timestamp, unused);
        vm.prank(trader);
        vm.expectRevert(DuelRouter.Expired.selector);
        router.sellWithPermit(info.keyD, info.keyX, info.keyA, 1, 0, trader, block.timestamp - 1, unused);
    }

    function test_sell_throughTheOtherSide_aWholeExitStaysWithinItsGas() public {
        uint256 held = _bothSidesThenA();
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        router.sell(info.keyD, info.keyX, info.keyA, held, 1, alice, block.timestamp);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("gas of a whole exit through the other side", gasUsed);
        assertLt(gasUsed, 4_000_000);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(DuelRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }
}
