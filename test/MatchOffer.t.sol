// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Base.t.sol";

/// Phase 0 gate: a real signed OpenSea offer, with OpenSea's real zone signature
/// and signer, settles atomically against a declining Market listing.
abstract contract MatchOfferTest is Base {
    bytes sellBlob;

    function sell() internal view returns (AdvancedOrder memory) {
        return abi.decode(sellBlob, (AdvancedOrder));
    }

    function fixtureName() internal pure virtual returns (string memory);

    function setUp() public {
        loadFixture(fixtureName());
        deployMarketAtSignedFulfiller();
        uint256 available = bidAvailable();
        // Declining 1.2x -> 0.6x of the bid's available WETH over two days; now at
        // the midpoint, so the current minimum is 0.9x and the bid has surplus.
        sellBlob = abi.encode(listing(available * 12 / 10, available * 6 / 10, block.timestamp - 1 days, block.timestamp + 1 days, 1));
    }

    function test_matchRealOffer() public {
        address bidder = bid().parameters.offerer;
        ConsiderationItem[] memory fees = bid().parameters.consideration;
        uint256 offerAmount = bid().parameters.offer[0].endAmount;
        uint256 available = bidAvailable();
        uint256 minimum = market.currentPrice(sell().parameters);

        uint256[] memory feeBefore = new uint256[](fees.length);
        for (uint256 i = 1; i < fees.length; i++) {
            feeBefore[i] = WETH.balanceOf(fees[i].recipient);
        }
        uint256 bidderBefore = WETH.balanceOf(bidder);
        uint256 sellerBefore = WETH.balanceOf(seller.addr);
        uint256 marketEthBefore = address(market).balance; // etched over an EOA that held ETH

        vm.prank(keeper);
        uint256 gas = gasleft();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
        gas -= gasleft();
        emit log_named_uint("matchOffer gas", gas);

        uint256 executorFee = available * 30 / 10_000;
        uint256 protocolFee = available * 20 / 10_000;
        assertEq(IERC721(nft).ownerOf(tokenId), fees[0].recipient, "nft to bidder");
        assertEq(bidderBefore - WETH.balanceOf(bidder), offerAmount, "bidder paid offer");
        for (uint256 i = 1; i < fees.length; i++) {
            assertEq(WETH.balanceOf(fees[i].recipient) - feeBefore[i], fees[i].endAmount, "bid fee paid");
        }
        uint256 sellerGot = WETH.balanceOf(seller.addr) - sellerBefore;
        assertEq(sellerGot, available - executorFee - protocolFee, "seller net");
        assertGt(sellerGot, minimum, "surplus to seller");
        assertEq(WETH.balanceOf(keeper), executorFee, "executor fee");
        assertEq(WETH.balanceOf(protocol), protocolFee, "protocol fee");
        assertEq(WETH.balanceOf(address(market)), 0, "no WETH left");
        assertEq(address(market).balance, marketEthBefore, "no ETH moved");

        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
    }

    function test_revertWhenOfferBelowMinimumPlusFees() public {
        uint256 available = bidAvailable();
        // Minimum equals what the bid releases, leaving nothing for fees.
        AdvancedOrder memory tight = listing(available, available, block.timestamp - 1, block.timestamp + 1 days, 2);
        vm.expectRevert();
        market.matchOffer(tight, bid(), resolvers(), fulfillments());

        // Exactly enough: seller gets the minimum, fees take the remaining 0.5%.
        uint256 minimum = available - available * 50 / 10_000;
        AdvancedOrder memory exact = listing(minimum, minimum, block.timestamp - 1, block.timestamp + 1 days, 3);
        uint256 before = WETH.balanceOf(seller.addr);
        market.matchOffer(exact, bid(), resolvers(), fulfillments());
        assertEq(WETH.balanceOf(seller.addr) - before, minimum);
    }

    function test_revertWhenListingCancelled() public {
        OrderComponents[] memory c = new OrderComponents[](1);
        uint256 available = bidAvailable();
        c[0] = components(available * 12 / 10, available * 6 / 10, block.timestamp - 1 days, block.timestamp + 1 days, 1);
        vm.prank(seller.addr);
        SEAPORT.cancel(c);
        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
    }

    function test_revertWhenListingExpired() public {
        AdvancedOrder memory short = listing(1, 1, block.timestamp - 1, block.timestamp + 10, 4);
        vm.warp(block.timestamp + 10);
        vm.expectRevert(Market.NotListing.selector);
        market.matchOffer(short, bid(), resolvers(), fulfillments());
    }

    function test_revertWhenZoneSignatureExpired() public {
        uint64 expiration = uint64(bytes8(this.slice(bid().extraData, 21, 29)));
        vm.warp(expiration + 1);
        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
    }

    function test_revertWhenSellerRevokedApproval() public {
        vm.prank(seller.addr);
        IERC721Full(nft).setApprovalForAll(OS_CONDUIT, false);
        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
        assertEq(IERC721(nft).ownerOf(tokenId), seller.addr);
    }

    function test_revertWhenSellerNoLongerOwns() public {
        vm.prank(seller.addr);
        IERC721Full(nft).transferFrom(seller.addr, makeAddr("elsewhere"), tokenId);
        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
    }

    function test_revertWhenBidderLacksWeth() public {
        address bidder = bid().parameters.offerer;
        uint256 balance = WETH.balanceOf(bidder);
        vm.prank(bidder);
        WETH.transfer(makeAddr("elsewhere"), balance);
        vm.expectRevert();
        market.matchOffer(sell(), bid(), resolvers(), fulfillments());
        assertEq(IERC721(nft).ownerOf(tokenId), seller.addr, "nft stays with seller");
    }

    /// The zone signature binds the fulfiller: the same bid cannot be routed
    /// through a Market at any other address.
    function test_revertWhenFulfillerDiffers() public {
        Market other = new Market(protocol);
        uint256 available = bidAvailable();
        market = other;
        AdvancedOrder memory l = listing(available / 2, available / 2, block.timestamp - 1, block.timestamp + 1 days, 5);
        vm.expectRevert();
        other.matchOffer(l, bid(), resolvers(), fulfillments());
    }

    /// Market-zone listings cannot be filled by calling Seaport directly.
    function test_listingOnlyFillableThroughMarket() public {
        address buyer = makeAddr("buyer");
        deal(address(WETH), buyer, 100 ether);
        vm.startPrank(buyer);
        WETH.approve(address(SEAPORT), type(uint256).max);
        vm.expectRevert();
        SEAPORT.fulfillAdvancedOrder(sell(), new CriteriaResolver[](0), bytes32(0), buyer);
        vm.stopPrank();
        assertEq(IERC721(nft).ownerOf(tokenId), seller.addr);
    }
}

contract MatchCollectionOfferWithRoyalty is MatchOfferTest {
    function fixtureName() internal pure override returns (string memory) {
        return "collection_offer_royalty";
    }
}

contract MatchItemOffer is MatchOfferTest {
    function fixtureName() internal pure override returns (string memory) {
        return "item_offer";
    }
}
