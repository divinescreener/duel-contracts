// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DuelToken} from "../../src/DuelToken.sol";

contract DuelTokenTest is Test {
    DuelToken internal token;
    address internal holder = makeAddr("holder");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new DuelToken("Cats", "CATS", "ipfs://meta", holder);
    }

    function test_mintsTheWholeSupplyOnce() public view {
        assertEq(token.name(), "Cats");
        assertEq(token.symbol(), "CATS");
        assertEq(token.decimals(), 18);
        assertEq(token.metadataURI(), "ipfs://meta");
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(holder), 1_000_000_000 ether);
    }

    function test_namesTheLaunchpadThatLaunchedIt() public view {
        assertEq(token.LAUNCHPAD_VERSION(), 1);
        assertEq(token.LAUNCHPAD_CODENAME(), "Petunia");
    }

    function test_approvesBySignature() public {
        (address signer, uint256 key) = makeAddrAndKey("signer");
        vm.prank(holder);
        token.transfer(signer, 10 ether);

        // its permits are signed for this token, on this chain, as EIP-712 and ERC-5267 say: in Duel's domain, whatever
        // the token's name (a long one included)
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(name, "Duel");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                spender,
                4 ether,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), permitHash)));
        // anyone may send it
        token.permit(signer, spender, 4 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), 4 ether);
        assertEq(token.nonces(signer), 1);
        // once
        vm.expectRevert();
        token.permit(signer, spender, 4 ether, deadline, v, r, s);
        vm.prank(spender);
        token.transferFrom(signer, spender, 4 ether);
        assertEq(token.balanceOf(spender), 4 ether);

        DuelToken long = new DuelToken(
            unicode"🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶🐶",
            "DOGS",
            "",
            holder
        );
        (, name,,,,,) = long.eip712Domain();
        assertEq(name, "Duel");
        assertTrue(long.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR());
    }

    function test_burnReducesTheSupply() public {
        vm.prank(holder);
        token.burn(100 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether - 100 ether);

        vm.prank(holder);
        token.approve(spender, 50 ether);
        vm.prank(spender);
        token.burnFrom(holder, 50 ether);
        assertEq(token.balanceOf(holder), 1_000_000_000 ether - 150 ether);
    }
}
