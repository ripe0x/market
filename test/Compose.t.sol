// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// Anyone's contract, written without either order owner's involvement: buys from a sale and
/// sells into a bid in one transaction. It fronts the purchase with the ETH it is sent, keeps
/// nothing, and requires at least `minProfit`; otherwise everything reverts.
contract Matcher {
    function matchSaleToBid(
        Order saleOrder,
        bytes calldata saleConfig,
        uint256 maxPrice,
        Order bidOrder,
        bytes calldata bidConfig,
        IERC721 nft,
        uint256 id,
        uint256 minProceeds,
        uint256 minProfit
    ) external payable {
        uint256 start = address(this).balance - msg.value;
        saleOrder.fill{value: msg.value}(saleConfig, abi.encode(address(this), maxPrice));
        // NFTBid takes the token under an approval to the handler, never to the bid's order.
        nft.approve(address(bidOrder.handler()), id);
        bidOrder.fill(bidConfig, abi.encode(id, minProceeds, address(this)));
        uint256 out = address(this).balance - start;
        require(out >= msg.value + minProfit, "unprofitable");
        (bool ok,) = msg.sender.call{value: out}("");
        require(ok);
    }

    receive() external payable {}
}

/// A buyer that does not trust the seller's handler: it fills, then checks it owns the NFT.
contract GuardedBuyer {
    function buy(Order order, bytes calldata config, bytes calldata input, IERC721 nft, uint256 id) external payable {
        order.fill{value: msg.value}(config, input);
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

    function handler() external view returns (address) {
        return address(this);
    }
}

/// Composition through the supported handlers. A falling NFTSale and a funded, rising NFTBid
/// are created by two strangers. Neither knows the other exists. When their prices cross, a
/// third party settles both in one transaction; each order enforces its own terms and the
/// matcher enforces its own.
contract ComposeTest is Base {
    RoyaltyNFT art;
    Matcher matcher;
    address bidder = makeAddr("bidder");
    address vault = makeAddr("vault");
    address keeper = makeAddr("keeper");

    Order saleOrder;
    bytes saleConfig;
    Order bidOrder;
    bytes bidConfig;

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500); // 5%
        matcher = new Matcher();
        vm.deal(keeper, 10 ether);
        vm.deal(bidder, 10 ether);

        // Seller: token 1, from 10 ETH down to 1 ETH over 1,000 seconds, royalty up to 10%.
        art.mint(seller, 1);
        saleConfig = abi.encode(
            NFTSale.Config(
                art, 1, NFTTrade.Schedule(10 ether, 1 ether, block.timestamp, block.timestamp + 1000, 0), seller, 1000
            )
        );
        saleOrder = _create(seller, sale, saleConfig);
        vm.prank(seller);
        art.transferFrom(seller, address(saleOrder), 1);

        // Bidder, separately: any token of the collection, from 2 ETH up to 6 ETH over the
        // same period, funded with 6 ETH, delivered to the bidder's vault.
        bidConfig = abi.encode(
            NFTBid.Config(
                art, true, 0, NFTTrade.Schedule(2 ether, 6 ether, block.timestamp, block.timestamp + 1000, 0), vault, 1
            )
        );
        vm.prank(bidder);
        bidOrder = market.create{value: 6 ether}(bids, bidConfig, 0);
    }

    function _match(uint256 pay, uint256 maxPrice, uint256 minProceeds, uint256 minProfit) internal {
        vm.prank(keeper);
        matcher.matchSaleToBid{value: pay}(
            saleOrder, saleConfig, maxPrice, bidOrder, bidConfig, art, 1, minProceeds, minProfit
        );
    }

    function _assertUntouched() internal view {
        assertEq(art.ownerOf(1), address(saleOrder));
        assertEq(address(bidOrder).balance, 6 ether);
        assertEq(keeper.balance, 10 ether);
        assertEq(seller.balance, 0);
        assertEq(royalty.balance, 0);
        assertFalse(saleOrder.closed());
        assertFalse(bidOrder.closed());
    }

    function test_matchCrossingSaleAndBid() public {
        // t=600: ask 4.6 ETH, bid 4.4 ETH (4.18 to its seller after royalty). Not crossed: the
        // whole match reverts and nothing moves.
        skip(600);
        vm.expectRevert("unprofitable");
        _match(4.6 ether, 4.6 ether, 0, 0);
        _assertUntouched();

        // t=700: ask 3.7 ETH, bid 4.8 ETH. Crossed.
        skip(100);
        (uint256 ask,, uint256 saleRoyalty) = sale.quote(abi.decode(saleConfig, (NFTSale.Config)));
        (uint256 offer,, uint256 bidRoyalty) = bids.quote(address(bidOrder), abi.decode(bidConfig, (NFTBid.Config)), 1);
        assertEq(ask, 3.7 ether);
        assertEq(offer, 4.8 ether);
        assertEq(saleRoyalty, 0.185 ether);
        assertEq(bidRoyalty, 0.24 ether);

        _match(ask, ask, offer - bidRoyalty, 0.8 ether);

        assertEq(art.ownerOf(1), vault, "bidder's recipient holds the token");
        assertEq(seller.balance, 3.7 ether - 0.185 ether, "seller proceeds: ask less royalty");
        assertEq(address(bidOrder).balance, 6 ether - 4.8 ether, "bidder spent exactly the bid");
        assertEq(royalty.balance, 0.185 ether + 0.24 ether, "royalty paid on both sales");
        assertEq(keeper.balance, 10 ether + 4.56 ether - 3.7 ether, "matcher keeps the spread");
        assertEq(address(matcher).balance, 0);
        assertTrue(saleOrder.closed());
        assertTrue(bidOrder.closed(), "a one-token bid closes after its fill");

        // The bidder recovers the unspent ETH from the closed bid.
        vm.prank(bidder);
        bidOrder.execute(bidder, 1.2 ether, "");
        assertEq(bidder.balance, 10 ether - 6 ether + 1.2 ether);
    }

    /// Each party's own limit reverts the whole match, the other order's fill included.
    function test_eachLimitRevertsTheWholeMatch() public {
        skip(700); // ask 3.7, bid 4.8, 4.56 to its seller

        // Buyer's limit on the sale.
        vm.expectRevert(abi.encodeWithSelector(NFTSale.AboveMaxPrice.selector, 3.7 ether, 3.6 ether));
        _match(3.7 ether, 3.6 ether, 0, 0);
        // Seller's limit on the bid.
        vm.expectRevert(abi.encodeWithSelector(NFTBid.BelowMinProceeds.selector, 4.56 ether, 4.6 ether));
        _match(3.7 ether, 3.7 ether, 4.6 ether, 0);
        // Matcher's own profit requirement.
        vm.expectRevert("unprofitable");
        _match(3.7 ether, 3.7 ether, 0, 1 ether);
        // Underpaying the sale.
        vm.expectRevert(abi.encodeWithSelector(NFTSale.Underpaid.selector, 3.7 ether, 3 ether));
        _match(3 ether, 3.7 ether, 0, 0);
        _assertUntouched();
    }

    /// The bid can pay only what its order holds: the bidder's expenditure limit.
    function test_underfundedBidRevertsTheWholeMatch() public {
        bytes memory config = abi.encode(
            NFTBid.Config(art, true, 0, NFTTrade.Schedule(4.8 ether, 4.8 ether, block.timestamp, block.timestamp, 0), vault, 1)
        );
        vm.prank(bidder);
        bidOrder = market.create{value: 4 ether}(bids, config, bytes32("thin"));
        bidConfig = config;
        skip(700);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.InsufficientFunds.selector, 4.8 ether, 4 ether));
        _match(3.7 ether, 3.7 ether, 0, 0);
        assertEq(art.ownerOf(1), address(saleOrder));
        assertEq(address(bidOrder).balance, 4 ether);
    }

    /// A counterparty that claims to have delivered cannot get paid: the bid checks delivery
    /// itself, so the matcher's whole transaction reverts and its ETH stays put.
    function test_counterfeitSaleCannotFoolTheBid() public {
        skip(700);
        CounterfeitOrder fake = new CounterfeitOrder();
        vm.prank(keeper);
        vm.expectRevert();
        matcher.matchSaleToBid{value: 1 ether}(Order(payable(address(fake))), "", 0, bidOrder, bidConfig, art, 1, 0, 0);
        assertEq(keeper.balance, 10 ether);
        assertEq(address(bidOrder).balance, 6 ether);
    }

    /// Market does not protect a filler from the handler it chose to trust. An EOA that pays a
    /// dishonest handler loses its ETH; a filler that states its own receipt condition does not.
    function test_fillerProtectsItselfAgainstDishonestHandler() public {
        nft.mint(seller, 2);
        Order order = _create(seller, new ClaimsDeliveryHandler(), "");
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 2);

        GuardedBuyer guarded = new GuardedBuyer();
        vm.prank(buyer);
        vm.expectRevert("not delivered");
        guarded.buy{value: 1 ether}(order, "", "", nft, 2);
        assertEq(buyer.balance, 100 ether);

        vm.prank(buyer);
        bytes memory claimed = order.fill{value: 1 ether}("", "");
        assertEq(abi.decode(claimed, (uint256)), 1 ether); // "success"
        assertEq(nft.ownerOf(2), address(order)); // but nothing was delivered
        assertEq(buyer.balance, 99 ether);
    }

    /// A known handler is itself a receipt guarantee: NFTSale always delivers or reverts, so
    /// the same guarded buyer succeeds against it.
    function test_guardedBuyerAgainstHonestHandler() public {
        (Order order, bytes memory config) = _listSale(seller, 2, 1 ether);
        GuardedBuyer guarded = new GuardedBuyer();
        vm.prank(buyer);
        guarded.buy{value: 1 ether}(order, config, abi.encode(address(guarded), 1 ether), nft, 2);
        assertEq(nft.ownerOf(2), address(guarded));
    }
}
