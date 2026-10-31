// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base, IERC721Safe} from "./Base.t.sol";
import {Market} from "../contracts/Market.sol";
import {console} from "forge-std/Test.sol";

/// Execution gas of each path with real WETH and a real NFT (Otherdeed) on a pinned
/// fork. Measured with gasleft around the call: excludes the 21,000 base and calldata.
/// Cold storage applies because each measured call is the first to touch its slots.
contract GasTest is Base {
    address bidder = makeAddr("bidder");

    function setUp() public {
        loadFixture("item_offer");
        deployMarketAtSignedFulfiller();
    }

    function _bid(uint256 budget, uint256 maxPrice) internal returns (uint256 id, Market.Bid memory b) {
        b.recipient = bidder;
        b.nft = nft;
        b.maxTokenId = type(uint256).max;
        b.currency = address(WETH);
        b.budget = uint128(budget);
        b.maxPrice = uint128(maxPrice);
        b.quantity = 1;
        b.expiry = uint40(block.timestamp + 1 days);
        b.price = Market.Price(uint128(maxPrice), uint128(maxPrice), 0, 0, address(0), 0);
        vm.deal(bidder, budget);
        vm.prank(bidder);
        uint256 g = gasleft();
        id = market.createBid{value: budget}(b);
        console.log("createBid (ETH funded)", g - gasleft());
        b.buyer = bidder;
    }

    function _list(uint256 floor) internal returns (uint256 id, Market.Listing memory l) {
        l = terms(floor);
        bytes memory data = abi.encodePacked(bytes1(0x00), abi.encode(l));
        vm.prank(seller.addr);
        uint256 g = gasleft();
        IERC721Safe(nft).safeTransferFrom(seller.addr, address(market), tokenId, data);
        console.log("list (safeTransferFrom deposit)", g - gasleft());
        id = market.lastId();
        (l.seller, l.nft, l.tokenId) = (seller.addr, nft, tokenId);
    }

    function test_gasBuy() public {
        (uint256 id, Market.Listing memory l) = _list(0.1 ether);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 g = gasleft();
        market.buy{value: 0.2 ether}(l, id, 0.2 ether, address(0), address(0));
        console.log("buy (ETH, refund as WETH)", g - gasleft());
    }

    function test_gasCancelWithdraw() public {
        (uint256 id, Market.Listing memory l) = _list(0.1 ether);
        vm.startPrank(seller.addr);
        uint256 g = gasleft();
        market.cancelListing(l, id);
        console.log("cancelListing", g - gasleft());
        g = gasleft();
        market.withdrawListing(l, id, seller.addr);
        console.log("withdrawListing", g - gasleft());
        vm.stopPrank();
    }

    function test_gasMatchBid() public {
        (uint256 listingId, Market.Listing memory l) = _list(0.1 ether);
        (uint256 bidId, Market.Bid memory b) = _bid(1 ether, 0.2 ether);
        vm.prank(keeper);
        uint256 g = gasleft();
        market.matchBid(l, listingId, b, bidId);
        console.log("matchBid", g - gasleft());
    }

    function test_gasSellIntoBid() public {
        (uint256 bidId, Market.Bid memory b) = _bid(1 ether, 0.2 ether);
        bytes memory data = abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, uint256(0), address(0)));
        vm.prank(seller.addr);
        uint256 g = gasleft();
        IERC721Safe(nft).safeTransferFrom(seller.addr, address(market), tokenId, data);
        console.log("sell into bid (safeTransferFrom)", g - gasleft());
        vm.prank(bidder);
        g = gasleft();
        market.withdrawBid(b, bidId, bidder);
        console.log("withdrawBid", g - gasleft());
    }

    function test_gasFillOffer() public {
        (uint256 id, Market.Listing memory l) = _list(0.01 ether);
        vm.prank(keeper);
        uint256 g = gasleft();
        market.fillOffer(l, id, bid(), resolvers());
        console.log("fillOffer (real OpenSea item offer)", g - gasleft());
    }
}
