// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DuelToken} from "../../src/DuelToken.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";

/// @dev Shared signing helper for local, known private keys. Expected hashes are built independently of the token.
abstract contract PermitSigning is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _sign(
        uint256 key,
        bytes32 domain,
        address holder,
        address spender,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (DuelRouter.Permit memory p) {
        bytes32 hash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, amount, nonce, deadline));
        (p.v, p.r, p.s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, hash)));
        p.deadline = deadline;
    }

    function _apply(DuelToken token, address holder, address spender, uint256 value, DuelRouter.Permit memory p)
        internal
    {
        token.permit(holder, spender, value, p.deadline, p.v, p.r, p.s);
    }
}

/// @notice Domain isolation, nonce histories, canonical signatures and explicit revocation, without any pool.
contract DuelTokenPermitSecurityTest is PermitSigning {
    DuelToken internal token;
    DuelToken internal otherToken;
    address internal holder;
    uint256 internal holderKey;
    address internal second;
    uint256 internal secondKey;
    address internal spender = makeAddr("permit spender");
    address internal otherSpender = makeAddr("other permit spender");

    function setUp() public {
        vm.warp(1_800_000_000);
        (holder, holderKey) = makeAddrAndKey("permit holder");
        (second, secondKey) = makeAddrAndKey("second permit holder");
        token = new DuelToken("Cats", "CATS", "", holder);
        otherToken = new DuelToken("Cats", "CATS", "", holder);
        vm.prank(holder);
        token.transfer(second, 100 ether);
    }

    function _signed(uint256 value, uint256 nonce) internal view returns (DuelRouter.Permit memory) {
        return _sign(holderKey, token.DOMAIN_SEPARATOR(), holder, spender, value, nonce, block.timestamp + 1 hours);
    }

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.nonces(holder),
                token.nonces(second),
                token.allowance(holder, spender),
                token.allowance(holder, otherSpender),
                token.allowance(second, spender),
                token.balanceOf(holder),
                token.balanceOf(second),
                token.balanceOf(spender),
                token.totalSupply(),
                otherToken.nonces(holder),
                otherToken.allowance(holder, spender)
            )
        );
    }

    function _reject(
        DuelToken target,
        address account,
        address approvedSpender,
        uint256 value,
        DuelRouter.Permit memory p
    ) internal {
        bytes32 beforeState = _state();
        vm.expectRevert();
        _apply(target, account, approvedSpender, value, p);
        assertEq(_state(), beforeState, "rejected permit mutated token state");
    }

    function test_domain_rejectsAnotherTokenWithTheSameName() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        _reject(otherToken, holder, spender, 4 ether, p);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(token.nonces(holder), 1);
        assertEq(otherToken.nonces(holder), 0);
    }

    function test_domain_rejectsAnotherChainAndRestoresTheOriginalDomain() public {
        // Literal fixture ids avoid relying on the compiler's CHAINID assumptions across a VM cheatcode.
        vm.chainId(31_337);
        bytes32 originalDomain = token.DOMAIN_SEPARATOR();
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        vm.chainId(31_338);
        assertNotEq(token.DOMAIN_SEPARATOR(), originalDomain);
        _reject(token, holder, spender, 4 ether, p);
        vm.chainId(31_337);
        assertEq(token.DOMAIN_SEPARATOR(), originalDomain);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(token.nonces(holder), 1);
    }

    function test_domain_rejectsAnotherSpender() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        _reject(token, holder, otherSpender, 4 ether, p);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(token.allowance(holder, otherSpender), 0);
        assertEq(token.allowance(holder, spender), 4 ether);
    }

    function test_payload_ownerValueAndDeadlineAreBoundToTheSignature() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        _reject(token, second, spender, 4 ether, p);
        _reject(token, holder, spender, 4 ether + 1, p);
        p.deadline++;
        _reject(token, holder, spender, 4 ether, p);
    }

    function test_history_successivePermitsReplaceTheAllowanceIncludingZero() public {
        _apply(token, holder, spender, 9 ether, _signed(9 ether, 0));
        _apply(token, holder, spender, 3 ether, _signed(3 ether, 1));
        assertEq(token.allowance(holder, spender), 3 ether, "permit must replace, not add");
        _apply(token, holder, spender, 0, _signed(0, 2));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.nonces(holder), 3);
    }

    function test_history_rejectsAStaleNonceWithoutUndoingTheCurrentAllowance() public {
        DuelRouter.Permit memory stale = _signed(8 ether, 0);
        _apply(token, holder, spender, 2 ether, _signed(2 ether, 0));
        _reject(token, holder, spender, 8 ether, stale);
        assertEq(token.allowance(holder, spender), 2 ether);
        assertEq(token.nonces(holder), 1);
    }

    function test_history_futureNonceIsUsableOnlyAfterItsPredecessor() public {
        DuelRouter.Permit memory future = _signed(8 ether, 1);
        _reject(token, holder, spender, 8 ether, future);
        _apply(token, holder, spender, 2 ether, _signed(2 ether, 0));
        _apply(token, holder, spender, 8 ether, future);
        assertEq(token.allowance(holder, spender), 8 ether);
        assertEq(token.nonces(holder), 2);
    }

    function test_history_noncesAreIndependentAcrossOwnersAndTokens() public {
        _apply(token, holder, spender, 4 ether, _signed(4 ether, 0));
        DuelRouter.Permit memory secondPermit =
            _sign(secondKey, token.DOMAIN_SEPARATOR(), second, spender, 2 ether, 0, block.timestamp + 1 hours);
        _apply(token, second, spender, 2 ether, secondPermit);
        DuelRouter.Permit memory otherPermit =
            _sign(holderKey, otherToken.DOMAIN_SEPARATOR(), holder, spender, 7 ether, 0, block.timestamp + 1 hours);
        _apply(otherToken, holder, spender, 7 ether, otherPermit);
        assertEq(token.nonces(holder), 1);
        assertEq(token.nonces(second), 1);
        assertEq(otherToken.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 4 ether);
        assertEq(token.allowance(second, spender), 2 ether);
        assertEq(otherToken.allowance(holder, spender), 7 ether);
    }

    function test_history_approvalAndSpendingDoNotConsumePermitNonces() public {
        vm.prank(holder);
        token.approve(spender, 6 ether);
        vm.prank(spender);
        token.transferFrom(holder, second, 2 ether);
        assertEq(token.nonces(holder), 0);
        _apply(token, holder, spender, 3 ether, _signed(3 ether, 0));
        assertEq(token.allowance(holder, spender), 3 ether);
        vm.prank(spender);
        token.transferFrom(holder, second, 1 ether);
        assertEq(token.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 2 ether);
    }

    function test_history_expiryDoesNotRevokeAnAllowanceButApproveZeroDoes() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        _apply(token, holder, spender, 4 ether, p);
        vm.warp(p.deadline + 1);
        assertEq(token.allowance(holder, spender), 4 ether);
        vm.prank(holder);
        token.approve(spender, 0);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.nonces(holder), 1);
    }

    function test_deadline_acceptsTheExactDeadlineAndRejectsOneSecondLater() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        vm.warp(p.deadline + 1);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, p.deadline));
        _apply(token, holder, spender, 4 ether, p);
        assertEq(_state(), beforeState);
        vm.warp(p.deadline);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(token.nonces(holder), 1);
    }

    function test_signature_rejectsHighSWithoutChangingNonceOrAllowance() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        p.s = bytes32(uint256(0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) + 1);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, p.s));
        _apply(token, holder, spender, 4 ether, p);
        assertEq(_state(), beforeState);
    }

    function test_signature_rejectsInvalidVWithoutChangingNonceOrAllowance() public {
        DuelRouter.Permit memory p = _signed(4 ether, 0);
        p.v = 0;
        bytes32 beforeState = _state();
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(_state(), beforeState);
    }

    function test_signature_rejectsZeroComponentsWithoutChangingNonceOrAllowance() public {
        DuelRouter.Permit memory p = DuelRouter.Permit(block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        bytes32 beforeState = _state();
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _apply(token, holder, spender, 4 ether, p);
        assertEq(_state(), beforeState);
    }

    function test_signature_rejectsAValidSignatureByTheWrongSigner() public {
        DuelRouter.Permit memory p =
            _sign(secondKey, token.DOMAIN_SEPARATOR(), holder, spender, 4 ether, 0, block.timestamp + 1 hours);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, second, holder));
        _apply(token, holder, spender, 4 ether, p);
        assertEq(_state(), beforeState);
    }

    function testFuzz_history_replacementAndConsumptionAreExact(uint96 previous, uint96 permitted, uint96 consumed)
        public
    {
        uint256 amount = bound(uint256(permitted), 0, 100 ether);
        uint256 paid = bound(uint256(consumed), 0, amount);
        vm.prank(holder);
        token.approve(spender, uint256(previous));
        _apply(token, holder, spender, amount, _signed(amount, 0));
        assertEq(token.allowance(holder, spender), amount);
        uint256 holderBefore = token.balanceOf(holder);
        uint256 secondBefore = token.balanceOf(second);
        vm.prank(spender);
        token.transferFrom(holder, second, paid);
        assertEq(token.allowance(holder, spender), amount - paid);
        assertEq(token.balanceOf(holder), holderBefore - paid);
        assertEq(token.balanceOf(second), secondBefore + paid);
        assertEq(token.nonces(holder), 1);
    }
}

/// @dev A minimal contract account using the ordinary approve path; no EOA signature or privileged token behavior.
contract PermitApprovedAccount {
    address private immutable controller = msg.sender;

    function execute(
        DuelToken token,
        DuelRouter router,
        PoolKey calldata keyIn,
        PoolKey calldata keyOut,
        uint8 route,
        bool zeroForOne,
        uint256 amount,
        address recipient
    ) external returns (uint256) {
        require(msg.sender == controller, "controller");
        token.approve(address(router), amount);
        if (route == 2) return router.swapThroughEth(keyIn, keyOut, amount, 1, recipient, block.timestamp);
        return router.swapExactIn(keyIn, zeroForOne, amount, 1, recipient, block.timestamp);
    }

    receive() external payable {}
}

/// @notice Ordinary buy/sell/switch fixtures prove permit rollback and payer/recipient separation on all three routes.
contract DuelRouterPermitSecurityTest is DuelTestBase, PermitSigning {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PairInfo internal info;
    address internal trader;
    uint256 internal traderKey;
    uint256 internal held;

    function setUp() public override(DuelTestBase) {
        super.setUp();
        info = _createPair(0, 0, false);
        vm.warp(block.timestamp + 10);
        (trader, traderKey) = makeAddrAndKey("router permit holder");
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        held = router.swapExactIn{value: 1 ether}(info.keyA, true, 1 ether, 1, trader, block.timestamp);
    }

    function _permit(uint256 amount) internal view returns (DuelRouter.Permit memory) {
        return _sign(
            traderKey,
            info.a.DOMAIN_SEPARATOR(),
            trader,
            address(router),
            amount,
            info.a.nonces(trader),
            block.timestamp + 1 hours
        );
    }

    function _route(uint8 route, uint256 amount, uint256 minimum, address recipient, DuelRouter.Permit memory p)
        internal
        returns (uint256)
    {
        if (route == 2) {
            return router.swapThroughEthWithPermit(info.keyA, info.keyD, amount, minimum, recipient, block.timestamp, p);
        }
        PoolKey memory key = route == 0 ? info.keyA : info.keyX;
        bool direction = route == 1 && Currency.unwrap(key.currency0) == address(info.a);
        return router.swapExactInWithPermit(key, direction, amount, minimum, recipient, block.timestamp, p);
    }

    function _poolState(PoolKey memory key) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(key.toId())));
    }

    function _accountState(address account) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                account.balance,
                info.a.balanceOf(account),
                info.d.balanceOf(account),
                info.a.nonces(account),
                info.d.nonces(account),
                info.a.allowance(account, address(router)),
                info.d.allowance(account, address(router)),
                manager.balanceOf(account, 0),
                manager.balanceOf(account, uint256(uint160(address(info.a)))),
                manager.balanceOf(account, uint256(uint160(address(info.d))))
            )
        );
    }

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.getPair(info.id),
                hook.protocolFees(),
                hook.pairCount(),
                info.a.totalSupply(),
                info.d.totalSupply(),
                _poolState(info.keyA),
                _poolState(info.keyD),
                _poolState(info.keyX),
                _accountState(trader),
                _accountState(bob),
                _accountState(creator),
                _accountState(treasury),
                _accountState(address(hook)),
                _accountState(address(manager)),
                _accountState(address(router))
            )
        );
    }

    function _rollback(uint8 route, uint256 requested) internal {
        // An existing allowance must be restored too: the valid permit temporarily replaces it before the route fails.
        vm.prank(trader);
        info.a.approve(address(router), 17);
        DuelRouter.Permit memory p = _permit(requested);
        bytes32 beforeState = _state();
        vm.prank(trader);
        vm.expectRevert(DuelRouter.TooLittleReceived.selector);
        _route(route, requested, type(uint256).max, bob, p);
        assertEq(_state(), beforeState, "failed route must undo permit and every observed state change");
        // The same signature is still valid after rollback.
        vm.prank(trader);
        assertGt(_route(route, requested, 1, bob, p), 0);
        assertEq(info.a.nonces(trader), 1);
    }

    function test_atomicity_sellFailureRestoresPermitBalancesAndAccounting() public {
        _rollback(0, held / 8);
    }

    function test_atomicity_directSwitchFailureRestoresPermitBalancesAndAccounting() public {
        _rollback(1, held / 8);
    }

    function test_atomicity_ethSwitchFailureRestoresPermitBalancesAndAccounting() public {
        _rollback(2, held / 8);
    }

    function testFuzz_atomicity_allRoutesRestoreState(uint8 routeSeed, uint16 fraction) public {
        _rollback(uint8(bound(routeSeed, 0, 2)), held / bound(uint256(fraction), 8, 100));
    }

    function _recipientSeparation(uint8 route) internal {
        uint256 amount = held / 8;
        uint256 traderEth = trader.balance;
        uint256 recipientEth = bob.balance;
        uint256 recipientD = info.d.balanceOf(bob);
        uint256 payerD = info.d.balanceOf(trader);
        uint256 out;
        DuelRouter.Permit memory p = _permit(amount);
        vm.prank(trader);
        out = _route(route, amount, 1, bob, p);
        assertGt(out, 0);
        uint256 paid = held - info.a.balanceOf(trader);
        assertGt(paid, 0);
        assertLe(paid, amount);
        assertEq(info.a.allowance(trader, address(router)), amount - paid);
        assertEq(info.a.balanceOf(bob), 0, "recipient is not the input payer");
        assertEq(info.a.nonces(bob), 0);
        assertEq(info.a.allowance(bob, address(router)), 0);
        assertEq(info.a.nonces(trader), 1);
        assertEq(info.d.balanceOf(trader), payerD);
        if (route == 0) {
            assertEq(bob.balance, recipientEth + out);
            assertEq(info.d.balanceOf(bob), recipientD);
            assertEq(trader.balance, traderEth);
        } else {
            assertEq(info.d.balanceOf(bob), recipientD + out);
            assertEq(bob.balance, recipientEth);
            if (route == 1) assertEq(trader.balance, traderEth);
        }
        assertEq(info.a.balanceOf(address(router)), 0);
        assertEq(info.d.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function test_isolation_sellPaysTheRecipientAndDebitsOnlyTheCaller() public {
        _recipientSeparation(0);
    }

    function test_isolation_directSwitchPaysTheRecipientAndDebitsOnlyTheCaller() public {
        _recipientSeparation(1);
    }

    function test_isolation_ethSwitchPaysTheRecipientAndDebitsOnlyTheCaller() public {
        _recipientSeparation(2);
    }

    function test_isolation_anUnrelatedHoldersAllowanceNonceAndBalancesStayUnchanged() public {
        vm.prank(bob);
        router.swapExactIn{value: 0.1 ether}(info.keyA, true, 0.1 ether, 1, bob, block.timestamp);
        vm.prank(bob);
        info.a.approve(address(router), 123 ether);
        bytes32 bobBefore = _accountState(bob);
        DuelRouter.Permit memory p = _permit(held / 8);
        vm.prank(trader);
        _route(1, held / 8, 1, trader, p);
        assertEq(_accountState(bob), bobBefore);
    }

    function test_domain_allRoutesRejectAPermitForAnotherRouter() public {
        uint256 amount = held / 8;
        DuelRouter otherRouter = new DuelRouter(manager);
        DuelRouter.Permit memory p = _sign(
            traderKey,
            info.a.DOMAIN_SEPARATOR(),
            trader,
            address(otherRouter),
            amount,
            info.a.nonces(trader),
            block.timestamp + 1 hours
        );
        bytes32 beforeState = _state();
        for (uint8 route; route < 3; ++route) {
            vm.prank(trader);
            vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
            _route(route, amount, 1, trader, p);
            assertEq(_state(), beforeState);
            assertEq(info.a.allowance(trader, address(otherRouter)), 0);
        }
    }

    function _fallback(uint8 route, bool sufficient) internal {
        uint256 amount = held / 8;
        uint256 approved = sufficient ? amount : 0;
        vm.prank(trader);
        info.a.approve(address(router), approved);
        DuelRouter.Permit memory invalid = DuelRouter.Permit(block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
        if (!sufficient) {
            bytes32 beforeState = _state();
            vm.prank(trader);
            vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
            _route(route, amount, 1, trader, invalid);
            assertEq(_state(), beforeState);
        } else {
            vm.prank(trader);
            assertGt(_route(route, amount, 1, trader, invalid), 0);
            uint256 paid = held - info.a.balanceOf(trader);
            assertEq(info.a.allowance(trader, address(router)), approved - paid);
            assertEq(info.a.nonces(trader), 0, "failed permit must not manufacture a nonce or an approval");
        }
    }

    function test_fallback_sellUsesOnlyTheExistingAllowance() public {
        _fallback(0, true);
    }

    function test_fallback_directSwitchUsesOnlyTheExistingAllowance() public {
        _fallback(1, true);
    }

    function test_fallback_ethSwitchUsesOnlyTheExistingAllowance() public {
        _fallback(2, true);
    }

    function test_fallback_sellWithoutAllowanceRollsBack() public {
        _fallback(0, false);
    }

    function test_fallback_directSwitchWithoutAllowanceRollsBack() public {
        _fallback(1, false);
    }

    function test_fallback_ethSwitchWithoutAllowanceRollsBack() public {
        _fallback(2, false);
    }

    function _contractAccount(uint8 route) internal {
        PermitApprovedAccount account = new PermitApprovedAccount();
        uint256 amount = held / 8;
        vm.prank(trader);
        info.a.transfer(address(account), amount);
        uint256 bobEth = bob.balance;
        uint256 bobD = info.d.balanceOf(bob);
        PoolKey memory key = route == 0 ? info.keyA : info.keyX;
        bool direction = route == 1 && Currency.unwrap(key.currency0) == address(info.a);
        uint256 out =
            account.execute(info.a, router, route == 2 ? info.keyA : key, info.keyD, route, direction, amount, bob);
        assertGt(out, 0);
        uint256 remaining = info.a.balanceOf(address(account));
        assertLt(remaining, amount);
        assertEq(info.a.allowance(address(account), address(router)), remaining);
        assertEq(info.a.nonces(address(account)), 0, "ordinary approval needs no permit nonce");
        assertEq(info.a.nonces(trader), 0);
        if (route == 0) assertEq(bob.balance, bobEth + out);
        else assertEq(info.d.balanceOf(bob), bobD + out);
    }

    function test_contractAccount_canApproveAndSellWithoutAnEOAPermit() public {
        _contractAccount(0);
    }

    function test_contractAccount_canApproveAndSwitchDirectlyWithoutAnEOAPermit() public {
        _contractAccount(1);
    }

    function test_contractAccount_canApproveAndSwitchThroughEthWithoutAnEOAPermit() public {
        _contractAccount(2);
    }
}

/// @notice Bounded-liquidity pools force ordinary partial fills, independently of Duel's realignment behavior.
/// @dev These local pools have no hook. They test the router's documented compatibility with any V4 pool.
contract DuelRouterPermitPartialTest is PermitSigning {
    IPoolManager internal manager;
    DuelRouter internal router;
    DuelToken internal input;
    DuelToken internal output;
    PoolKey internal sale;
    PoolKey internal purchase;
    PoolKey internal cross;
    address internal holder;
    uint256 internal key;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 10 ether);
        (holder, key) = makeAddrAndKey("partial permit holder");
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new DuelRouter(manager);
        input = new DuelToken("Input", "IN", "", address(this));
        output = new DuelToken("Output", "OUT", "", address(this));
        input.transfer(holder, 10 ether);
        sale = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(input)), 3000, 60, IHooks(address(0)));
        purchase = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(output)), 3000, 60, IHooks(address(0)));
        bool inputFirst = address(input) < address(output);
        cross = PoolKey(
            Currency.wrap(inputFirst ? address(input) : address(output)),
            Currency.wrap(inputFirst ? address(output) : address(input)),
            3000,
            60,
            IHooks(address(0))
        );
        manager.initialize(sale, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(purchase, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(cross, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        input.approve(address(lp), type(uint256).max);
        output.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 1 ether}(
            sale, IPoolManager.ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), ""
        );
        lp.modifyLiquidity(
            purchase,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: -60, liquidityDelta: 1e17, salt: 0}),
            ""
        );
        lp.modifyLiquidity(
            cross,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    function _partial(uint8 route) internal {
        uint256 requested = 1 ether;
        address recipient = makeAddr("partial fill recipient");
        uint256 balanceBefore = input.balanceOf(holder);
        uint256 ethBefore = holder.balance;
        uint256 managerEthBefore = address(manager).balance;
        DuelRouter.Permit memory p =
            _sign(key, input.DOMAIN_SEPARATOR(), holder, address(router), requested, 0, block.timestamp + 1 hours);
        uint256 out;
        vm.prank(holder);
        if (route == 2) {
            out = router.swapThroughEthWithPermit(sale, purchase, requested, 1, recipient, block.timestamp, p);
        } else {
            out = router.swapExactInWithPermit(
                route == 0 ? sale : cross,
                route == 1 && Currency.unwrap(cross.currency0) == address(input),
                requested,
                1,
                recipient,
                block.timestamp,
                p
            );
        }
        uint256 paid = balanceBefore - input.balanceOf(holder);
        assertGt(out, 0);
        assertGt(paid, 0);
        assertLt(paid, requested, "fixture must exercise a real partial fill");
        assertEq(input.nonces(holder), 1);
        assertEq(input.allowance(holder, address(router)), requested - paid);
        assertEq(input.nonces(recipient), 0);
        assertEq(input.allowance(recipient, address(router)), 0);
        if (route == 0) {
            assertEq(recipient.balance, out);
            assertEq(holder.balance, ethBefore);
        } else {
            assertEq(output.balanceOf(recipient), out);
            assertEq(output.balanceOf(holder), 0);
            assertEq(recipient.balance, 0);
            if (route == 2) {
                // The thin output pool cannot spend all of the sale's ETH: only the payer receives the remainder.
                assertGt(holder.balance, ethBefore);
                assertEq(holder.balance - ethBefore, managerEthBefore - address(manager).balance);
            } else {
                assertEq(holder.balance, ethBefore);
            }
        }
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(output.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        vm.warp(p.deadline + 1);
        assertEq(input.allowance(holder, address(router)), requested - paid, "expiry does not revoke an allowance");
        vm.prank(holder);
        input.approve(address(router), 0);
        assertEq(input.allowance(holder, address(router)), 0);
        assertEq(input.nonces(holder), 1);
    }

    function test_partial_sellLeavesOnlyTheUnspentAllowanceAndItCanBeRevoked() public {
        _partial(0);
    }

    function test_partial_directSwitchLeavesOnlyTheUnspentAllowanceAndItCanBeRevoked() public {
        _partial(1);
    }

    function test_partial_ethSwitchLeavesOnlyTheUnspentAllowanceAndItCanBeRevoked() public {
        _partial(2);
    }

    receive() external payable {}
}
