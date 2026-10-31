// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../contracts/Market.sol";
import {MockWETH, MockNFT} from "./Mocks.sol";

/// Random sequences of every user action. Each fill asserts its own bounds; the
/// invariants check escrow solvency and custody after every call.
contract Handler is Test {
    Market market;
    MockWETH weth;
    MockNFT nft;
    address[3] actors = [makeAddr("a"), makeAddr("b"), makeAddr("c")];

    Market.Listing[] public listings;
    uint256[] public listingIds;
    Market.Bid[] public bids;
    uint256[] public bidIds;
    uint256 nextToken = 1;
    uint256 public sales;

    constructor(Market m, MockWETH w, MockNFT n) {
        (market, weth, nft) = (m, w, n);
    }

    function listingCount() external view returns (uint256) {
        return listings.length;
    }

    function bidCount() external view returns (uint256) {
        return bids.length;
    }

    function listing(uint256 i) external view returns (Market.Listing memory) {
        return listings[i];
    }

    function bid(uint256 i) external view returns (Market.Bid memory) {
        return bids[i];
    }

    function _price(uint256 seed) internal view returns (Market.Price memory p) {
        uint128 a = uint128(bound(seed, 0, 5 ether));
        uint128 b = uint128(bound(seed >> 128, 0, 5 ether));
        p = Market.Price(a, b, uint40(block.timestamp), uint40(block.timestamp + 7 days), address(0), 0);
    }

    function list(uint256 actor, uint256 seed) external {
        address from = actors[actor % 3];
        uint256 id = nextToken++;
        nft.mint(from, id);
        Market.Listing memory l;
        l.currency = address(weth);
        l.recipient = from;
        l.floor = uint128(bound(seed, 0, 2 ether));
        l.expiry = uint40(block.timestamp + 10 days);
        l.price = _price(seed >> 8);
        vm.prank(from);
        nft.safeTransferFrom(from, address(market), id, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        (l.seller, l.nft, l.tokenId) = (from, address(nft), id);
        listings.push(l);
        listingIds.push(market.lastId());
    }

    function createBid(uint256 actor, uint256 seed) external {
        address from = actors[actor % 3];
        Market.Bid memory b;
        b.recipient = from;
        b.nft = address(nft);
        b.maxTokenId = seed % 2 == 0 ? type(uint256).max : nextToken; // collection or range
        b.currency = address(weth);
        b.budget = uint128(bound(seed, 1, 10 ether));
        b.maxPrice = uint128(bound(seed >> 64, 0, 4 ether));
        b.quantity = uint32(bound(seed >> 32, 1, 4));
        b.expiry = uint40(block.timestamp + 10 days);
        b.price = _price(seed >> 96);
        vm.deal(from, b.budget);
        vm.prank(from);
        uint256 id = market.createBid{value: b.budget}(b);
        b.buyer = from;
        bids.push(b);
        bidIds.push(id);
    }

    function buy(uint256 i, uint256 actor) external {
        if (listings.length == 0) return;
        i %= listings.length;
        Market.Listing memory l = listings[i];
        try market.quoteBuy(l, listingIds[i]) returns (Market.Quote memory q) {
            address to = actors[actor % 3];
            uint256 before = weth.balanceOf(l.recipient);
            uint256 minimum = market.ask(l, listingIds[i]);
            vm.deal(to, q.price);
            vm.prank(to);
            market.buy{value: q.price}(l, listingIds[i], q.price, address(0), address(0));
            assertGe(q.proceeds, minimum, "seller minimum");
            assertEq(nft.ownerOf(l.tokenId), to);
            if (l.recipient != to) assertEq(weth.balanceOf(l.recipient) - before, q.proceeds);
            sales++;
        } catch {}
    }

    function sell(uint256 i, uint256 actor) external {
        if (bids.length == 0) return;
        i %= bids.length;
        Market.Bid memory b = bids[i];
        address from = actors[actor % 3];
        uint256 id = nextToken++;
        nft.mint(from, id);
        (, uint128 spentBefore,,) = market.orders(bidIds[i]);
        try market.quoteSell(b, bidIds[i], id) returns (Market.Quote memory q) {
            vm.prank(from);
            nft.safeTransferFrom(
                from,
                address(market),
                id,
                abi.encodePacked(bytes1(0x01), abi.encode(b, bidIds[i], q.proceeds, address(0)))
            );
            (, uint128 spent, uint32 fills,) = market.orders(bidIds[i]);
            assertLe(q.price, b.maxPrice, "per-NFT bound");
            assertEq(spent - spentBefore, q.price);
            assertLe(spent, b.budget, "budget bound");
            assertLe(fills, b.quantity, "quantity bound");
            sales++;
        } catch {}
    }

    function matchBid(uint256 li, uint256 bi) external {
        if (listings.length == 0 || bids.length == 0) return;
        li %= listings.length;
        bi %= bids.length;
        Market.Listing memory l = listings[li];
        Market.Bid memory b = bids[bi];
        try market.quoteMatch(l, listingIds[li], b, bidIds[bi]) returns (Market.Quote memory q) {
            uint256 minimum = market.ask(l, listingIds[li]);
            market.matchBid(l, listingIds[li], b, bidIds[bi]);
            assertGe(q.proceeds, minimum, "seller minimum");
            assertLe(q.price, b.maxPrice, "buyer bound");
            sales++;
        } catch {}
    }

    function cancelOrWithdraw(uint256 i, bool isBid, bool withdraw) external {
        if (isBid && bids.length != 0) {
            i %= bids.length;
            vm.startPrank(bids[i].buyer);
            if (withdraw) {
                try market.withdrawBid(bids[i], bidIds[i], bids[i].buyer) {} catch {}
            } else {
                try market.cancelBid(bids[i], bidIds[i]) {} catch {}
            }
            vm.stopPrank();
        } else if (!isBid && listings.length != 0) {
            i %= listings.length;
            vm.startPrank(listings[i].seller);
            if (withdraw) {
                try market.withdrawListing(listings[i], listingIds[i], listings[i].seller) {} catch {}
            } else {
                try market.cancelListing(listings[i], listingIds[i]) {} catch {}
            }
            vm.stopPrank();
        }
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 3 days));
    }
}

contract InvariantTest is Test {
    Market market;
    MockWETH weth;
    MockNFT nft;
    Handler handler;

    function setUp() public {
        deployCodeTo("Mocks.sol:MockWETH", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        weth = MockWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        market = new Market(makeAddr("protocol"), makeAddr("admin"), address(0xdead));
        nft = new MockNFT();
        nft.setRoyalty(makeAddr("artist"), 500, 0);
        handler = new Handler(market, weth, nft);
        targetContract(address(handler));
    }

    /// Market holds exactly the unspent budget of every open bid: no stranded funds,
    /// and no fill was paid from another order's escrow.
    function invariant_escrowEqualsOpenBudgets() public view {
        uint256 owed;
        for (uint256 i; i < handler.bidCount(); i++) {
            Market.Bid memory b = handler.bid(i);
            (bytes32 h, uint128 spent,,) = market.orders(handler.bidIds(i));
            if (h != bytes32(0)) owed += b.budget - spent;
        }
        assertEq(weth.balanceOf(address(market)), owed);
    }

    /// Every open listing's NFT is in escrow, and every closed listing's NFT is not.
    function invariant_custodyMatchesListings() public view {
        for (uint256 i; i < handler.listingCount(); i++) {
            Market.Listing memory l = handler.listing(i);
            (bytes32 h,,,) = market.orders(handler.listingIds(i));
            assertEq(nft.ownerOf(l.tokenId) == address(market), h != bytes32(0));
        }
    }

    /// Guards against a vacuous run where every fill attempt reverted.
    function afterInvariant() public view {
        assertGt(handler.sales(), 0, "no sales exercised");
    }
}
