// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {FeeConfig} from "../handlers/FeeConfig.sol";
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

/// The fee on `NFTSale` and `NFTBid` fills: at most 1%, set by the `FeeConfig` admin, locked per order at creation.
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
        assertEq(fees.MAX_FEE_BPS(), 100);
        assertEq(fees.feeBps(), 100, "starts at 1%");
        assertEq(fees.recipient(), treasury);
        assertEq(fees.admin(), feeAdmin);
        assertEq(address(fees.market()), address(market));
        assertEq(address(sale.fees()), address(fees));
        assertEq(address(bids.fees()), address(fees));
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(FeeConfig.ZeroAddress.selector);
        new FeeConfig(market, address(0), treasury);
        vm.expectRevert(FeeConfig.ZeroAddress.selector);
        new FeeConfig(market, feeAdmin, address(0));
        vm.startPrank(feeAdmin);
        vm.expectRevert(FeeConfig.ZeroAddress.selector);
        fees.setRecipient(address(0));
        vm.stopPrank();
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

    /// Only the admin changes anything; the recipient, sellers and buyers cannot.
    function test_onlyAdminChangesTerms() public {
        address[3] memory others = [treasury, seller, buyer];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(FeeConfig.NotAdmin.selector);
            fees.setFee(0);
            vm.expectRevert(FeeConfig.NotAdmin.selector);
            fees.setRecipient(others[i]);
            vm.expectRevert(FeeConfig.NotAdmin.selector);
            fees.setAdmin(others[i]);
            vm.stopPrank();
        }
        vm.startPrank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(FeeConfig.FeeTooHigh.selector, 101));
        fees.setFee(101);
        vm.expectEmit(address(fees));
        emit FeeConfig.FeeSet(25, vm.getBlockTimestamp() + 1);
        fees.setFee(25);
        vm.stopPrank();
        assertEq(fees.feeBps(), 25, "one rate for both handlers");
    }

    /// A new recipient receives the fee of every later fill, including orders created before.
    function test_recipientChangeAppliesToEveryFill() public {
        (Order order, bytes memory config) = _listArt(sale, 1 ether, 1000);
        address next = makeAddr("next treasury");
        vm.prank(feeAdmin);
        fees.setRecipient(next);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(next.balance, 0.01 ether);
        assertEq(treasury.balance, 0);
    }

    /// The role moves only when the offered account accepts; the old admin then loses it.
    function test_adminHandoff() public {
        address next = makeAddr("next admin");
        vm.prank(feeAdmin);
        fees.setAdmin(next);
        assertEq(fees.admin(), feeAdmin, "nothing changes before acceptance");
        vm.prank(buyer);
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        fees.acceptAdmin();
        vm.prank(next);
        fees.acceptAdmin();
        assertEq(fees.admin(), next);
        assertEq(fees.pendingAdmin(), address(0));
        vm.prank(feeAdmin);
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        fees.setFee(0);
        vm.prank(next);
        fees.setFee(0);
        assertEq(fees.feeBps(), 0);
    }

    /// A mistyped offer is replaced or withdrawn; nobody can accept a withdrawn one.
    function test_adminOfferWithdrawn() public {
        vm.startPrank(feeAdmin);
        fees.setAdmin(makeAddr("typo"));
        fees.setAdmin(address(0));
        vm.stopPrank();
        vm.prank(makeAddr("typo"));
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        fees.acceptAdmin();
        vm.prank(address(0));
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        fees.acceptAdmin();
        assertEq(fees.admin(), feeAdmin);
    }

    /// Each order keeps the rate in force when it was created, through cuts and raises.
    function test_rateLockedAtCreation() public {
        (Order a, bytes memory ca) = _listArtId(1, 1 ether);
        vm.prank(feeAdmin);
        fees.setFee(50);
        (Order sameBlock, bytes memory cs) = _listArtId(2, 1 ether);
        skip(1);
        (Order b, bytes memory cb) = _listArtId(3, 1 ether);
        vm.prank(feeAdmin);
        fees.setFee(100);
        skip(1);
        (Order c, bytes memory cc) = _listArtId(4, 1 ether);

        assertEq(fees.feeBpsOf(address(a)), 100);
        assertEq(fees.feeBpsOf(address(sameBlock)), 100, "a change applies from the next second");
        assertEq(fees.feeBpsOf(address(b)), 50);
        assertEq(fees.feeBpsOf(address(c)), 100);

        _buyArt(b, cb, 1 ether);
        assertEq(treasury.balance, 0.005 ether, "cut-rate order keeps 0.5% after the raise");
        _buyArt(a, ca, 1 ether);
        _buyArt(sameBlock, cs, 1 ether);
        _buyArt(c, cc, 1 ether);
        assertEq(treasury.balance, 0.035 ether);
    }

    /// Across many changes, every order still finds the rate of its own creation second.
    function test_rateLookupAcrossManyChanges() public {
        Order[] memory orders = new Order[](40);
        uint256[] memory rate = new uint256[](40);
        for (uint256 i; i < 40; ++i) {
            if (i % 3 == 0) {
                vm.prank(feeAdmin);
                fees.setFee(uint16(i * 7 % 101));
                skip(1);
            }
            rate[i] = fees.feeBps();
            (orders[i],) = _listArtId(i + 1, 1 ether);
            skip(i % 2);
        }
        for (uint256 i; i < 40; ++i) {
            assertEq(fees.feeBpsOf(address(orders[i])), rate[i]);
        }
    }

    /// An order deployed outside `Market` has no creation time and pays the latest rate, so a
    /// hand-made clone cannot claim an old, lower rate.
    function test_handMadeOrderPaysLatestRate() public {
        vm.prank(feeAdmin);
        fees.setFee(0);
        skip(1);
        art.mint(seller, 1);
        bytes memory config = abi.encode(NFTSale.Config(art, 1, _fixed(1 ether), seller, 1000));
        vm.prank(feeAdmin);
        fees.setFee(100);
        Order order = Order(
            payable(Clones.cloneWithImmutableArgs(
                    market.implementation(),
                    abi.encodePacked(seller, address(sale), address(sale).codehash, keccak256(config))
                ))
        );
        assertEq(market.createdAt(order), 0);
        assertEq(fees.feeBpsOf(address(order)), 100);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
        _buyArt(order, config, 1 ether);
        assertEq(treasury.balance, 0.01 ether);
    }

    /// A fee recipient that refuses ETH stops fills until the admin replaces it; the owner can
    /// still recover meanwhile.
    function test_refusingFeeRecipientIsReplaceable() public {
        address refusing = address(new RefusingTreasury());
        vm.prank(feeAdmin);
        fees.setRecipient(refusing);
        (Order order, bytes memory config) = _listArt(sale, 1 ether, 1000);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(art.ownerOf(1), address(order));

        vm.prank(feeAdmin);
        fees.setRecipient(treasury);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(art.ownerOf(1), buyer);
        assertEq(treasury.balance, 0.01 ether);
    }

    function test_ownerRecoversWhileFeeRecipientRefuses() public {
        address refusing = address(new RefusingTreasury());
        vm.prank(feeAdmin);
        fees.setRecipient(refusing);
        (Order order,) = _listArt(sale, 1 ether, 1000);
        vm.startPrank(seller);
        order.close();
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.stopPrank();
        assertEq(art.ownerOf(1), seller);
    }

    /// The fee recipient cannot refill the bid that pays it.
    function test_feeRecipientCannotReenter() public {
        ReentrantTreasury t = new ReentrantTreasury();
        NFTBid hostile = new NFTBid(new FeeConfig(market, feeAdmin, address(t)));
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

    function test_latestScheduledGetterBeforeEffectiveBoundary() public {
        (Order order,) = _listArtId(42, 1 ether);
        vm.prank(feeAdmin);
        fees.setFee(0);
        assertEq(fees.feeBps(), 0, "latest scheduled rate immediately");
        assertEq(fees.feeBpsOf(address(order)), 100, "creation rate remains applicable");
        (Order sameSecond,) = _listArtId(43, 1 ether);
        assertEq(fees.feeBpsOf(address(sameSecond)), 100);
        skip(1);
        (Order nextSecond,) = _listArtId(44, 1 ether);
        assertEq(fees.feeBpsOf(address(nextSecond)), 0);
    }

    function test_delayedBidFundingRetainsLowCreationFee() public {
        vm.prank(feeAdmin);
        fees.setFee(0);
        skip(1);
        bytes memory config = _bidConfig(1 ether);
        Order bid = _openBid(1 ether, 0);
        vm.prank(feeAdmin);
        fees.setFee(100);
        skip(1);
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        (bool funded,) = address(bid).call{value: 1 ether}("");
        assertTrue(funded);
        vm.prank(holder);
        bid.fill(config, abi.encode(1, 0, holder));
        assertEq(treasury.balance, 0);
        assertEq(royalty.balance, 0.05 ether);
        assertEq(holder.balance, 0.95 ether);
        assertEq(fees.feeBpsOf(address(bid)), 0);
    }

    function test_closedSaleQuoteStillReturnsWhileFillReverts() public {
        (Order order, bytes memory config) = _listArtId(45, 1 ether);
        vm.prank(seller);
        order.close();
        (uint256 price,,,,) = sale.quote(address(order), abi.decode(config, (NFTSale.Config)));
        assertEq(price, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
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
