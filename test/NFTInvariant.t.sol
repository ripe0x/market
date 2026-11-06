// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// Random listings, purchases, sales into a persistent bid, cancellations, top-ups, time and
/// theft attempts against both NFT handlers, with ghost accounting of every payment.
contract NFTDriver is Test {
    Market public market = new Market();
    NFTSale public sale = new NFTSale();
    NFTBid public bids = new NFTBid(market);
    RoyaltyNFT public art = new RoyaltyNFT();

    uint256 public constant TOKENS = 12;
    uint256 public constant MAX_FILLS = 4;
    address[2] public holders = [makeAddr("holder0"), makeAddr("holder1")];
    address public buyer = makeAddr("buyer");
    address public bidder = makeAddr("bidder");
    address public vault = makeAddr("vault");
    address public royaltyTo = makeAddr("royaltyTo");
    address public attacker = makeAddr("attacker");

    struct Listing {
        Order order;
        bytes config;
        uint256 tokenId;
        address seller;
        bool done;
    }

    Listing[] public listings;
    Order public bid;
    bytes public bidConfig;
    bool public bidRecovered;

    // Ghost accounting.
    uint256 public royaltiesOwed;
    mapping(address => uint256) public proceedsOwed;
    uint256 public bidIn; // funding and top-ups
    uint256 public bidOut; // prices paid
    uint256 public bought;
    uint256 public attacks;
    bool public attackSucceeded;

    constructor() {
        art.setRoyalty(royaltyTo, 500);
        for (uint256 i; i < TOKENS; ++i) {
            address h = holders[i % 2];
            art.mint(h, i);
        }
        for (uint256 i; i < 2; ++i) {
            vm.prank(holders[i]);
            art.setApprovalForAll(address(bids), true);
        }
        vm.deal(buyer, 1e30);
        vm.deal(bidder, 1e30);
        vm.deal(attacker, 1 ether);
        bidConfig = abi.encode(
            NFTBid.Config(
                art, true, 0, NFTTrade.Schedule(0.5 ether, 3 ether, block.timestamp, block.timestamp + 1 days, 0), vault, MAX_FILLS
            )
        );
        vm.prank(bidder);
        bid = market.create{value: 4 ether}(bids, bidConfig, 0);
        bidIn = 4 ether;
    }

    function listingCount() external view returns (uint256) {
        return listings.length;
    }

    function list(uint256 tokenSeed, uint256 start, uint256 end, uint256 duration) external {
        uint256 id = tokenSeed % TOKENS;
        address seller = art.ownerOf(id);
        if (seller != holders[0] && seller != holders[1]) return;
        start = bound(start, 0, 10 ether);
        end = bound(end, 0, 10 ether);
        duration = bound(duration, 0, 2 days);
        bytes memory config = abi.encode(
            NFTSale.Config(art, id, NFTTrade.Schedule(start, end, block.timestamp, block.timestamp + duration, 0), seller, 10_000)
        );
        vm.startPrank(seller);
        Order order = market.create(sale, config, bytes32(listings.length));
        art.transferFrom(seller, address(order), id);
        vm.stopPrank();
        listings.push(Listing(order, config, id, seller, false));
    }

    function buy(uint256 index, uint256 extra) external {
        if (listings.length == 0) return;
        Listing storage l = listings[index % listings.length];
        if (l.done) return;
        (uint256 price,, uint256 r) = sale.quote(abi.decode(l.config, (NFTSale.Config)));
        extra = bound(extra, 0, 1 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        l.order.fill{value: price + extra}(l.config, abi.encode(buyer, price));
        assertEq(before - buyer.balance, price, "buyer pays the price");
        l.done = true;
        royaltiesOwed += r;
        proceedsOwed[l.seller] += price - r;
    }

    function cancel(uint256 index) external {
        if (listings.length == 0) return;
        Listing storage l = listings[index % listings.length];
        if (l.done) return;
        vm.startPrank(l.seller);
        l.order.close();
        l.order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(l.order), l.seller, l.tokenId)));
        vm.stopPrank();
        l.done = true;
    }

    function sellIntoBid(uint256 tokenSeed) external {
        if (bid.closed()) return;
        uint256 id = tokenSeed % TOKENS;
        address seller = art.ownerOf(id);
        if (seller != holders[0] && seller != holders[1]) return;
        NFTBid.Config memory c = abi.decode(bidConfig, (NFTBid.Config));
        uint256 price = bids.priceAt(c.schedule, block.timestamp);
        if (address(bid).balance < price) return;
        (, , uint256 r) = bids.quote(address(bid), c, id);
        vm.prank(seller);
        bid.fill(bidConfig, abi.encode(id, price - r, seller));
        royaltiesOwed += r;
        proceedsOwed[seller] += price - r;
        bidOut += price;
        bought += 1;
    }

    function topUp(uint256 amount) external {
        if (bid.closed()) return;
        amount = bound(amount, 0, 5 ether);
        vm.prank(buyer);
        (bool ok,) = address(bid).call{value: amount}("");
        require(ok);
        bidIn += amount;
    }

    function cancelBid() external {
        if (bidRecovered) return;
        vm.startPrank(bidder);
        if (!bid.closed()) bid.close();
        bid.execute(bidder, address(bid).balance, "");
        vm.stopPrank();
        bidRecovered = true;
    }

    function wait(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 0, 1 days));
    }

    /// Every way an outsider or the bidder might take a holder's token or anyone's ETH.
    function attack(uint256 tokenSeed, uint8 kind) external {
        uint256 id = tokenSeed % TOKENS;
        address victim = art.ownerOf(id);
        attacks += 1;
        bool ok;
        kind %= 5;
        if (kind == 0) {
            vm.prank(attacker);
            (ok,) = address(bids).call(abi.encodeCall(IOrderHandler.onFill, (victim, 0, bidConfig, abi.encode(id, 0, attacker))));
        } else if (kind == 1) {
            vm.prank(attacker);
            (ok,) = address(bid).call(abi.encodeCall(Order.fill, (bidConfig, abi.encode(id, 0, attacker))));
        } else if (kind == 2) {
            // The bidder, once closed, tries to use the holders' approvals through the order.
            if (!bid.closed()) return;
            vm.prank(bidder);
            (ok,) = address(bid).call(
                abi.encodeCall(Order.execute, (address(art), 0, abi.encodeCall(IERC721.transferFrom, (victim, bidder, id))))
            );
            if (!ok) {
                vm.prank(bidder);
                (ok,) = address(bid).call(
                    abi.encodeCall(
                        Order.execute,
                        (address(bids), 0, abi.encodeCall(IOrderHandler.onFill, (victim, 0, bidConfig, abi.encode(id, 0, bidder))))
                    )
                );
            }
        } else if (kind == 3) {
            if (listings.length == 0) return;
            Listing storage l = listings[id % listings.length];
            vm.prank(attacker);
            (ok,) = address(sale).call(abi.encodeCall(IOrderHandler.onFill, (attacker, 0, l.config, abi.encode(attacker, 0))));
            if (!ok) {
                vm.prank(attacker);
                (ok,) = address(l.order).call(
                    abi.encodeCall(Order.execute, (address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(l.order), attacker, l.tokenId))))
                );
            }
        } else {
            vm.prank(attacker);
            (ok,) = address(art).call(abi.encodeCall(IERC721.transferFrom, (victim, attacker, id)));
        }
        if (ok) attackSucceeded = true;
    }
}

contract NFTInvariantTest is Test {
    NFTDriver d;

    function setUp() public {
        vm.warp(1_000_000);
        d = new NFTDriver();
        targetContract(address(d));
    }

    function invariant_noTheft() public view {
        assertFalse(d.attackSucceeded());
        assertEq(d.attacker().balance, 1 ether);
        assertEq(d.art().balanceOf(d.attacker()), 0);
        assertEq(d.art().balanceOf(d.bidder()), 0, "the bidder only ever withdraws ETH");
    }

    function invariant_handlersHoldNothing() public view {
        assertEq(address(d.sale()).balance, 0);
        assertEq(address(d.bids()).balance, 0);
        assertEq(d.art().balanceOf(address(d.sale())), 0);
        assertEq(d.art().balanceOf(address(d.bids())), 0);
    }

    function invariant_everyPaymentAccounted() public view {
        assertEq(d.royaltyTo().balance, d.royaltiesOwed(), "royalties");
        for (uint256 i; i < 2; ++i) {
            address h = d.holders(i);
            assertEq(h.balance, d.proceedsOwed(h), "seller proceeds");
        }
        if (!d.bidRecovered()) assertEq(address(d.bid()).balance, d.bidIn() - d.bidOut(), "bid escrow");
        else assertEq(address(d.bid()).balance, 0);
    }

    function invariant_bidLimits() public view {
        assertLe(d.bought(), d.MAX_FILLS());
        assertEq(d.art().balanceOf(d.vault()), d.bought(), "one token per paid fill");
        assertEq(d.bids().fills(address(d.bid())), d.bought());
        if (d.bought() == d.MAX_FILLS()) assertTrue(d.bid().closed());
    }

    function invariant_tokensAreSomewhereLegitimate() public view {
        uint256 open;
        for (uint256 i; i < d.listingCount(); ++i) {
            (Order order,,,, bool done) = d.listings(i);
            if (!done) open += 1;
            else assertEq(d.art().balanceOf(address(order)), 0, "finished listings hold nothing");
        }
        uint256 total = d.art().balanceOf(d.holders(0)) + d.art().balanceOf(d.holders(1))
            + d.art().balanceOf(d.buyer()) + d.art().balanceOf(d.vault()) + open;
        assertEq(total, d.TOKENS());
    }
}
