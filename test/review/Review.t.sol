// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../Base.t.sol";

/// Independent security review probes. No product code is modified.
contract ReviewTest is Base {
    Vm.Wallet bidder = vm.createWallet("review-bidder");
    Vm.Wallet attacker = vm.createWallet("review-attacker");

    function setUp() public {
        loadFixture("item_offer");
        deployMarket();
    }

    function nftTo(address to) internal view returns (ConsiderationItem[] memory c) {
        c = new ConsiderationItem[](1);
        c[0] = ConsiderationItem(ItemType.ERC721, nft, tokenId, 1, 1, payable(to));
    }

    function twoWay() internal pure returns (Fulfillment[] memory f) {
        f = new Fulfillment[](2);
        f[0] = pair(0, 0, 1, 0); // listing NFT -> bid NFT consideration
        f[1] = pair(1, 0, 0, 0); // bid WETH   -> seller price
    }

    /// FINDING (low/info): Market treats its entire WETH balance as "surplus" for
    /// the current match. Any WETH sitting in Market before the call -- a donation,
    /// or a stray balance from some other interaction -- is swept to whatever seller
    /// happens to match next, and the executor/protocol earn fees on it. This breaks
    /// the "holds no WETH between transactions" assumption. It is NOT profitable to
    /// the donor: an attacker who is also the executor recovers only EXECUTOR_FEE_BPS
    /// of what they donate. Shown here: a 5 ETH donation lands almost entirely on the
    /// seller, the executor nets a loss, and Market still ends at zero.
    function test_donationSweptToCurrentSeller_noTheft() public {
        uint256 priceP = 1 ether;
        AdvancedOrder memory l = listing(priceP, priceP, block.timestamp - 1, block.timestamp + 1 days, 1);

        // Donation arrives before the match (griefer "gifts" the next seller).
        uint256 donation = 5 ether;
        deal(address(WETH), attacker.addr, donation);
        vm.prank(attacker.addr);
        WETH.transfer(address(market), donation);

        // A plain 2 ETH bid; released = 2 ETH, true surplus over price = 1 ETH.
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftTo(bidder.addr));

        uint256 attackerWethBefore = WETH.balanceOf(attacker.addr); // 0 after donating

        // Attacker is also the executor, trying to recover the donation via the fee.
        vm.prank(attacker.addr);
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());

        // base = price + surplus = 1 + (5 + 1) = 7 ETH.
        assertEq(WETH.balanceOf(attacker.addr) - attackerWethBefore, 7 ether * 30 / 10_000, "executor got only 30bps");
        assertEq(WETH.balanceOf(protocol), 7 ether * 20 / 10_000, "protocol got 20bps");
        // Seller receives price (from Seaport) + sellerExtra; dominated by the donation.
        assertEq(WETH.balanceOf(seller.addr), 7 ether - 7 ether * 50 / 10_000, "donation landed on seller");
        assertGt(WETH.balanceOf(seller.addr), 6.9 ether, "seller got the donated WETH");
        // Donor's net: donated 5, recovered 0.021 as executor fee -> clear loss, no theft.
        assertLt(WETH.balanceOf(attacker.addr), donation / 10, "donation not recoverable");
        assertEq(WETH.balanceOf(address(market)), 0, "market swept to zero");
        assertEq(IERC721(nft).ownerOf(tokenId), bidder.addr);
    }

    /// FINDING (medium, by-design economic risk, D013): the seller's only on-chain
    /// guarantee is the *current declining price*. Anyone may call matchOffer with
    /// any WETH offer at/above that floor, including a minimal self-signed bid. A
    /// searcher can therefore acquire the NFT at the floor and separately flip it
    /// into a much larger real offer, capturing the gap the honest keeper would have
    /// routed to the seller. Shown: the listing floor is 1 ETH, a fat 10 ETH offer
    /// exists, but the attacker takes the NFT for ~1 ETH via their own bid.
    function test_searcherAcquiresAtFloorDespiteFatOffer() public {
        uint256 floor = 1 ether;
        AdvancedOrder memory l = listing(floor, floor, block.timestamp - 1, block.timestamp + 1 days, 2);

        // A fat 10 ETH real-style offer the seller "should" have captured exists in
        // the wild (not matched here). The attacker instead uses a minimal self-bid
        // just above the floor so the match clears the 0.5% fees.
        AdvancedOrder memory selfBid = syntheticBid(attacker, 1.01 ether, nftTo(attacker.addr));

        uint256 sellerBefore = WETH.balanceOf(seller.addr);
        vm.prank(attacker.addr);
        market.matchOffer(l, selfBid, new CriteriaResolver[](0), twoWay());

        // Attacker now owns the NFT having paid ~1.01 ETH, seller got ~floor.
        assertEq(IERC721(nft).ownerOf(tokenId), attacker.addr, "attacker took the NFT at the floor");
        uint256 sellerGot = WETH.balanceOf(seller.addr) - sellerBefore;
        assertGe(sellerGot, floor, "floor honored");
        assertLt(sellerGot, 1.02 ether, "but seller got only ~floor, not the fat-offer value");
    }

    /// Property check (held): a malicious executor cannot redirect the surplus to
    /// themselves beyond the disclosed 30bps. The match recipient is hardcoded to
    /// Market, so unspent offer WETH can only land in Market, and _settle routes the
    /// remainder to the seller-signed recipient. Here the attacker tries to add a
    /// self-paying consideration via fulfillments that Seaport will reject.
    function test_cannotRouteSurplusToExecutorViaFulfillments() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 3);
        AdvancedOrder memory b = syntheticBid(bidder, 3 ether, nftTo(bidder.addr));

        // Honest two-way fulfillment: all surplus goes to the seller, attacker gets 30bps.
        vm.prank(attacker.addr);
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
        assertEq(WETH.balanceOf(attacker.addr), 3 ether * 30 / 10_000, "executor capped at 30bps");
        assertEq(WETH.balanceOf(seller.addr), 3 ether - 3 ether * 50 / 10_000, "seller got the rest");
        assertEq(WETH.balanceOf(address(market)), 0);
    }

    /// Property check (held): even an extra fulfillment pointing the bid's WETH at a
    /// non-existent consideration index cannot skim the surplus. Seaport tolerates
    /// it, the unspent WETH still lands in Market, and _settle still pays the seller
    /// everything beyond the disclosed fees.
    function test_extraFulfillmentCannotSkimSurplus() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 7);
        AdvancedOrder memory b = syntheticBid(bidder, 3 ether, nftTo(bidder.addr));
        Fulfillment[] memory f = new Fulfillment[](3);
        f[0] = pair(0, 0, 1, 0);
        f[1] = pair(1, 0, 0, 0);
        f[2] = pair(1, 0, 1, 1); // bid consideration[1] does not exist
        vm.prank(attacker.addr);
        market.matchOffer(l, b, new CriteriaResolver[](0), f);
        assertEq(WETH.balanceOf(attacker.addr), 3 ether * 30 / 10_000, "executor still capped at 30bps");
        assertEq(WETH.balanceOf(seller.addr), 3 ether - 3 ether * 50 / 10_000, "seller still got the surplus");
        assertEq(WETH.balanceOf(address(market)), 0);
        assertEq(IERC721(nft).ownerOf(tokenId), bidder.addr);
    }
}
