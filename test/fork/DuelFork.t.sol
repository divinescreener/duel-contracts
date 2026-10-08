// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelHook} from "../../src/DuelHook.sol";
import {DuelFactory} from "../../src/DuelFactory.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelLens} from "../../src/DuelLens.sol";
import {DuelSimulator} from "../../src/DuelSimulator.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelDeploy} from "../../script/DuelDeploy.sol";

/// @dev Universal Router 2.1.2 as deployed on Robinhood Chain, with the errors of the V4Router it embeds.
interface IUniversalRouter {
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);
    error V4TooLittleReceivedPerHopSingle(uint256 minPrice, uint256 price);

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IV4Quoter {
    /// @dev A quote whose simulated swap reverted: that revert, wrapped.
    error UnexpectedRevertBytes(bytes revertData);
    /// @dev A simulated swap that did not consume all of its specified amount.
    error NotEnoughLiquidity(PoolId poolId);

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}

/// @notice End-to-end tests against the live Uniswap V4 deployment of Robinhood Chain.
/// @dev Needs an RPC: `ROBINHOOD_RPC_URL` (defaults to the public endpoint). Run with `forge test --match-path
///      "test/fork/*"`.
contract DuelForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Layout of V4Router's exact-input single-hop parameters in the periphery version the router embeds.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev Its exact-output single-hop parameters: the price bound is still a minimum, of the output over the input.
    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev What a swap through the Universal Router left in its logs: the pool's side of it, before the hook's cut (the
    ///      PoolManager's Swap event), the hook's cut (FeeTaken) and what the realignment after it captured for the pot.
    struct Trade {
        int256 eth; // the ETH the pool paid out (positive) or took in (negative)
        int256 tokens;
        uint160 sqrtPriceX96; // where the swap left the pool, before the realignment moved it
        uint128 liquidity; // the pool's liquidity at that price
        uint256 fee;
        uint256 tax;
        uint256 captured;
    }

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniversalRouter internal constant UNIVERSAL_ROUTER = IUniversalRouter(0x204FAca1764B154221e35c0d20aBb3c525710498);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);

    uint256 internal constant SWEEP = 0x04;
    uint256 internal constant V4_SWAP = 0x10;
    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;

    DuelHook internal hook;
    DuelFactory internal factory;
    DuelRouter internal router;
    DuelLens internal lens;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal pairId;
    DuelToken internal tokenA;
    DuelToken internal tokenD;
    PoolKey internal keyA;
    PoolKey internal keyD;
    PoolKey internal keyX;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        assertEq(block.chainid, 4663);

        // same path as the deploy script: the hook and the factory in one bootstrap this test contract creates
        (hook, factory) = DuelDeploy.deployCore(POOL_MANAGER, owner, DuelDeploy.defaultConfig(treasury), address(this));
        router = new DuelRouter(POOL_MANAGER);
        lens = new DuelLens(hook);
        // born paused, for its owner's first pair: the owner opens the launches
        assertTrue(factory.paused());
        vm.prank(owner);
        factory.setPaused(false);

        vm.deal(creator, 10 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        // ETH someone left in the live router goes to the next sweep: an exact-output buy's change is all it sends here
        vm.deal(address(UNIVERSAL_ROUTER), 0);

        DuelFactory.CreateParams memory params = DuelFactory.CreateParams({
            nameA: "Cats",
            symbolA: "CATS",
            nameD: "Dogs",
            symbolD: "DOGS",
            metadataURI: "ipfs://duel-fork",
            buyA: 0.02 ether,
            buyD: 0.02 ether,
            supporter: false,
            category: 5,
            config: factory.configHash()
        });
        vm.prank(creator);
        // the launch fee and both launch buys
        pairId = factory.createPair{value: 0.05 ether}(params);
        DuelHook.Pair memory p = hook.getPair(pairId);
        tokenA = DuelToken(p.tokenA);
        tokenD = DuelToken(p.tokenD);
        (keyA, keyD, keyX) = hook.poolKeys(pairId);
        // leave the anti-snipe window
        vm.warp(block.timestamp + 10);
    }

    function test_fork_hookAddressCarriesItsFlags() public view {
        // the PoolManager's code, as the deploy script expects it there
        assertEq(address(POOL_MANAGER).codehash, DuelDeploy.ROBINHOOD_POOL_MANAGER_CODEHASH);
        assertEq(uint160(address(hook)) & 0x3FFF, DuelDeploy.HOOK_FLAGS);
        assertEq(address(hook.poolManager()), address(POOL_MANAGER));
        assertEq(hook.factory(), address(factory));
    }

    function test_fork_pairLivesInTheLivePoolManager() public view {
        (uint160 sqrtA, int24 tickA,,) = POOL_MANAGER.getSlot0(keyA.toId());
        (uint160 sqrtX,,,) = POOL_MANAGER.getSlot0(keyX.toId());
        assertGt(sqrtA, 0);
        assertGt(sqrtX, 0);
        // the creator's launch buy moved side A off its launch tick
        assertLt(tickA, hook.getPair(pairId).startTick);
        assertGt(tokenA.balanceOf(creator), 0);
        assertGt(tokenD.balanceOf(creator), 0);
        assertApproxEqAbs(lens.getPair(pairId).gaugeBps, 5000, 5);
    }

    function test_fork_universalRouterBuysSellsAndSwitches() public {
        uint256 protocolBefore = hook.protocolFees();

        // join side A with 1 ETH through the Universal Router
        _urSwap(alice, keyA, true, 1 ether, 1 ether);
        uint256 boughtA = tokenA.balanceOf(alice);
        assertGt(boughtA, 0);
        assertEq(hook.protocolFees() - protocolBefore, 0.003_96 ether);
        assertGt(lens.getPair(pairId).gaugeBps, 5000);

        // switch half of it to side D, paying through Permit2
        _permit(alice, address(tokenA));
        bool aIsCurrency0 = Currency.unwrap(keyX.currency0) == address(tokenA);
        uint256 supplyA = tokenA.totalSupply();
        _urSwap(alice, keyX, aIsCurrency0, boughtA / 2, 0);
        assertGt(tokenD.balanceOf(alice), 0);
        assertEq(supplyA - tokenA.totalSupply(), (boughtA / 2) * 50 / 10_000);

        // sell the rest of side A for ETH
        uint256 ethBefore = alice.balance;
        _urSwap(alice, keyA, false, tokenA.balanceOf(alice), 0);
        assertGt(alice.balance, ethBefore);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    /// @notice A sale bigger than what the pool pays for, in the Universal Router's one exact-input swap where Duel's
    ///         router sells again after each realignment: the pool takes what all its ETH pays for, down to its launch
    ///         price, the hook its fee on that ETH, and the rest stays in the seller's wallet.
    function test_fork_universalRouterSellsWhatThePoolPaysForAndLeavesTheRest() public {
        (uint256 held, uint256 takes, uint256 pays) = _aliceHoldsMoreAThanItsPoolPaysFor();
        vm.startPrank(alice);
        tokenA.approve(address(PERMIT2), held);
        PERMIT2.approve(address(tokenA), address(UNIVERSAL_ROUTER), uint160(held), uint48(block.timestamp + 1 days));
        vm.stopPrank();

        uint256 snapshot = vm.snapshotState();
        DuelHook.Pair memory pairBefore = hook.getPair(pairId);
        uint256 protocolBefore = hook.protocolFees();
        uint256 claimsBefore = POOL_MANAGER.balanceOf(address(hook), 0);
        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        _urSwap(alice, keyA, false, held, 0);
        Trade memory sale = _trade(vm.getRecordedLogs());

        // The router swaps to the far price limit, and the PoolManager does not revert an exact-input swap that stops
        // short of its amount: through the pool's position up to its launch price, where its ETH runs out, then on
        // through ticks without liquidity, which take nothing.
        assertEq(sale.sqrtPriceX96, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(sale.liquidity, 0);
        assertEq(sale.tokens, -int256(takes));
        assertEq(sale.eth, int256(pays));
        // The hook charges a sale after the swap, on the ETH paid out. Its PartialFill rule binds only the swaps whose
        // fee it takes before, on the amount asked (exact-input buys, exact-output sales): this one may fill in part.
        uint256 fee = (pays * 120) / 10_000;
        assertEq(sale.fee, fee);
        assertEq(sale.tax, 0);
        assertEq(alice.balance - ethBefore, pays - fee);
        // SETTLE_ALL pays the router's debt, what the swap took: Permit2 pulls only that from alice. The rest never left
        // her wallet, and her allowance still covers it.
        assertEq(tokenA.balanceOf(alice), held - takes);
        (uint160 allowance,,) = PERMIT2.allowance(alice, address(tokenA), address(UNIVERSAL_ROUTER));
        assertEq(allowance, held - takes);
        assertEq(tokenA.balanceOf(address(UNIVERSAL_ROUTER)), 0);

        // The books: 33% of the fee to the protocol, 33% to the creator, 34% to the pot, which also gets what the
        // realignment after the sale captured; the hook holds all of it as claims in the PoolManager.
        DuelHook.Pair memory pairAfter = hook.getPair(pairId);
        assertEq(hook.protocolFees() - protocolBefore, fee * 3300 / 10_000);
        assertEq(pairAfter.creatorFees - pairBefore.creatorFees, fee - fee * 3300 / 10_000 - fee * 3400 / 10_000);
        assertGt(sale.captured, 0);
        assertEq(pairAfter.pot - pairBefore.pot, fee * 3400 / 10_000 + sale.captured);
        assertEq(POOL_MANAGER.balanceOf(address(hook), 0) - claimsBefore, fee + sale.captured);
        assertEq(pairAfter.volume - pairBefore.volume, pays);

        // That realignment bought A from the pool at its launch price: the rest sells in a second transaction, and both
        // give alice, to the wei, what Duel's router gives in one, selling again after the realignment.
        _urSwap(alice, keyA, false, held - takes, 0);
        assertEq(tokenA.balanceOf(alice), 0);
        uint256 twoSales = alice.balance - ethBefore;
        vm.revertToState(snapshot);
        vm.startPrank(alice);
        tokenA.approve(address(router), held);
        assertEq(router.swapExactIn(keyA, false, held, 0, alice, block.timestamp), twoSales);
        vm.stopPrank();
    }

    /// @notice The same sale with a minimum: the router checks it against the ETH its one swap gave. A minimum of what
    ///         the whole amount is worth fails, and so does a price per hop at the very price the pool paid, which the
    ///         router divides by the amount asked; but a usual slippage on the whole lets the partial sale through. The
    ///         live quoter does not quote the sale at all: its swap must take the whole amount.
    function test_fork_universalRouterChecksATooBigSaleOnWhatItSold() public {
        (uint256 held, uint256 takes, uint256 pays) = _aliceHoldsMoreAThanItsPoolPaysFor();
        _permit(alice, address(tokenA));

        vm.expectRevert(
            abi.encodeWithSelector(
                IV4Quoter.UnexpectedRevertBytes.selector,
                abi.encodeWithSelector(IV4Quoter.NotEnoughLiquidity.selector, keyA.toId())
            )
        );
        QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(keyA, false, uint128(held), ""));

        // what all of it is worth: Duel's router sells it all, again after each realignment
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(alice);
        tokenA.approve(address(router), held);
        uint256 worth = router.swapExactIn(keyA, false, held, 0, alice, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        uint256 gives = pays - (pays * 120) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(IUniversalRouter.V4TooLittleReceived.selector, worth, gives));
        _urSwap(alice, keyA, false, held, worth, 0, 0);

        uint256 price = gives * 1e36 / takes;
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.V4TooLittleReceivedPerHopSingle.selector, price, gives * 1e36 / held
            )
        );
        _urSwap(alice, keyA, false, held, 0, price, 0);

        // 0.5% under what all of it is worth: what does not sell is worth less than that, and stays in the wallet
        uint256 ethBefore = alice.balance;
        _urSwap(alice, keyA, false, held, worth * 995 / 1000, 0, 0);
        assertEq(alice.balance - ethBefore, gives);
        assertEq(tokenA.balanceOf(alice), held - takes);
    }

    /// @notice A buy of an exact amount of tokens through the Universal Router (SWAP_EXACT_OUT_SINGLE): the trader gets
    ///         exactly what it asked, for the live quoter's price, never above its maximum, and the hook takes the share
    ///         of that price an exact-input buy pays.
    function test_fork_universalRouterExactOutputBuyPaysTheExactInputRate() public {
        assertEq(hook.snipeTaxBps(pairId), 0);
        _buyExactOutputAndExactInput(keyD, 0);
    }

    /// @notice A second after launch, when buys also pay the anti-snipe tax (49% then), an exact-output buy pays all of
    ///         it, as an exact-input buy does.
    function test_fork_universalRouterExactOutputBuyPaysTheSnipeTax() public {
        DuelFactory.CreateParams memory params = DuelFactory.CreateParams({
            nameA: "Owls",
            symbolA: "OWLS",
            nameD: "Bats",
            symbolD: "BATS",
            metadataURI: "ipfs://duel-fork-launch",
            buyA: 0,
            buyD: 0,
            supporter: false,
            category: 0,
            config: factory.configHash()
        });
        vm.prank(creator);
        // the launch fee alone
        uint256 launched = factory.createPair{value: 0.01 ether}(params);
        (PoolKey memory key,,) = hook.poolKeys(launched);
        vm.warp(block.timestamp + 1);
        assertEq(hook.snipeTaxBps(launched), 4900);
        _buyExactOutputAndExactInput(key, 4900);
    }

    /// @notice A sale for an exact amount of ETH through the Universal Router: the hook takes its fee before the swap,
    ///         grossed up on the ETH asked, so the trader gets exactly that ETH and the pool pays it with the fee. A sale
    ///         asking for more than the pool can pay would pay the fee on ETH that never comes: the hook reverts it.
    function test_fork_universalRouterExactOutputSaleFillsWholeOrReverts() public {
        _urSwap(alice, keyA, true, 1 ether, 1 ether);
        _permit(alice, address(tokenA));
        uint256 held = tokenA.balanceOf(alice);
        (uint256 price,) = QUOTER.quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams(keyA, false, 0.5 ether, ""));

        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        _urSwapExactOut(alice, keyA, false, 0.5 ether, held, 0);
        Trade memory sale = _trade(vm.getRecordedLogs());
        assertEq(alice.balance - ethBefore, 0.5 ether);
        assertEq(held - tokenA.balanceOf(alice), price);
        // 0.5 ETH is 98.8% of what the pool paid: the fee is 1.2% of it, as on an exact-input sale
        uint256 gross = FullMath.mulDivRoundingUp(0.5 ether, 10_000, 9880);
        assertEq(sale.eth, int256(gross));
        assertEq(sale.fee, gross - 0.5 ether);
        assertApproxEqAbs(sale.fee, (gross * 120) / 10_000, 1);

        // all the ETH left in the pool, with the fee on top: more than the pool pays
        (, uint256 pays) = _untilLaunch(keyA);
        uint256 rest = tokenA.balanceOf(alice);
        bytes memory partialFill =
            _hookError(IHooks.afterSwap.selector, abi.encodeWithSelector(DuelHook.PartialFill.selector));
        vm.expectRevert(partialFill);
        _urSwapExactOut(alice, keyA, false, pays, rest, 0);
        // which the live quoter cannot quote either
        vm.expectRevert(abi.encodeWithSelector(IV4Quoter.UnexpectedRevertBytes.selector, partialFill));
        QUOTER.quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams(keyA, false, uint128(pays), ""));
    }

    function test_fork_quoterMatchesExecution() public {
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: keyD, zeroForOne: true, exactAmount: 0.5 ether, hookData: ""})
        );
        vm.prank(bob);
        uint256 received = router.swapExactIn{value: 0.5 ether}(keyD, true, 0.5 ether, quoted, bob, block.timestamp);
        assertEq(received, quoted);
    }

    /// @notice A switch through the ETH pools: the live quoter's two-hop quote, which the app shows, is what the router
    ///         gives, to the wei.
    function test_fork_switchThroughEthMatchesTheQuotersPath() public {
        vm.startPrank(alice);
        uint256 bought = router.swapExactIn{value: 1 ether}(keyA, true, 1 ether, 1, alice, block.timestamp);
        tokenA.approve(address(router), bought);
        vm.stopPrank();

        IV4Quoter.PathKey[] memory path = new IV4Quoter.PathKey[](2);
        path[0] = IV4Quoter.PathKey(keyA.currency0, keyA.fee, keyA.tickSpacing, keyA.hooks, "");
        path[1] = IV4Quoter.PathKey(keyD.currency1, keyD.fee, keyD.tickSpacing, keyD.hooks, "");
        (uint256 quoted,) = QUOTER.quoteExactInput(
            IV4Quoter.QuoteExactParams({exactCurrency: keyA.currency1, path: path, exactAmount: uint128(bought / 2)})
        );

        vm.prank(alice);
        uint256 received = router.swapThroughEth(keyA, keyD, bought / 2, quoted, alice, block.timestamp);
        assertEq(received, quoted);
        assertEq(tokenD.balanceOf(alice), received);
        assertEq(tokenA.balanceOf(alice), bought - bought / 2);
        assertEq(address(router).balance, 0);
    }

    function test_fork_roundSettlesAndEveryoneGetsPaid() public {
        vm.startPrank(alice);
        router.swapExactIn{value: 2 ether}(keyA, true, 2 ether, 1, alice, block.timestamp);
        vm.stopPrank();
        vm.prank(bob);
        router.swapExactIn{value: 0.5 ether}(keyD, true, 0.5 ether, 1, bob, block.timestamp);

        DuelHook.Pair memory p = hook.getPair(pairId);
        uint256 supplyA = tokenA.totalSupply();
        assertGt(p.pot, 0);

        vm.warp(p.roundEnd);
        hook.settle(pairId);
        DuelHook.Pair memory settled = hook.getPair(pairId);
        assertEq(settled.roundIndex, 1);
        assertLt(settled.pot, p.pot); // part of the pot bought side A back
        assertLt(tokenA.totalSupply(), supplyA); // and burned it

        uint256 creatorBefore = creator.balance;
        hook.claimCreatorFees(pairId);
        assertGt(creator.balance, creatorBefore);

        uint256 treasuryBefore = treasury.balance;
        hook.claimProtocolFees();
        assertGt(treasury.balance, treasuryBefore);
    }

    /// @dev Alice buys A with 5 ETH. The realignment after her buy sells into A's pool some of the cross pool's A, at its
    ///      new price: the pool then pays for less A than she holds (`takes`, for all its ETH, `pays`).
    /// @notice The sale the route `sell` exists for, on the live PoolManager: a holder whose side's pool has no ETH left,
    ///         the ETH paying for its tokens sitting in the other side's. The live quoter refuses the sale, which is
    ///         what makes the app turn to `sell`; the simulator quotes it; `swapExactIn` sells part of it and leaves the
    ///         rest; `sell` takes it all, pays the quote to the wei, and leaves nothing in the router.
    function test_fork_aSaleItsPoolCannotPay_leavesThroughTheOtherSide() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenD.approve(address(router), type(uint256).max);
        router.swapExactIn{value: 0.05 ether}(keyA, true, 0.05 ether, 1, alice, block.timestamp);
        uint256 held = router.swapExactIn{value: 0.05 ether}(keyD, true, 0.05 ether, 1, alice, block.timestamp);
        vm.stopPrank();
        // the creator leaves both sides first, then alice A: the first out take the ETH
        vm.startPrank(creator);
        tokenA.approve(address(router), type(uint256).max);
        tokenD.approve(address(router), type(uint256).max);
        router.swapExactIn(keyA, false, tokenA.balanceOf(creator), 0, creator, block.timestamp);
        router.swapExactIn(keyD, false, tokenD.balanceOf(creator), 0, creator, block.timestamp);
        vm.stopPrank();
        uint256 heldA = tokenA.balanceOf(alice);
        vm.prank(alice);
        router.swapExactIn(keyA, false, heldA, 0, alice, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IV4Quoter.UnexpectedRevertBytes.selector,
                abi.encodeWithSelector(IV4Quoter.NotEnoughLiquidity.selector, keyD.toId())
            )
        );
        QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(keyD, false, uint128(held), ""));

        // into D's pool alone: part of it sells, the pool ends without ETH and the rest stays in the wallet
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 alone = router.swapExactIn(keyD, false, held, 0, alice, block.timestamp);
        assertGt(tokenD.balanceOf(alice), 0);
        (uint160 price,,,) = POOL_MANAGER.getSlot0(keyD.toId());
        assertEq(price, TickMath.MAX_SQRT_PRICE - 1);
        vm.revertToState(snapshot);

        // the quote, as the app asks for it: the simulator's code on alice's own address
        vm.etch(alice, type(DuelSimulator).runtimeCode);
        (uint256 quoted,, uint256 paid, uint256 back) =
            DuelSimulator(payable(alice)).simulateSale(router, hook, pairId, keyD, keyX, keyA, held);
        vm.revertToState(snapshot);
        assertEq(paid, held);
        assertEq(back, 0);
        assertGt(quoted, alone);

        uint256 claimsBefore = POOL_MANAGER.balanceOf(address(hook), 0);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = router.sell(keyD, keyX, keyA, held, quoted, alice, block.timestamp);
        assertEq(out, quoted);
        assertEq(alice.balance - ethBefore, out);
        assertEq(tokenD.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(address(router).balance, 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenD.balanceOf(address(router)), 0);
        // the hook holds what it owes, to the wei, in the live PoolManager
        DuelHook.Pair memory p = hook.getPair(pairId);
        assertGt(POOL_MANAGER.balanceOf(address(hook), 0), claimsBefore);
        assertEq(POOL_MANAGER.balanceOf(address(hook), 0), hook.protocolFees() + p.pot + p.creatorFees);

        // a wei more than the quote is refused, and nothing moves
        vm.revertToState(snapshot);
        vm.prank(alice);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        router.sell(keyD, keyX, keyA, held, quoted + 1, alice, block.timestamp);
        assertEq(tokenD.balanceOf(alice), held);
    }

    function _aliceHoldsMoreAThanItsPoolPaysFor() internal returns (uint256 held, uint256 takes, uint256 pays) {
        _urSwap(alice, keyA, true, 5 ether, 5 ether);
        held = tokenA.balanceOf(alice);
        (takes, pays) = _untilLaunch(keyA);
        assertGt(held, takes);
    }

    /// @dev What an ETH pool of the pair takes before its price is back at the launch price, where its position ends, and
    ///      the ETH it pays for that: all it holds.
    function _untilLaunch(PoolKey memory key) internal view returns (uint256 tokens, uint256 eth) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint160 launchPrice = TickMath.getSqrtPriceAtTick(hook.getPair(pairId).startTick);
        uint128 liquidity = POOL_MANAGER.getLiquidity(key.toId());
        tokens = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, launchPrice, liquidity, true);
        eth = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, launchPrice, liquidity, false);
    }

    /// @dev Bob buys exactly a million tokens from `key`'s pool, then, from the same state, spends what they cost in an
    ///      exact-input buy: the hook takes `1.2% + taxBps` of what he pays either way. On exact output the pool's input
    ///      is not what bob specified: the hook takes its cut after the swap, grossed up on that input (`_ethCut`).
    function _buyExactOutputAndExactInput(PoolKey memory key, uint256 taxBps) internal {
        uint256 tokens = 1_000_000 ether;
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        (uint256 price,) =
            QUOTER.quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams(key, true, uint128(tokens), ""));

        // a maximum a wei under the price
        vm.expectRevert(abi.encodeWithSelector(IUniversalRouter.V4TooMuchRequested.selector, price - 1, price));
        _urSwapExactOut(bob, key, true, tokens, price - 1, 1 ether);

        uint256 snapshot = vm.snapshotState();
        uint256 ethBefore = bob.balance;
        vm.recordLogs();
        _urSwapExactOut(bob, key, true, tokens, 1 ether, 1 ether);
        Trade memory exactOut = _trade(vm.getRecordedLogs());
        assertEq(token.balanceOf(bob), tokens);
        // he sent 1 ETH and paid the quoted price: the sweep sent him the rest
        assertEq(ethBefore - bob.balance, price);
        uint256 cut = exactOut.fee + exactOut.tax;
        assertEq(cut, price - uint256(-exactOut.eth));
        assertApproxEqAbs(cut, price * (120 + taxBps) / 10_000, 1);
        assertApproxEqAbs(exactOut.tax, price * taxBps / 10_000, 2);

        // the fee taken before the swap, on what bob specified: at least the same tokens, the same fee and tax to a wei
        vm.revertToState(snapshot);
        vm.recordLogs();
        _urSwap(bob, key, true, price, price);
        Trade memory exactIn = _trade(vm.getRecordedLogs());
        assertGe(token.balanceOf(bob), tokens);
        assertEq(exactIn.fee + exactIn.tax, price * (120 + taxBps) / 10_000);
        assertApproxEqAbs(exactIn.fee, exactOut.fee, 1);
        assertApproxEqAbs(exactIn.tax, exactOut.tax, 1);
    }

    /// @dev The trade a swap through the Universal Router left in `logs`.
    function _trade(Vm.Log[] memory logs) internal view returns (Trade memory t) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(POOL_MANAGER) && log.topics[0] == IPoolManager.Swap.selector) {
                // the router's swap, not the hook's own in the realignment after it
                if (address(uint160(uint256(log.topics[2]))) != address(UNIVERSAL_ROUTER)) continue;
                (int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity,,) =
                    abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
                (t.eth, t.tokens, t.sqrtPriceX96, t.liquidity) = (amount0, amount1, sqrtPriceX96, liquidity);
            } else if (log.emitter == address(hook) && log.topics[0] == DuelHook.FeeTaken.selector) {
                (t.fee, t.tax) = abi.decode(log.data, (uint256, uint256));
            } else if (log.emitter == address(hook) && log.topics[0] == DuelHook.ArbitrageCaptured.selector) {
                t.captured += abi.decode(log.data, (uint256));
            }
        }
    }

    /// @dev The revert data the PoolManager produces when a hook callback reverts with `reason`.
    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _permit(address user, address token) internal {
        vm.startPrank(user);
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(UNIVERSAL_ROUTER), type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _urSwap(address user, PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 value) internal {
        _urSwap(user, key, zeroForOne, amountIn, 0, 0, value);
    }

    /// @dev An exact-input swap through the Universal Router as the Uniswap SDK sends one: the swap, with the trader's
    ///      minimums, then SETTLE_ALL pays the router's whole debt in the input (Permit2 pulls it from the trader; ETH is
    ///      paid from what the call sent) and TAKE_ALL sends the trader its whole credit in the output.
    function _urSwap(
        address user,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 minHopPriceX36,
        uint256 value
    ) internal {
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(amountOutMinimum),
                minHopPriceX36: minHopPriceX36,
                hookData: ""
            })
        );
        params[1] = abi.encode(input, amountIn);
        params[2] = abi.encode(output, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] =
            abi.encode(abi.encodePacked(uint8(SWAP_EXACT_IN_SINGLE), uint8(SETTLE_ALL), uint8(TAKE_ALL)), params);

        vm.prank(user);
        UNIVERSAL_ROUTER.execute{value: value}(abi.encodePacked(uint8(V4_SWAP)), inputs, block.timestamp + 60);
    }

    /// @dev An exact-output swap through the Universal Router: exactly `amountOut`, for at most `amountInMaximum`. Paid in
    ///      ETH, the router keeps what the swap did not use unless the call sweeps it back, as the Uniswap SDK's does.
    function _urSwapExactOut(
        address user,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 value
    ) internal {
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: uint128(amountOut),
                amountInMaximum: uint128(amountInMaximum),
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(input, amountInMaximum);
        params[2] = abi.encode(output, amountOut);
        bool sweep = input.isAddressZero();
        bytes[] memory inputs = new bytes[](sweep ? 2 : 1);
        inputs[0] =
            abi.encode(abi.encodePacked(uint8(SWAP_EXACT_OUT_SINGLE), uint8(SETTLE_ALL), uint8(TAKE_ALL)), params);
        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        if (sweep) {
            // all the router's ETH (address zero there) to the trader
            inputs[1] = abi.encode(address(0), user, uint256(0));
            commands = abi.encodePacked(commands, uint8(SWEEP));
        }

        vm.prank(user);
        UNIVERSAL_ROUTER.execute{value: value}(commands, inputs, block.timestamp + 60);
    }
}
