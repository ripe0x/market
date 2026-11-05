// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {AcquisitionBid} from "../examples/AcquisitionBid.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {Base} from "./utils/Base.sol";

/// Anyone's contract: buys from one order and sells into another in one transaction. It
/// fronts the purchase with the ETH it is sent and keeps nothing. Its own receipt condition
/// is that it ends with at least as much ETH as it started with.
contract Matcher {
    function matchSaleToBid(
        Order sale,
        bytes calldata saleConfig,
        Order bid,
        bytes calldata bidConfig,
        IERC721 nft,
        uint256 id,
        uint256 bidPrice
    ) external payable {
        sale.fill{value: msg.value}(saleConfig, abi.encode(address(this)));
        nft.approve(address(bid), id);
        bid.fill(bidConfig, abi.encode(id, bidPrice));
        require(address(this).balance >= msg.value, "unprofitable");
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

/// A buyer that does not trust the seller's handler: it fills, then checks it owns the NFT.
contract GuardedBuyer {
    function buy(Order order, bytes calldata config, IERC721 nft, uint256 id) external payable {
        order.fill{value: msg.value}(config, abi.encode(address(this)));
        require(nft.ownerOf(id) == address(this), "not delivered");
    }

    receive() external payable {}
}

/// A genuine Market order whose creator wrote a dishonest handler: it keeps the ETH and
/// reports a successful sale.
contract ClaimsDeliveryHandler is IOrderHandler {
    function onFill(address, uint256 value, bytes calldata, bytes calldata) external pure returns (bytes memory) {
        return abi.encode(value);
    }
}

/// Not an order at all, but shaped like one.
contract CounterfeitOrder {
    function fill(bytes calldata, bytes calldata) external payable returns (bytes memory) {
        return abi.encode(msg.value);
    }
}

contract ComposeTest is Base {
    Matcher matcher;
    address keeper = makeAddr("keeper");
    address vault = makeAddr("vault");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        matcher = new Matcher();
        vm.deal(keeper, 10 ether);
        vm.deal(operator, 10 ether);
    }

    function _bid(uint256 capital) internal returns (Order bid, bytes memory config) {
        config = _bidConfig(vault, 10 ether, rising, _risingParams(2 ether, 0.01 ether, 5000), address(0));
        vm.prank(operator);
        bid = market.create{value: capital}(acquisition, config, 0);
    }

    /// A falling sale and a rising bid were written by different people with different
    /// handlers. When they cross, anyone can settle them together; each order enforces its
    /// own terms and the matcher enforces its own.
    function test_matchCrossingSaleAndBid() public {
        (Order sale, bytes memory saleConfig) = _listDutch(seller, 1); // 10 -> 1 ETH over 1000s
        (Order bid, bytes memory bidConfig) = _bid(5 ether); // 2 ETH rising 0.01/s

        skip(500); // sale at 5.5 ETH, bid at 7 ETH capped by 5 ETH capital
        uint256 ask = dutch.price(abi.decode(saleConfig, (DutchAuction.Config)), block.timestamp);
        uint256 offer = acquisition.currentBid(address(bid), abi.decode(bidConfig, (AcquisitionBid.Config)));
        assertEq(ask, 5.5 ether);
        assertEq(offer, 5 ether);

        // Not crossed yet: the whole match reverts and nothing moves.
        vm.prank(keeper);
        vm.expectRevert();
        matcher.matchSaleToBid{value: ask}(sale, saleConfig, bid, bidConfig, nft, 1, offer);
        assertEq(nft.ownerOf(1), address(sale));

        skip(100); // sale at 4.6 ETH, bid still 5 ETH
        ask = dutch.price(abi.decode(saleConfig, (DutchAuction.Config)), block.timestamp);
        vm.prank(keeper);
        matcher.matchSaleToBid{value: ask}(sale, saleConfig, bid, bidConfig, nft, 1, 5 ether);

        assertEq(nft.ownerOf(1), vault);
        assertEq(seller.balance, 4.6 ether);
        assertEq(keeper.balance, 10 ether + 0.4 ether);
        assertEq(address(bid).balance, 0);
        assertTrue(sale.closed());
        assertEq(address(matcher).balance, 0);
    }

    /// A counterparty that claims to have delivered cannot get paid: the bid checks delivery
    /// itself, so the matcher's whole transaction reverts and its ETH stays put.
    function test_counterfeitSaleCannotFoolTheBid() public {
        (Order bid, bytes memory bidConfig) = _bid(5 ether);
        nft.mint(attacker, 1);
        CounterfeitOrder fake = new CounterfeitOrder();
        vm.prank(keeper);
        vm.expectRevert();
        matcher.matchSaleToBid{value: 1 ether}(Order(payable(address(fake))), "", bid, bidConfig, nft, 1, 2 ether);
        assertEq(keeper.balance, 10 ether);
        assertEq(address(bid).balance, 5 ether);
    }

    /// Market does not protect a filler from the handler it chose to trust. An EOA that pays a
    /// dishonest handler loses its ETH; a filler that states its own receipt condition does not.
    function test_fillerProtectsItselfAgainstDishonestHandler() public {
        nft.mint(seller, 1);
        IOrderHandler liar = new ClaimsDeliveryHandler();
        Order order = _create(seller, liar, "");
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);

        GuardedBuyer guarded = new GuardedBuyer();
        vm.prank(buyer);
        vm.expectRevert("not delivered");
        guarded.buy{value: 1 ether}(order, "", nft, 1);
        assertEq(buyer.balance, 100 ether);

        vm.prank(buyer);
        bytes memory claimed = order.fill{value: 1 ether}("", abi.encode(buyer));
        assertEq(abi.decode(claimed, (uint256)), 1 ether); // "success"
        assertEq(nft.ownerOf(1), address(order)); // but nothing was delivered
        assertEq(buyer.balance, 99 ether);
    }

    /// A known handler is itself a receipt guarantee: DutchAuction always delivers or reverts,
    /// so the same guarded buyer succeeds against it.
    function test_guardedBuyerAgainstHonestHandler() public {
        (Order order, bytes memory config) = _listDutch(seller, 1);
        GuardedBuyer guarded = new GuardedBuyer();
        vm.prank(buyer);
        guarded.buy{value: 10 ether}(order, config, nft, 1);
        assertEq(nft.ownerOf(1), address(guarded));
    }
}
