// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../../contracts/Market.sol";
import {MockWETH, MockToken, MockNFT} from "../Mocks.sol";

/// Independent security review PoCs. Mirrors the Local harness setup (WETH9 etched at
/// the canonical address, no fork). Each test documents a finding from the review.
contract ReviewTest is Test {
    MockWETH weth;
    MockNFT nft;
    Market market;
    address protocol = makeAddr("protocol");
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        deployCodeTo("Mocks.sol:MockWETH", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        weth = MockWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        market = new Market(protocol, admin, address(0xdead));
        nft = new MockNFT();
        vm.warp(1_800_000_000);
    }

    function _fixed(uint256 a) internal pure returns (Market.Price memory) {
        return Market.Price(uint128(a), uint128(a), 0, 0, address(0), 0);
    }

    function _listing(uint256 floor, address currency) internal view returns (Market.Listing memory l) {
        l.currency = currency;
        l.recipient = seller;
        l.floor = uint128(floor);
        l.expiry = uint40(block.timestamp + 30 days);
        l.price = _fixed(floor);
    }

    function _list(uint256 id, Market.Listing memory l) internal returns (uint256, Market.Listing memory) {
        nft.mint(seller, id);
        vm.prank(seller);
        nft.safeTransferFrom(seller, address(market), id, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        (l.seller, l.nft, l.tokenId) = (seller, address(nft), id);
        return (market.lastId(), l);
    }

    // ------------------------------------------------------------------ Finding 1

    /// FINDING (Low): `cancelListing` reverts once the owner disables the listing's
    /// currency, because `_liveListing` requires the currency enabled. Security
    /// property 4 / invariant 4 state "cancellation ... never depend on the owner".
    /// Mitigation present: `withdrawListing` has no currency check and still works, and
    /// a disabled currency already blocks every fill, so the seller's assets are safe.
    /// The finding is the broken property, not a loss of funds. Fixed: this test now
    /// asserts cancellation works with the currency disabled.
    function test_cancelListingIgnoresDisabledCurrency() public {
        MockToken token = new MockToken();
        vm.prank(admin);
        market.setCurrency(address(token), true);
        (uint256 id, Market.Listing memory l) = _list(1, _listing(1000, address(token)));

        // Owner disables the currency.
        vm.prank(admin);
        market.setCurrency(address(token), false);

        // Fixed after review: cancelling does not depend on the owner's currency setting.
        vm.prank(seller);
        market.cancelListing(l, id);

        // Withdrawal is the escape hatch and does not depend on the owner.
        vm.prank(seller);
        market.withdrawListing(l, id, seller);
        assertEq(nft.ownerOf(1), seller, "seller recovers the NFT despite disabled currency");
    }

    // ------------------------------------------------------------------ Finding 2

    /// FINDING (Low/Info): the referrer is caller-chosen and unconstrained, so any buyer
    /// can name itself (or any address it controls) and recapture the 0.10% referral
    /// out of the 0.20% protocol fee. The effective protocol fee is therefore 0.10% for
    /// any caller who self-refers. Consistent with D033 ("users pay the same with or
    /// without a referrer") but it halves protocol revenue by default; confirm intended.
    function test_selfReferralRecapturesHalfTheProtocolFee() public {
        (uint256 id, Market.Listing memory l) = _list(1, _listing(1 ether, address(weth)));
        Market.Quote memory q = market.quoteBuy(l, id);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        // Buyer names ITSELF as referrer.
        market.buy{value: 2 ether}(l, id, q.price, address(0), buyer);

        uint256 referral = q.price * 10 / 10_000; // REFERRAL_FEE_BPS
        // Buyer's WETH balance = excess refund + the referral it clawed back.
        assertEq(weth.balanceOf(buyer), (2 ether - q.price) + referral, "buyer recaptured referral");
        assertEq(weth.balanceOf(protocol), q.protocolFee - referral, "protocol keeps only half its fee");
        assertEq(referral * 2, q.protocolFee, "referral is half the protocol fee");
    }

    // ------------------------------------------------------------------ Finding 3

    /// FINDING (Info): a seller may list (or bid) with a zero ask, in which case the NFT
    /// is transferable for a zero sale price. `buy` succeeds paying nothing. This is the
    /// seller's own authorized terms (floor 0, price 0); noted as a UI/footgun, not a
    /// contract fault. Demonstrates no validation forbids a zero price.
    function test_zeroPriceListingSellsForFree() public {
        (uint256 id, Market.Listing memory l) = _list(1, _listing(0, address(weth)));
        Market.Quote memory q = market.quoteBuy(l, id);
        assertEq(q.price, 0, "ask is zero");

        vm.prank(buyer);
        market.buy(l, id, 0, address(0), address(0)); // pays nothing, no msg.value
        assertEq(nft.ownerOf(1), buyer, "NFT handed over for free");
        assertEq(weth.balanceOf(seller), 0);
    }

    // --------------------------------------------------- Positive confirmations

    /// CONFIRMS SOUND: no administrator can move an escrowed NFT. The owner has only
    /// setCurrency/setZone/setOwner; there is no path to pull an escrowed asset.
    function test_ownerCannotTouchEscrowedNft() public {
        (, Market.Listing memory l) = _list(1, _listing(1 ether, address(weth)));
        assertEq(nft.ownerOf(1), address(market));
        // There is simply no owner-callable function that transfers the NFT; the only
        // transfer-out paths (buy/match/fillOffer/withdraw) require buyer payment or the
        // seller. Assert the admin cannot even become the seller to withdraw.
        vm.prank(admin);
        vm.expectRevert(Market.Unauthorized.selector);
        market.withdrawListing(l, 1, admin);
    }

    /// CONFIRMS SOUND: a listing hash cannot be reinterpreted as a bid (domain tags).
    function test_listingHashIsNotABidHash() public view {
        Market.Listing memory l = _listing(1 ether, address(weth));
        (l.seller, l.nft, l.tokenId) = (seller, address(nft), 1);
        Market.Bid memory b;
        b.buyer = seller;
        b.nft = address(nft);
        b.currency = address(weth);
        b.budget = 1 ether;
        b.maxPrice = 1 ether;
        b.quantity = 1;
        b.expiry = uint40(block.timestamp + 1 days);
        assertTrue(market.hashListing(l) != market.hashBid(b), "domain separation holds");
    }
}
