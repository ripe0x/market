// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../contracts/Market.sol";
import {MockWETH, MockToken, MockNFT, MockStrategy} from "./Mocks.sol";

/// Shared local harness: WETH9 semantics at the canonical WETH address, no fork.
abstract contract Local is Test {
    MockWETH weth;
    MockNFT nft;
    Market market;
    address protocol = makeAddr("protocol");
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address keeper = makeAddr("keeper");
    address artist = makeAddr("artist");

    function setUp() public virtual {
        deployCodeTo("Mocks.sol:MockWETH", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        weth = MockWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        market = new Market(protocol, admin, address(0xdead));
        nft = new MockNFT();
        vm.warp(1_800_000_000);
    }

    function fixedPrice(uint256 amount) internal pure returns (Market.Price memory) {
        return Market.Price(uint128(amount), uint128(amount), 0, 0, address(0), 0);
    }

    function listingTerms(uint256 floor) internal view returns (Market.Listing memory l) {
        l.currency = address(weth);
        l.recipient = seller;
        l.floor = uint128(floor);
        l.expiry = uint40(block.timestamp + 30 days);
        l.price = fixedPrice(floor);
    }

    /// Mint `id` to `from` and list it with `l`. Returns the id and the stored terms.
    function list(address from, uint256 id, Market.Listing memory l) internal returns (uint256, Market.Listing memory) {
        nft.mint(from, id);
        vm.prank(from);
        nft.safeTransferFrom(from, address(market), id, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        (l.seller, l.nft, l.tokenId) = (from, address(nft), id);
        return (market.lastId(), l);
    }

    function bidTerms(uint256 budget, uint256 maxPrice, uint32 quantity) internal view returns (Market.Bid memory b) {
        b.recipient = buyer;
        b.nft = address(nft);
        b.maxTokenId = type(uint256).max;
        b.currency = address(weth);
        b.budget = uint128(budget);
        b.maxPrice = uint128(maxPrice);
        b.quantity = quantity;
        b.expiry = uint40(block.timestamp + 30 days);
        b.price = fixedPrice(maxPrice);
    }

    function createBid(Market.Bid memory b) internal returns (uint256 id, Market.Bid memory) {
        vm.deal(buyer, b.budget);
        vm.prank(buyer);
        id = market.createBid{value: b.budget}(b);
        b.buyer = buyer;
        return (id, b);
    }

    function sellInto(address from, uint256 tokenId, Market.Bid memory b, uint256 bidId, uint256 minProceeds) internal {
        nft.mint(from, tokenId);
        vm.prank(from);
        nft.safeTransferFrom(
            from,
            address(market),
            tokenId,
            abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, minProceeds, address(0)))
        );
    }

    function proceedsAt(uint256 price, uint256 royaltyBps, uint256 executorBps) internal pure returns (uint256) {
        return price - price * royaltyBps / 10_000 - price * 20 / 10_000 - price * executorBps / 10_000;
    }
}

contract ListingTest is Local {
    function test_listEscrowsAndBuyPaysEveryone() public {
        nft.setRoyalty(artist, 500, 0);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        assertEq(nft.ownerOf(1), address(market));

        Market.Quote memory q = market.quoteBuy(l, id);
        assertGe(q.proceeds, 1 ether, "seller minimum is net");
        assertEq(q.royalty, q.price * 500 / 10_000);
        assertEq(q.protocolFee, q.price * 20 / 10_000);
        assertEq(q.price, q.proceeds + q.royalty + q.protocolFee);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        market.buy{value: 2 ether}(l, id, q.price, address(0), address(0));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(weth.balanceOf(seller), q.proceeds);
        assertEq(weth.balanceOf(artist), q.royalty);
        assertEq(weth.balanceOf(protocol), q.protocolFee);
        assertEq(weth.balanceOf(buyer), 2 ether - q.price, "excess back as WETH");
        assertEq(weth.balanceOf(address(market)), 0);

        vm.expectRevert(Market.NotActive.selector);
        market.buy(l, id, q.price, address(0), address(0));
    }

    function test_buyRespectsMaxPrice() public {
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        uint256 p = market.quoteBuy(l, id).price;
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        vm.expectRevert(Market.PriceAboveLimit.selector);
        market.buy{value: 2 ether}(l, id, p - 1, address(0), address(0));
    }

    function test_buyWithTokenAndReferral() public {
        MockToken token = new MockToken();
        token.configure(0, true); // returns nothing, like USDT
        vm.prank(admin);
        market.setCurrency(address(token), true);
        Market.Listing memory t = listingTerms(1000e6);
        t.currency = address(token);
        (uint256 id, Market.Listing memory l) = list(seller, 1, t);
        Market.Quote memory q = market.quoteBuy(l, id);
        token.mint(buyer, q.price);
        vm.startPrank(buyer);
        token.approve(address(market), q.price);
        market.buy(l, id, q.price, address(0), makeAddr("ref"));
        vm.stopPrank();
        assertEq(token.balanceOf(seller), q.proceeds);
        assertEq(token.balanceOf(makeAddr("ref")), q.price * 10 / 10_000);
        assertEq(token.balanceOf(protocol), q.protocolFee - q.price * 10 / 10_000);
    }

    function test_rejectFeeOnTransferToken() public {
        MockToken token = new MockToken();
        token.configure(100, false);
        vm.prank(admin);
        market.setCurrency(address(token), true);
        Market.Listing memory t = listingTerms(1000);
        t.currency = address(token);
        (uint256 id, Market.Listing memory l) = list(seller, 1, t);
        uint256 p = market.quoteBuy(l, id).price;
        token.mint(buyer, p);
        vm.startPrank(buyer);
        token.approve(address(market), p);
        vm.expectRevert(Market.PaymentFailed.selector);
        market.buy(l, id, p, address(0), address(0));
        vm.stopPrank();
    }

    function test_rejectsBadDeposits() public {
        Market.Listing memory l = listingTerms(1);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(buyer, true);
        vm.prank(buyer); // approved operator cannot set terms for the owner
        vm.expectRevert(Market.Unauthorized.selector);
        nft.safeTransferFrom(seller, address(market), 1, abi.encodePacked(bytes1(0x00), abi.encode(l)));

        vm.startPrank(seller);
        vm.expectRevert(Market.InvalidTerms.selector);
        nft.safeTransferFrom(seller, address(market), 1, "");
        vm.expectRevert(Market.InvalidTerms.selector);
        nft.safeTransferFrom(seller, address(market), 1, abi.encodePacked(bytes1(0x02), abi.encode(l)));
        l.currency = makeAddr("unlisted");
        vm.expectRevert(Market.CurrencyDisabled.selector);
        nft.safeTransferFrom(seller, address(market), 1, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        l = listingTerms(1);
        l.expiry = uint40(block.timestamp);
        vm.expectRevert(Market.InvalidTerms.selector);
        nft.safeTransferFrom(seller, address(market), 1, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        vm.stopPrank();
    }

    /// A contract that only claims to deliver an NFT cannot be paid by a bid.
    function test_fakeDeliveryIsRejected() public {
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(1 ether, 1 ether, 1));
        vm.prank(address(nft));
        vm.expectRevert(Market.NftNotDelivered.selector);
        market.onERC721Received(seller, seller, 7, abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, 0, address(0))));
    }

    function test_cancelWithdrawAndFailedTransfer() public {
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        vm.expectRevert(Market.Unauthorized.selector);
        market.withdrawListing(l, id, buyer);

        // The NFT transfer fails: withdrawal reverts and changes nothing.
        vm.mockCallRevert(address(nft), abi.encodeWithSelector(MockNFT.transferFrom.selector), "paused");
        vm.prank(seller);
        vm.expectRevert();
        market.withdrawListing(l, id, seller);
        // Cancellation needs no transfer and stops the listing.
        vm.prank(seller);
        market.cancelListing(l, id);
        vm.expectRevert(Market.NotActive.selector);
        market.quoteBuy(l, id);
        vm.clearMockedCalls();

        vm.prank(seller);
        market.withdrawListing(l, id, makeAddr("cold"));
        assertEq(nft.ownerOf(1), makeAddr("cold"));
        vm.prank(seller);
        vm.expectRevert(Market.NotActive.selector);
        market.withdrawListing(l, id, seller);
    }

    function test_updateListing() public {
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        Market.Listing memory next = listingTerms(2 ether);
        next.tokenId = 99; // ignored: the NFT cannot change
        vm.prank(seller);
        market.updateListing(l, id, next);
        (next.seller, next.nft, next.tokenId) = (seller, address(nft), 1);
        assertGe(market.quoteBuy(next, id).proceeds, 2 ether);
        vm.expectRevert(Market.NotActive.selector);
        market.quoteBuy(l, id);
    }

    function test_disabledCurrencyStopsFillsNotWithdrawals() public {
        MockToken token = new MockToken();
        vm.prank(admin);
        market.setCurrency(address(token), true);
        Market.Listing memory t = listingTerms(1);
        t.currency = address(token);
        (uint256 id, Market.Listing memory l) = list(seller, 1, t);
        vm.prank(admin);
        market.setCurrency(address(token), false);
        vm.expectRevert(Market.CurrencyDisabled.selector);
        market.quoteBuy(l, id);
        vm.prank(seller);
        market.withdrawListing(l, id, seller);
        assertEq(nft.ownerOf(1), seller);
    }

    function test_onlyOwnerConfigures() public {
        vm.expectRevert(Market.Unauthorized.selector);
        market.setCurrency(address(1), true);
        vm.expectRevert(Market.Unauthorized.selector);
        market.setOwner(buyer);
        vm.prank(admin);
        market.setOwner(buyer);
        assertEq(market.owner(), buyer);
    }

    function test_royaltyAbovePriceIsIncompatible() public {
        nft.setRoyalty(artist, 10_000, 1);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        vm.expectRevert(Market.Incompatible.selector);
        market.quoteBuy(l, id);
    }

    function test_royaltyToMarketOrMalformedIsIgnored() public {
        nft.setRoyalty(address(market), 1000, 0);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        assertEq(market.quoteBuy(l, id).royalty, 0);
    }

    /// Declining price: never increases, rounds up for the seller, stays within bounds.
    function testFuzz_linearAsk(uint128 start, uint128 end, uint32 duration, uint32 t1, uint32 t2) public {
        duration = uint32(bound(duration, 1, 365 days));
        Market.Listing memory terms = listingTerms(0);
        uint40 t0 = uint40(block.timestamp);
        terms.price = Market.Price(start, end, t0, t0 + duration, address(0), 0);
        (uint256 id, Market.Listing memory l) = list(seller, 1, terms);
        (uint256 a, uint256 b) = t1 < t2 ? (uint256(t1), uint256(t2)) : (uint256(t2), uint256(t1));
        a = bound(a, 0, uint256(duration) + 10);
        b = bound(b, a, uint256(duration) + 10);
        vm.warp(t0 + a);
        uint256 pa = market.ask(l, id);
        vm.warp(t0 + b);
        uint256 pb = market.ask(l, id);
        (uint256 lo, uint256 hi) = start < end ? (uint256(start), uint256(end)) : (uint256(end), uint256(start));
        assertGe(pa, lo);
        assertLe(pa, hi);
        if (start >= end) assertGe(pa, pb, "declining never increases");
        else assertLe(pa, pb, "increasing never decreases");
        if (a < duration) {
            uint256 exact = (uint256(start) * (duration - a) + uint256(end) * a);
            assertGe(pa * duration, exact, "rounds up for the seller");
            assertLt(pa * duration, exact + duration);
        }
    }

    /// Gross-up: proceeds cover the ask, and the buyer pays at most a few wei above the
    /// exact price that does.
    function testFuzz_buyQuoteIsNearMinimal(uint96 floor, uint16 royaltyBps) public {
        royaltyBps = uint16(bound(royaltyBps, 0, 2_500));
        if (royaltyBps != 0) nft.setRoyalty(artist, royaltyBps, 0);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(floor));
        Market.Quote memory q = market.quoteBuy(l, id);
        assertGe(q.proceeds, floor);
        assertEq(q.proceeds, proceedsAt(q.price, royaltyBps, 0));
        // Within 4 wei of the exact gross-up floor / (1 - fee rates).
        assertLe(q.price * (10_000 - royaltyBps - 20), uint256(floor) * 10_000 + 4 * 10_000, "near minimal");
    }

    function test_nonProportionalRoyaltyStillCoversAsk() public {
        nft.setRoyalty(artist, 300, 0.01 ether);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        Market.Quote memory q = market.quoteBuy(l, id);
        assertGe(q.proceeds, 1 ether);
        assertEq(q.royalty, q.price * 300 / 10_000 + 0.01 ether);
    }

    function test_externalStrategyIsClampedToFloor() public {
        MockStrategy s = new MockStrategy();
        s.set(0.1 ether, 0, false);
        Market.Listing memory terms = listingTerms(0.5 ether);
        terms.price.strategy = address(s);
        (uint256 id, Market.Listing memory l) = list(seller, 1, terms);
        assertEq(market.ask(l, id), 0.5 ether, "floor holds");
        s.set(2 ether, 0, false);
        assertEq(market.ask(l, id), 2 ether);
        s.set(0, 0, true);
        vm.expectRevert(Market.StrategyFailed.selector);
        market.ask(l, id);
        vm.prank(seller); // withdrawal does not depend on the strategy
        market.withdrawListing(l, id, seller);
    }
}

contract BidTest is Local {
    function test_sellIntoBid() public {
        nft.setRoyalty(artist, 500, 0);
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(3 ether, 1 ether, 2));
        assertEq(weth.balanceOf(address(market)), 3 ether);
        sellInto(seller, 5, b, bidId, proceedsAt(1 ether, 500, 0));
        assertEq(nft.ownerOf(5), buyer);
        assertEq(weth.balanceOf(seller), proceedsAt(1 ether, 500, 0));
        assertEq(weth.balanceOf(artist), 0.05 ether);
        assertEq(weth.balanceOf(protocol), 0.002 ether);
        (, uint128 spent, uint32 fills,) = market.orders(bidId);
        assertEq(spent, 1 ether);
        assertEq(fills, 1);
        assertEq(weth.balanceOf(address(market)), 2 ether, "unspent budget stays escrowed");
    }

    function test_sellRespectsMinimumAndEligibility() public {
        Market.Bid memory t = bidTerms(1 ether, 1 ether, 1);
        t.minTokenId = 10;
        t.maxTokenId = 20;
        (uint256 bidId, Market.Bid memory b) = createBid(t);
        nft.mint(seller, 5);
        vm.prank(seller);
        vm.expectRevert(Market.NotEligible.selector);
        nft.safeTransferFrom(
            seller, address(market), 5, abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, 0, address(0)))
        );
        nft.mint(seller, 15);
        vm.prank(seller);
        vm.expectRevert(Market.ProceedsBelowMinimum.selector);
        nft.safeTransferFrom(
            seller, address(market), 15, abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, 1 ether, address(0)))
        );
        sellInto(seller, 16, b, bidId, 0.99 ether);
        assertEq(nft.ownerOf(16), buyer);
    }

    /// Fills cannot exceed the quantity or budget, and the last fill pays at most the
    /// remaining budget.
    function test_budgetAndQuantityBound() public {
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(1.5 ether, 1 ether, 3));
        sellInto(seller, 1, b, bidId, 0);
        Market.Quote memory q = market.quoteSell(b, bidId, 2);
        assertEq(q.price, 0.5 ether, "clamped to the remaining budget");
        sellInto(seller, 2, b, bidId, 0);
        vm.expectRevert(Market.NotActive.selector); // budget exhausted
        market.quoteSell(b, bidId, 3);
    }

    function test_quantityBound() public {
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(10 ether, 1 ether, 1));
        sellInto(seller, 1, b, bidId, 0);
        vm.expectRevert(Market.NotActive.selector);
        market.quoteSell(b, bidId, 2);
        vm.prank(buyer);
        market.withdrawBid(b, bidId, buyer);
        assertEq(weth.balanceOf(buyer), 9 ether);
    }

    function test_matchListingWithBid() public {
        (uint256 listingId, Market.Listing memory l) = list(seller, 3, listingTerms(0.8 ether));
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(1 ether, 1 ether, 1));
        Market.Quote memory q = market.quoteMatch(l, listingId, b, bidId);
        vm.prank(keeper);
        market.matchBid(l, listingId, b, bidId);
        assertEq(nft.ownerOf(3), buyer);
        assertEq(weth.balanceOf(seller), proceedsAt(1 ether, 0, 30), "seller gets the bid, not the ask");
        assertEq(weth.balanceOf(keeper), 0.003 ether);
        assertEq(q.proceeds, weth.balanceOf(seller));
        assertEq(weth.balanceOf(address(market)), 0);
    }

    function test_matchRevertsBelowAsk() public {
        (uint256 listingId, Market.Listing memory l) = list(seller, 3, listingTerms(1 ether));
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(1 ether, 1 ether, 1));
        vm.expectRevert(Market.ProceedsBelowMinimum.selector);
        market.matchBid(l, listingId, b, bidId);
    }

    function test_bidStrategyUsesFills() public {
        MockStrategy s = new MockStrategy();
        s.set(0.1 ether, 0.1 ether, false); // pays 0.1 more after each fill
        Market.Bid memory t = bidTerms(10 ether, 0.25 ether, 5);
        t.price.strategy = address(s);
        (uint256 bidId, Market.Bid memory b) = createBid(t);
        assertEq(market.quoteSell(b, bidId, 1).price, 0.1 ether);
        sellInto(seller, 1, b, bidId, 0);
        assertEq(market.quoteSell(b, bidId, 2).price, 0.2 ether);
        sellInto(seller, 2, b, bidId, 0);
        assertEq(market.quoteSell(b, bidId, 3).price, 0.25 ether, "clamped to maxPrice");
    }

    function test_cancelAndWithdrawBid() public {
        (uint256 bidId, Market.Bid memory b) = createBid(bidTerms(1 ether, 1 ether, 1));
        vm.expectRevert(Market.Unauthorized.selector);
        market.withdrawBid(b, bidId, seller);
        vm.prank(buyer);
        market.cancelBid(b, bidId);
        nft.mint(seller, 1);
        vm.prank(seller);
        vm.expectRevert(Market.NotActive.selector);
        nft.safeTransferFrom(
            seller, address(market), 1, abi.encodePacked(bytes1(0x01), abi.encode(b, bidId, 0, address(0)))
        );
        vm.prank(buyer);
        market.withdrawBid(b, bidId, buyer);
        assertEq(weth.balanceOf(buyer), 1 ether);
        assertEq(weth.balanceOf(address(market)), 0);
    }

    function test_createBidValidation() public {
        Market.Bid memory b = bidTerms(1 ether, 1 ether, 1);
        vm.deal(buyer, 2 ether);
        vm.startPrank(buyer);
        vm.expectRevert(Market.InvalidTerms.selector);
        market.createBid{value: 0.5 ether}(b);
        b.quantity = 0;
        vm.expectRevert(Market.InvalidTerms.selector);
        market.createBid{value: 1 ether}(b);
        b = bidTerms(1 ether, 1 ether, 1);
        b.minTokenId = 2;
        b.maxTokenId = 1;
        vm.expectRevert(Market.InvalidTerms.selector);
        market.createBid{value: 1 ether}(b);
        vm.stopPrank();
    }
}

contract CallbackTest is Local {
    function _sale() internal returns (uint256 id) {
        (uint256 listingId, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        market.buy{value: 2 ether}(l, listingId, 2 ether, address(0), address(0));
        return listingId;
    }

    function test_observerRecordsSale() public {
        nft.setObserver(MockNFT.Observer.Record);
        _sale();
        assertEq(nft.sales(), 1);
        assertEq(nft.lastBuyer(), buyer);
        assertGt(nft.lastPrice(), 1 ether);
    }

    function test_failingObserversCannotUndoSale() public {
        MockNFT.Observer[3] memory modes = [MockNFT.Observer.Revert, MockNFT.Observer.BurnGas, MockNFT.Observer.Reenter];
        for (uint256 i; i < modes.length; i++) {
            setUp();
            nft.setObserver(modes[i]);
            _sale();
            assertEq(nft.ownerOf(1), buyer);
            assertEq(nft.sales(), 0);
        }
    }

    function test_executorCannotStarveObserver() public {
        nft.setObserver(MockNFT.Observer.Record);
        (uint256 id, Market.Listing memory l) = list(seller, 1, listingTerms(1 ether));
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        // Enough for the sale but not for the observer's full allowance.
        (bool ok,) = address(market).call{value: 2 ether, gas: 150_000}(
            abi.encodeCall(Market.buy, (l, id, 2 ether, address(0), address(0)))
        );
        assertFalse(ok);
        assertEq(nft.ownerOf(1), address(market));
    }
}
