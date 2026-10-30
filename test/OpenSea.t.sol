// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base, IERC721Safe} from "./Base.t.sol";
import {Market} from "../contracts/Market.sol";
import {AdvancedOrder, ConsiderationItem, CriteriaResolver} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {Vm} from "forge-std/Test.sol";

/// Real signed OpenSea offers, with OpenSea's real zone signature, filled from escrow
/// through `Market.fillOffer` (Seaport `fulfillAdvancedOrder`). The fixtures come from
/// mainnet `matchAdvancedOrders` fills, so passing here also shows that zone data
/// OpenSea signed for its match shape works for direct fulfillment.
abstract contract OpenSeaTest is Base {
    function fixture() internal pure virtual returns (string memory);

    function setUp() public {
        loadFixture(fixture());
        deployMarketAtSignedFulfiller();
    }

    function price() internal view returns (uint256) {
        return bid().parameters.offer[0].endAmount;
    }

    function fees() internal view returns (uint256 protocolFee, uint256 executorFee) {
        protocolFee = price() * 20 / 10_000;
        executorFee = price() * 30 / 10_000;
    }

    function expectedProceeds() internal view returns (uint256) {
        (uint256 p, uint256 e) = fees();
        return bidAvailable() - p - e;
    }

    function test_fillRealOffer() public {
        Market.Listing memory l = terms(expectedProceeds() * 9 / 10);
        uint256 id = list(l);
        assertEq(IERC721Safe(nft).ownerOf(tokenId), address(market), "escrowed");

        AdvancedOrder memory offer = bid();
        address bidder = offer.parameters.offerer;
        ConsiderationItem[] memory c = offer.parameters.consideration;
        uint256[] memory feeBefore = new uint256[](c.length);
        for (uint256 i = 1; i < c.length; i++) {
            feeBefore[i] = WETH.balanceOf(c[i].recipient);
        }
        uint256 bidderBefore = WETH.balanceOf(bidder);

        vm.prank(keeper);
        Market.Quote memory q = market.fillOffer(l, id, offer, resolvers());

        (uint256 protocolFee, uint256 executorFee) = fees();
        assertEq(IERC721Safe(nft).ownerOf(tokenId), c[0].recipient, "nft to bidder");
        assertEq(bidderBefore - WETH.balanceOf(bidder), price(), "bidder pays the offer");
        for (uint256 i = 1; i < c.length; i++) {
            assertEq(WETH.balanceOf(c[i].recipient) - feeBefore[i], c[i].endAmount, "offer fee item");
        }
        assertEq(WETH.balanceOf(seller.addr), expectedProceeds(), "seller gets the rest");
        assertEq(WETH.balanceOf(keeper), executorFee, "executor fee");
        assertEq(WETH.balanceOf(protocol), protocolFee, "protocol fee");
        assertEq(WETH.balanceOf(address(market)), 0, "nothing left");
        assertEq(q.price, price());
        assertEq(q.proceeds, expectedProceeds());
        assertEq(q.royalty, 0, "offer consideration settles royalty");

        (bytes32 h,,,) = market.orders(id);
        assertEq(h, bytes32(0), "listing consumed");
        vm.expectRevert(Market.NotActive.selector);
        market.fillOffer(l, id, offer, resolvers());
    }

    function test_exactBoundaryFills() public {
        Market.Listing memory l = terms(expectedProceeds());
        uint256 id = list(l);
        vm.prank(keeper);
        market.fillOffer(l, id, bid(), resolvers());
        assertEq(WETH.balanceOf(seller.addr), expectedProceeds());
    }

    function test_revertWhenAskAboveProceeds() public {
        Market.Listing memory l = terms(expectedProceeds() + 1);
        uint256 id = list(l);
        AdvancedOrder memory offer = bid();
        vm.prank(keeper);
        vm.expectRevert(Market.ProceedsBelowMinimum.selector);
        market.fillOffer(l, id, offer, resolvers());
        assertEq(IERC721Safe(nft).ownerOf(tokenId), address(market), "still escrowed");
        (bytes32 h,,,) = market.orders(id);
        assertEq(h, market.hashListing(l), "still listed");
    }

    function test_revertWhenCancelled() public {
        Market.Listing memory l = terms(1);
        uint256 id = list(l);
        vm.prank(seller.addr);
        market.cancelListing(l, id);
        AdvancedOrder memory offer = bid();
        vm.expectRevert(Market.NotActive.selector);
        market.fillOffer(l, id, offer, resolvers());
        vm.prank(seller.addr);
        market.withdrawListing(l, id, seller.addr);
        assertEq(IERC721Safe(nft).ownerOf(tokenId), seller.addr);
    }

    function test_revertWhenZoneSignatureExpired() public {
        Market.Listing memory l = terms(1);
        uint256 id = list(l);
        AdvancedOrder memory offer = bid();
        uint64 expiration = uint64(bytes8(this.slice(offer.extraData, 21, 29)));
        vm.warp(expiration + 1);
        vm.expectRevert();
        market.fillOffer(l, id, offer, resolvers());
        assertEq(IERC721Safe(nft).ownerOf(tokenId), address(market));
    }

    function test_revertWhenZoneDisabled() public {
        Market.Listing memory l = terms(1);
        uint256 id = list(l);
        vm.prank(admin);
        market.setZone(OS_ZONE, false);
        AdvancedOrder memory offer = bid();
        vm.expectRevert(Market.Incompatible.selector);
        market.fillOffer(l, id, offer, resolvers());
    }

    function test_onlyOwnerSetsZones() public {
        vm.expectRevert(Market.Unauthorized.selector);
        market.setZone(address(0), true);
    }

    /// Escrowed bid budgets must not fund an offer's consideration. The zone check is
    /// relaxed to reach Seaport with a synthetic offer that tries to take more WETH out
    /// of Market than it puts in.
    function test_revertWhenOfferWouldSpendEscrow() public {
        _escrowBudget(5 ether);
        Market.Listing memory l = terms(0);
        uint256 id = list(l);
        Vm.Wallet memory thief = vm.createWallet("thief");
        ConsiderationItem[] memory c = new ConsiderationItem[](2);
        c[0] = ConsiderationItem(ItemType.ERC721, nft, tokenId, 1, 1, payable(thief.addr));
        c[1] = ConsiderationItem(ItemType.ERC20, address(WETH), 0, 3 ether, 3 ether, payable(thief.addr));
        AdvancedOrder memory offer = syntheticBid(thief, 1 ether, c);
        vm.prank(admin);
        market.setZone(address(0), true);
        vm.expectRevert(); // arithmetic underflow on Market's balance change
        market.fillOffer(l, id, offer, new CriteriaResolver[](0));
        assertEq(WETH.balanceOf(address(market)), 5 ether, "escrow intact");
        assertEq(IERC721Safe(nft).ownerOf(tokenId), address(market));
    }

    /// An offer cannot pull a different escrowed NFT: Market approves only the listed one.
    function test_revertWhenOfferAsksForAnotherNft() public {
        Market.Listing memory l = terms(0);
        uint256 id = list(l);
        Vm.Wallet memory thief = vm.createWallet("thief");
        ConsiderationItem[] memory c = new ConsiderationItem[](1);
        c[0] = ConsiderationItem(ItemType.ERC721, nft, tokenId + 1, 1, 1, payable(thief.addr));
        AdvancedOrder memory offer = syntheticBid(thief, 1 ether, c);
        vm.prank(admin);
        market.setZone(address(0), true);
        vm.expectRevert();
        market.fillOffer(l, id, offer, new CriteriaResolver[](0));
        assertEq(IERC721Safe(nft).ownerOf(tokenId), address(market));
    }

    /// A synthetic offer that pays well and delivers the listed NFT settles exactly.
    function test_syntheticOfferSplits() public {
        Market.Listing memory l = terms(0.5 ether);
        uint256 id = list(l);
        Vm.Wallet memory buyer = vm.createWallet("buyer");
        ConsiderationItem[] memory c = new ConsiderationItem[](2);
        c[0] = ConsiderationItem(ItemType.ERC721, nft, tokenId, 1, 1, payable(buyer.addr));
        c[1] = ConsiderationItem(ItemType.ERC20, address(WETH), 0, 0.01 ether, 0.01 ether, payable(makeAddr("osfee")));
        AdvancedOrder memory offer = syntheticBid(buyer, 1 ether, c);
        vm.prank(admin);
        market.setZone(address(0), true);
        vm.prank(keeper);
        market.fillOffer(l, id, offer, new CriteriaResolver[](0));
        assertEq(WETH.balanceOf(seller.addr), 0.99 ether - 0.005 ether);
        assertEq(WETH.balanceOf(keeper), 0.003 ether);
        assertEq(WETH.balanceOf(protocol), 0.002 ether);
        assertEq(WETH.balanceOf(address(market)), 0);
    }

    function test_revertAtUnsignedMarketAddress() public {
        // A Market at any other address is not the fulfiller OpenSea signed for.
        deployMarket();
        Market.Listing memory l = terms(1);
        uint256 id = list(l);
        AdvancedOrder memory offer = bid();
        vm.expectRevert();
        market.fillOffer(l, id, offer, resolvers());
    }

    function _escrowBudget(uint256 amount) internal {
        address buyer = makeAddr("bidder");
        vm.deal(buyer, amount);
        Market.Bid memory b;
        b.recipient = buyer;
        b.nft = nft;
        b.maxTokenId = type(uint256).max;
        b.currency = address(WETH);
        b.budget = uint128(amount);
        b.maxPrice = uint128(amount);
        b.quantity = 1;
        b.expiry = uint40(block.timestamp + 1 days);
        vm.prank(buyer);
        market.createBid{value: amount}(b);
    }
}

contract ItemOfferTest is OpenSeaTest {
    function fixture() internal pure override returns (string memory) {
        return "item_offer";
    }
}

contract CollectionOfferRoyaltyTest is OpenSeaTest {
    function fixture() internal pure override returns (string memory) {
        return "collection_offer_royalty";
    }
}
