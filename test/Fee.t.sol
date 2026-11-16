// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// A fee recipient that refuses ETH.
contract RefusingTreasury {
    receive() external payable {
        revert("no");
    }
}

/// A fee recipient that tries to fill the paying order again when paid.
contract ReentrantTreasury {
    Order public target;
    bytes public data;
    bool public reentered;

    function arm(Order target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    receive() external payable {
        if (address(target) == address(0)) return;
        (reentered,) = address(target).call{value: 0}(data);
    }
}

/// The fee on `NFTSale` and `NFTBid` fills: at most 1%, set by `feeTo`, locked per order at creation.
contract FeeTest is Base {
    RoyaltyNFT art;
    address holder = makeAddr("holder");
    address vault = makeAddr("vault");

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500);
    }

    function test_feeTerms() public view {
        assertEq(sale.MAX_FEE_BPS(), 100);
        assertEq(sale.feeBps(), 100, "starts at 1%");
        assertEq(bids.feeBps(), 100);
        assertEq(sale.feeTo(), treasury);
        assertEq(bids.feeTo(), treasury);
        assertEq(address(sale.market()), address(market));
    }

    function test_zeroFeeRecipientRejected() public {
        vm.expectRevert(NFTTrade.ZeroAddress.selector);
        new NFTSale(market, address(0));
        vm.expectRevert(NFTTrade.ZeroAddress.selector);
        new NFTBid(market, address(0));
    }

    /// Sale at 1 ETH with a 5% royalty: buyer 1, artist 0.05, fee 0.01, seller 0.94.
    function test_saleSplit() public {
        (Order order, bytes memory config) = _listArt(sale, 1 ether, 1000);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        order.fill{value: 1.5 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(before - buyer.balance, 1 ether, "buyer spends the price only");
        assertEq(royalty.balance, 0.05 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(seller.balance, 0.94 ether);
        assertEq(address(order).balance, 0);
        assertEq(address(sale).balance, 0);
    }

    /// Bid at 1 ETH with a 5% royalty: order pays 1, artist 0.05, fee 0.01, seller 0.94.
    function test_bidSplit() public {
        Order bid = _openBid(1 ether, 2 ether);
        bytes memory config = _bidConfig(1 ether);
        vm.prank(holder);
        bid.fill(config, abi.encode(1, 0.94 ether, holder));
        assertEq(address(bid).balance, 1 ether, "bid spent exactly the price");
        assertEq(royalty.balance, 0.05 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(holder.balance, 0.94 ether);
        assertEq(art.ownerOf(1), vault);
    }

    /// The seller's minimum is net of the fee: asking for the pre-fee amount reverts.
    function test_bidMinimumIsNetOfFee() public {
        Order bid = _openBid(1 ether, 1 ether);
        bytes memory config = _bidConfig(1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.BelowMinProceeds.selector, 0.94 ether, 0.95 ether));
        bid.fill(config, abi.encode(1, 0.95 ether, holder));
    }

    /// A royalty above what the fee leaves is capped: the trade settles, the fee is paid in full.
    function test_fullRoyaltyCappedAtPriceLessFee() public {
        art.setRoyalty(royalty, 10_000);
        (Order order, bytes memory config) = _listArt(sale, 1 ether, 10_000);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(royalty.balance, 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(seller.balance, 0);
        assertEq(art.ownerOf(1), buyer);
    }

    /// A bid on a 100% royalty collection settles too; the seller's minimum still binds.
    function test_bidOnFullRoyaltySettles() public {
        art.setRoyalty(royalty, 10_000);
        Order bid = _openBid(1 ether, 1 ether);
        bytes memory config = _bidConfig(1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.BelowMinProceeds.selector, 0, 1));
        bid.fill(config, abi.encode(1, 1, holder));
        vm.prank(holder);
        bid.fill(config, abi.encode(1, 0, holder));
        assertEq(royalty.balance, 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(holder.balance, 0);
    }

    /// The seller's royalty cap applies to the capped royalty.
    function test_cappedRoyaltyStillBoundBySellerLimit() public {
        art.setRoyalty(royalty, 10_000);
        (Order order, bytes memory config) = _listArt(sale, 1 ether, 9_000);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.RoyaltyAboveLimit.selector, 0.99 ether, 0.9 ether));
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
    }

    /// Under 100 wei the fee rounds to 0, so a 100% royalty takes everything.
    function test_tinyPricePaysNoFee() public {
        art.setRoyalty(royalty, 10_000);
        (Order order, bytes memory config) = _listArt(sale, 99, 10_000);
        vm.prank(buyer);
        order.fill{value: 99}(config, abi.encode(buyer, 99));
        assertEq(royalty.balance, 99);
        assertEq(treasury.balance, 0);
        assertEq(seller.balance, 0);
    }

    function test_onlyFeeToSetsFee() public {
        vm.prank(seller);
        vm.expectRevert(NFTTrade.NotFeeTo.selector);
        sale.setFee(0);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.FeeTooHigh.selector, 101));
        sale.setFee(101);
        vm.prank(treasury);
        vm.expectEmit(address(sale));
        emit NFTTrade.FeeSet(25, vm.getBlockTimestamp() + 1);
        sale.setFee(25);
        assertEq(sale.feeBps(), 25);
        assertEq(bids.feeBps(), 100, "each handler has its own rate");
    }

    /// Each order keeps the rate in force when it was created, through cuts and raises.
    function test_rateLockedAtCreation() public {
        (Order a, bytes memory ca) = _listArtId(1, 1 ether);
        vm.prank(treasury);
        sale.setFee(50);
        (Order sameBlock, bytes memory cs) = _listArtId(2, 1 ether);
        skip(1);
        (Order b, bytes memory cb) = _listArtId(3, 1 ether);
        vm.prank(treasury);
        sale.setFee(100);
        skip(1);
        (Order c, bytes memory cc) = _listArtId(4, 1 ether);

        assertEq(sale.feeBpsOf(address(a)), 100);
        assertEq(sale.feeBpsOf(address(sameBlock)), 100, "a change applies from the next second");
        assertEq(sale.feeBpsOf(address(b)), 50);
        assertEq(sale.feeBpsOf(address(c)), 100);

        _buyArt(b, cb, 1 ether);
        assertEq(treasury.balance, 0.005 ether, "cut-rate order keeps 0.5% after the raise");
        _buyArt(a, ca, 1 ether);
        _buyArt(sameBlock, cs, 1 ether);
        _buyArt(c, cc, 1 ether);
        assertEq(treasury.balance, 0.035 ether);
    }

    /// An order deployed outside `Market` has no creation time and pays the latest rate, so a
    /// hand-made clone cannot claim an old, lower rate.
    function test_handMadeOrderPaysLatestRate() public {
        vm.prank(treasury);
        sale.setFee(0);
        skip(1);
        art.mint(seller, 1);
        bytes memory config = abi.encode(NFTSale.Config(art, 1, _fixed(1 ether), seller, 1000));
        vm.prank(treasury);
        sale.setFee(100);
        Order order = Order(
            payable(
                Clones.cloneWithImmutableArgs(
                    market.implementation(),
                    abi.encodePacked(seller, address(sale), address(sale).codehash, keccak256(config))
                )
            )
        );
        assertEq(market.createdAt(order), 0);
        assertEq(sale.feeBpsOf(address(order)), 100);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
        _buyArt(order, config, 1 ether);
        assertEq(treasury.balance, 0.01 ether);
    }

    /// A fee recipient that refuses ETH stops every fill; nothing moves and the owner recovers.
    function test_refusingFeeRecipientBlocksFillsButNotRecovery() public {
        NFTSale blocked = new NFTSale(market, address(new RefusingTreasury()));
        (Order order, bytes memory config) = _listArt(blocked, 1 ether, 1000);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(art.ownerOf(1), address(order));
        vm.startPrank(seller);
        order.close();
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.stopPrank();
        assertEq(art.ownerOf(1), seller);
    }

    /// The fee recipient cannot refill the bid that pays it.
    function test_feeRecipientCannotReenter() public {
        ReentrantTreasury t = new ReentrantTreasury();
        NFTBid hostile = new NFTBid(market, address(t));
        bytes memory config = abi.encode(NFTBid.Config(art, true, 0, _fixed(1 ether), vault, 2));
        vm.deal(seller, 2 ether);
        vm.prank(seller);
        Order bid = market.create{value: 2 ether}(hostile, config, 0);
        art.mint(holder, 1);
        art.mint(address(t), 2);
        vm.prank(address(t));
        art.setApprovalForAll(address(hostile), true);
        t.arm(bid, abi.encodeCall(Order.fill, (config, abi.encode(2, 0, address(t)))));
        vm.startPrank(holder);
        art.setApprovalForAll(address(hostile), true);
        bid.fill(config, abi.encode(1, 0, holder));
        vm.stopPrank();
        assertFalse(t.reentered(), "reentry refused");
        assertEq(art.ownerOf(2), address(t));
        assertEq(hostile.fills(address(bid)), 1);
        assertEq(address(t).balance, 0.01 ether);
    }

    function _listArt(NFTSale handler, uint256 price, uint16 maxRoyaltyBps)
        internal
        returns (Order order, bytes memory config)
    {
        art.mint(seller, 1);
        config = abi.encode(NFTSale.Config(art, 1, _fixed(price), seller, maxRoyaltyBps));
        order = _create(seller, handler, config);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
    }

    function _listArtId(uint256 id, uint256 price) internal returns (Order order, bytes memory config) {
        art.mint(seller, id);
        config = abi.encode(NFTSale.Config(art, id, _fixed(price), seller, 1000));
        order = _create(seller, sale, config);
        vm.prank(seller);
        art.transferFrom(seller, address(order), id);
    }

    function _buyArt(Order order, bytes memory config, uint256 price) internal {
        vm.deal(buyer, price);
        vm.prank(buyer);
        order.fill{value: price}(config, abi.encode(buyer, price));
    }

    function _bidConfig(uint256 price) internal view returns (bytes memory) {
        return abi.encode(NFTBid.Config(art, true, 0, _fixed(price), vault, 5));
    }

    function _openBid(uint256 price, uint256 funds) internal returns (Order bid) {
        vm.deal(seller, funds);
        vm.prank(seller);
        bid = market.create{value: funds}(bids, _bidConfig(price), 0);
        art.mint(holder, 1);
        vm.prank(holder);
        art.setApprovalForAll(address(bids), true);
    }
}
