// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {HandlerBase} from "../examples/HandlerBase.sol";
import {Base} from "./utils/Base.sol";
import {Reenterer, Rejecter} from "./utils/Mocks.sol";

contract DutchAuctionTest is Base {
    function test_buyAtDecliningPrice() public {
        nft.mint(seller, 1);
        DutchAuction.Config memory c = _dutchConfig(1, seller);
        c.payees = _payees(royalty, 500, seller); // 5% royalty, rest to the seller
        bytes memory config = abi.encode(c);
        Order order = _create(seller, dutch, config);
        vm.prank(seller);
        nft.safeTransferFrom(seller, address(order), 1);

        skip(250); // a quarter of the way: 10 - 9 * 0.25 = 7.75 ETH
        assertEq(dutch.price(c, block.timestamp), 7.75 ether);
        address recipient = makeAddr("recipient");
        vm.prank(buyer);
        bytes memory ret = order.fill{value: 8 ether}(config, abi.encode(recipient));

        assertEq(abi.decode(ret, (uint256)), 7.75 ether);
        assertEq(nft.ownerOf(1), recipient);
        assertEq(royalty.balance, 0.3875 ether);
        assertEq(seller.balance, 7.3625 ether);
        assertEq(buyer.balance, 100 ether - 7.75 ether); // 0.25 ETH refunded
        assertEq(address(order).balance, 0);
        assertTrue(order.closed());
    }

    function test_priceHoldsAtEnd() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        skip(10_000);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 1 ether);
    }

    function test_underpaymentReverts() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.Underpaid.selector, 10 ether, 9 ether));
        order.fill{value: 9 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), address(order));
    }

    function test_soldOrderCannotSellAgain() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        // Even if the NFT comes back to the order address, the sale is over.
        vm.prank(buyer);
        nft.transferFrom(buyer, address(order), 1);
        vm.prank(attacker);
        vm.expectRevert(Order.OrderClosed.selector);
        order.fill{value: 10 ether}(config, abi.encode(attacker));
    }

    function test_cancelAndRecover() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        vm.startPrank(seller);
        order.close();
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), seller);

        vm.prank(buyer);
        vm.expectRevert(Order.OrderClosed.selector);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
    }

    /// While the sale is active its NFT stays committed to it: the owner cannot withdraw it
    /// without closing, so an open sale never points at an NFT taken out from under it.
    function test_ownerCannotWithdrawWhileActive() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        vm.prank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        assertEq(nft.ownerOf(1), address(order));
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 10 ether);
    }

    /// The sale moves the NFT out of the order, so it completes only if the order holds it. An
    /// order that was merely approved, or never received the NFT, cannot sell.
    function test_saleRequiresTheOrderToHoldTheNFT() public {
        nft.mint(seller, 1);
        bytes memory config = abi.encode(_dutchConfig(1, seller));
        Order order = _create(seller, dutch, config);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 10 ether}(config, abi.encode(buyer));

        vm.prank(seller);
        nft.approve(address(order), 1);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), seller);
        assertEq(buyer.balance, 100 ether);
    }

    function test_onlyOwnerRecovers() public {
        (Order order,) = _listDutch(seller, 1);
        bytes memory take = abi.encodeCall(IERC721.transferFrom, (address(order), attacker, 1));
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        order.close();
        vm.prank(seller);
        order.close();
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(nft), 0, take);
        vm.prank(address(dutch));
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(nft), 0, take);
        assertEq(nft.ownerOf(1), address(order));
    }

    /// The buyer cannot change the price, the NFT or the payees: they are committed in config.
    function test_buyerCannotRewriteTerms() public {
        (Order order,) = _listDutch(seller, 1);
        DutchAuction.Config memory cheap = _dutchConfig(1, attacker);
        cheap.startPrice = 0;
        cheap.endPrice = 0;
        vm.prank(attacker);
        vm.expectRevert(Order.WrongConfig.selector);
        order.fill(abi.encode(cheap), abi.encode(attacker));
    }

    /// A payee that tries to buy again from inside its payment is stopped by the order's lock.
    function test_payeeCannotReenter() public {
        nft.mint(seller, 1);
        Reenterer payee = new Reenterer();
        DutchAuction.Config memory c = _dutchConfig(1, address(payee));
        bytes memory config = abi.encode(c);
        Order order = _create(seller, dutch, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);
        payee.arm(address(order), abi.encodeCall(Order.fill, (config, abi.encode(address(payee)))));

        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        assertTrue(payee.attempted());
        assertFalse(payee.succeeded());
        assertEq(nft.ownerOf(1), buyer);
        assertEq(address(payee).balance, 10 ether);
    }

    /// Documented risk: a payee that rejects ETH blocks the sale. The creator chose the payees.
    function test_rejectingPayeeBlocksSale() public {
        nft.mint(seller, 1);
        bytes memory config = abi.encode(_dutchConfig(1, address(new Rejecter())));
        Order order = _create(seller, dutch, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), address(order));
    }

    function test_payeesMustTotalFullAmount() public {
        nft.mint(seller, 1);
        DutchAuction.Config memory c = _dutchConfig(1, seller);
        c.payees = new HandlerBase.Payee[](2);
        c.payees[0] = HandlerBase.Payee(seller, 6000);
        c.payees[1] = HandlerBase.Payee(royalty, 3000);
        bytes memory config = abi.encode(c);
        Order order = _create(seller, dutch, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);
        vm.prank(buyer);
        vm.expectRevert(HandlerBase.BadPayees.selector);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
    }

    function testFuzz_priceIsMonotoneAndBounded(uint96 start, uint96 end, uint32 duration, uint32 t1, uint32 t2)
        public
        view
    {
        vm.assume(start >= end && duration > 0);
        DutchAuction.Config memory c = _dutchConfig(1, seller);
        (c.startPrice, c.endPrice, c.startTime, c.endTime) = (start, end, 5000, 5000 + uint256(duration));
        (uint256 a, uint256 b) = t1 <= t2 ? (t1, t2) : (t2, t1);
        uint256 pa = dutch.price(c, a);
        uint256 pb = dutch.price(c, b);
        assertGe(pa, pb);
        assertLe(pa, start);
        assertGe(pb, end);
    }

    function testFuzz_buyerPaysExactlyPriceAndGetsChange(uint32 elapsed, uint96 extra) public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        DutchAuction.Config memory c = abi.decode(config, (DutchAuction.Config));
        skip(elapsed);
        uint256 p = dutch.price(c, block.timestamp);
        vm.deal(buyer, p + extra);
        vm.prank(buyer);
        order.fill{value: p + extra}(config, abi.encode(buyer));
        assertEq(buyer.balance, extra);
        assertEq(seller.balance, p);
        assertEq(nft.ownerOf(1), buyer);
    }
}
