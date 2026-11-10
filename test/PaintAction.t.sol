// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../src/Order.sol";
import {Artwork} from "../examples/Artwork.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {Base} from "./utils/Base.sol";

contract PaintActionTest is Base {
    Artwork art;
    address artist = makeAddr("artist");
    uint256 constant ID = 7;
    uint256 constant ALLOWED = (1 << 3) | (1 << 9) | (1 << 200);

    function setUp() public override {
        super.setUp();
        vm.prank(artist);
        art = new Artwork();
        vm.prank(artist);
        art.mint(artist, ID);
    }

    /// The artist offers one repaint for 0.5 ETH and lends the order the
    /// painter role. Returns the order and its config.
    function _offer() internal returns (Order order, bytes memory config) {
        config = abi.encode(PaintAction.Config(art, ID, ALLOWED, 0.5 ether, artist));
        order = _create(artist, paint, config);
        vm.prank(artist);
        art.setPainter(ID, address(order));
    }

    function test_buyerPaintsAndPays() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(buyer);
        order.fill{value: 0.6 ether}(config, abi.encode(uint8(9)));

        assertEq(art.colorOf(ID), 9);
        assertEq(art.ownerOf(ID), artist); // the buyer bought an action, not the token
        assertEq(artist.balance, 0.5 ether);
        assertEq(buyer.balance, 100 ether - 0.5 ether);
        assertEq(address(order).balance, 0);
    }

    /// After its single use, the order holds no authority and accepts no fill.
    function test_authorityIsConsumed() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(buyer);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));

        assertEq(art.painterOf(ID), address(0));
        assertTrue(order.closed());
        vm.prank(attacker);
        vm.expectRevert(Order.OrderClosed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(9)));
        // Not even the order's owner can paint through the order any more.
        vm.prank(artist);
        vm.expectRevert(Artwork.NotAllowed.selector);
        order.execute(address(art), 0, abi.encodeCall(Artwork.paint, (ID, 9)));
    }

    function test_onlyAllowedColors() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PaintAction.ColorNotAllowed.selector, 4));
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(4)));
        // Input outside uint8 does not decode.
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 0.5 ether}(config, abi.encode(uint256(256 + 3)));
    }

    function testFuzz_colorRule(uint8 color) public {
        (Order order, bytes memory config) = _offer();
        bool allowed = (ALLOWED >> color) & 1 == 1;
        vm.prank(buyer);
        if (!allowed) vm.expectRevert(abi.encodeWithSelector(PaintAction.ColorNotAllowed.selector, color));
        order.fill{value: 0.5 ether}(config, abi.encode(color));
        assertEq(art.colorOf(ID), allowed ? color : 0);
    }

    function test_underpaymentReverts() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PaintAction.Underpaid.selector, 0.5 ether, 0.4 ether));
        order.fill{value: 0.4 ether}(config, abi.encode(uint8(3)));
    }

    /// The artwork's own rules decide: an order the owner never named as painter cannot paint,
    /// and the buyer's ETH stays with the buyer.
    function test_noAuthorityNoAction() public {
        bytes memory config = abi.encode(PaintAction.Config(art, ID, ALLOWED, 0.5 ether, artist));
        Order order = _create(artist, paint, config);
        vm.prank(buyer);
        vm.expectRevert(Artwork.NotAllowed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));
        assertEq(buyer.balance, 100 ether);
    }

    /// Someone other than the token's owner cannot create a working offer for it.
    function test_nonOwnerCannotSellTheAction() public {
        bytes memory config = abi.encode(PaintAction.Config(art, ID, ALLOWED, 0.5 ether, attacker));
        Order order = _create(attacker, paint, config);
        vm.prank(attacker);
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.setPainter(ID, address(order));
        vm.prank(buyer);
        vm.expectRevert(Artwork.NotAllowed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));
    }

    /// A stale offer dies with the authority behind it: transferring the token clears the
    /// painter, so the old order can no longer act.
    function test_transferMakesOfferStale() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(artist);
        art.transferFrom(artist, seller, ID);
        vm.prank(buyer);
        vm.expectRevert(Artwork.NotAllowed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));
    }

    /// Cancelling the offer does not revoke the painter role: closing stops fills and nothing
    /// else. The owner then resigns the role through the closed order (or, as the token's
    /// owner, could clear it on the artwork directly).
    function test_closingKeepsTheRoleUntilRevoked() public {
        (Order order, bytes memory config) = _offer();
        vm.startPrank(artist);
        order.close();
        assertEq(art.painterOf(ID), address(order));
        order.execute(address(art), 0, abi.encodeCall(Artwork.resign, (ID)));
        vm.stopPrank();
        assertEq(art.painterOf(ID), address(0));
        vm.prank(buyer);
        vm.expectRevert(Order.OrderClosed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));
    }

    /// An active order commits only the authority it holds while it holds it: the artwork's
    /// owner keeps its own rights in the artwork and can take the role back at any time.
    function test_creatorRevokesWithoutTouchingTheOrder() public {
        (Order order, bytes memory config) = _offer();
        vm.prank(artist);
        art.setPainter(ID, address(0));
        vm.prank(buyer);
        vm.expectRevert(Artwork.NotAllowed.selector);
        order.fill{value: 0.5 ether}(config, abi.encode(uint8(3)));
    }

    /// The artwork contract cannot tell an order from anyone else; it only sees the painter.
    /// Two offers for different tokens stay independent.
    function test_offersForDifferentTokensAreIsolated() public {
        vm.prank(artist);
        art.mint(artist, 8);
        (Order a, bytes memory ca) = _offer();
        bytes memory cb = abi.encode(PaintAction.Config(art, 8, ALLOWED, 1 ether, artist));
        Order b = _create(artist, paint, cb);
        vm.prank(artist);
        art.setPainter(8, address(b));

        // Order a is active, so not even its owner can act through it; its handler paints only
        // the token in a's config.
        vm.prank(artist);
        vm.expectRevert(Order.Unauthorized.selector);
        a.execute(address(art), 0, abi.encodeCall(Artwork.paint, (8, 3)));

        vm.prank(buyer);
        a.fill{value: 0.5 ether}(ca, abi.encode(uint8(3)));
        assertEq(art.painterOf(8), address(b));
        vm.prank(buyer);
        b.fill{value: 1 ether}(cb, abi.encode(uint8(9)));
        assertEq(art.colorOf(ID), 3);
        assertEq(art.colorOf(8), 9);
    }
}
