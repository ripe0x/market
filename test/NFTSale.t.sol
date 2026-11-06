// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Base} from "./utils/Base.sol";
import {Reenterer, Rejecter, RoyaltyNFT, ScriptedRoyaltyNFT, LyingNFT} from "./utils/Mocks.sol";

contract NFTSaleTest is Base {
    NFTSale sale;
    RoyaltyNFT art;
    address proceeds = makeAddr("proceeds");
    address recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        sale = new NFTSale();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500); // 5%
    }

    function _schedule(uint256 startPrice, uint256 endPrice, uint256 duration, uint256 expiry)
        internal
        view
        returns (NFTTrade.Schedule memory)
    {
        return NFTTrade.Schedule(startPrice, endPrice, block.timestamp, block.timestamp + duration, expiry);
    }

    function _config(IERC721 token, uint256 id, NFTTrade.Schedule memory s, uint16 maxRoyaltyBps)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(NFTSale.Config(token, id, s, proceeds, maxRoyaltyBps));
    }

    /// Mints `id` of `art` to the seller, lists it and deposits it.
    function _list(NFTTrade.Schedule memory s, uint16 maxRoyaltyBps) internal returns (Order order, bytes memory config) {
        art.mint(seller, 1);
        config = _config(art, 1, s, maxRoyaltyBps);
        order = _create(seller, sale, config);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
    }

    function _buy(Order order, bytes memory config, uint256 value, uint256 maxPrice) internal returns (bytes memory) {
        vm.prank(buyer);
        return order.fill{value: value}(config, abi.encode(recipient, maxPrice));
    }

    function test_fixedPriceSale() public {
        (Order order, bytes memory config) = _list(_schedule(2 ether, 2 ether, 0, 0), 1000);
        uint256 buyerBefore = buyer.balance;

        bytes memory ret = _buy(order, config, 3 ether, 2 ether);

        assertEq(art.ownerOf(1), recipient, "token delivered");
        assertEq(royalty.balance, 0.1 ether, "5% royalty");
        assertEq(proceeds.balance, 1.9 ether, "seller proceeds");
        assertEq(buyerBefore - buyer.balance, 2 ether, "buyer spends the price, excess refunded");
        assertEq(address(order).balance, 0, "order keeps nothing");
        assertEq(address(sale).balance, 0, "handler keeps nothing");
        assertTrue(order.closed(), "single use");
        (uint256 price, uint256 paidRoyalty) = abi.decode(ret, (uint256, uint256));
        assertEq(price, 2 ether);
        assertEq(paidRoyalty, 0.1 ether);
    }

    function test_fallingPrice() public {
        (Order order, bytes memory config) = _list(_schedule(10 ether, 1 ether, 1000, 0), 1000);
        skip(250);
        (uint256 price,,) = sale.quote(abi.decode(config, (NFTSale.Config)));
        assertEq(price, 7.75 ether);
        _buy(order, config, price, price);
        assertEq(proceeds.balance, 7.75 ether * 95 / 100);
    }

    function test_priceHoldsAtEndPrice() public view {
        NFTTrade.Schedule memory s = _schedule(10 ether, 1 ether, 1000, 0);
        assertEq(sale.priceAt(s, s.endTime + 10 days), 1 ether);
        assertEq(sale.priceAt(s, s.startTime), 10 ether);
    }

    function test_risingScheduleRoundsTowardStart() public view {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(0, 2, 0, 3, 0);
        assertEq(sale.priceAt(s, 1), 0); // 0.67 rounds down
        s = NFTTrade.Schedule(2, 0, 0, 3, 0);
        assertEq(sale.priceAt(s, 1), 2); // 1.33 rounds up
    }

    function test_revertWhenAboveBuyerMax() public {
        (Order order, bytes memory config) = _list(_schedule(10 ether, 1 ether, 1000, 0), 1000);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.AboveMaxPrice.selector, 10 ether, 9 ether));
        _buy(order, config, 10 ether, 9 ether);
    }

    function test_revertWhenUnderpaid() public {
        (Order order, bytes memory config) = _list(_schedule(2 ether, 2 ether, 0, 0), 1000);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.Underpaid.selector, 2 ether, 1 ether));
        _buy(order, config, 1 ether, 2 ether);
    }

    function test_windowIsEnforced() public {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(1 ether, 1 ether, block.timestamp + 100, block.timestamp + 100, block.timestamp + 200);
        (Order order, bytes memory config) = _list(s, 1000);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.NotStarted.selector, s.startTime));
        _buy(order, config, 1 ether, 1 ether);
        vm.warp(s.expiry);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.Expired.selector, s.expiry));
        _buy(order, config, 1 ether, 1 ether);
        vm.warp(s.expiry - 1);
        _buy(order, config, 1 ether, 1 ether);
        assertEq(art.ownerOf(1), recipient);
    }

    function test_royaltyAboveSellerLimitReverts() public {
        art.setRoyalty(royalty, 1001);
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.RoyaltyAboveLimit.selector, 0.1001 ether, 0.1 ether));
        _buy(order, config, 1 ether, 1 ether);
        assertEq(art.ownerOf(1), address(order), "still escrowed");
    }

    function test_noRoyaltyWithoutERC2981() public {
        nft.mint(seller, 7);
        bytes memory config = _config(nft, 7, _schedule(1 ether, 1 ether, 0, 0), 0);
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 7);
        _buy(order, config, 1 ether, 1 ether);
        assertEq(proceeds.balance, 1 ether);
        assertEq(nft.ownerOf(7), recipient);
    }

    function test_royaltyFailuresRevert() public {
        ScriptedRoyaltyNFT s = new ScriptedRoyaltyNFT();
        s.mint(seller, 1);
        bytes memory config = _config(s, 1, _schedule(1 ether, 1 ether, 0, 0), 10_000);
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        s.transferFrom(seller, address(order), 1);

        s.script(royalty, 0, true);
        vm.expectRevert("royalty broken");
        _buy(order, config, 1 ether, 1 ether);

        s.script(royalty, 1 ether + 1, false);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.BadRoyalty.selector, royalty, 1 ether + 1, 1 ether));
        _buy(order, config, 1 ether, 1 ether);

        s.script(address(0), 1, false);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.BadRoyalty.selector, address(0), 1, 1 ether));
        _buy(order, config, 1 ether, 1 ether);

        s.script(address(new Rejecter()), 0.1 ether, false);
        vm.expectRevert();
        _buy(order, config, 1 ether, 1 ether);

        // A receiver of zero when nothing is owed is fine.
        s.script(address(0), 0, false);
        _buy(order, config, 1 ether, 1 ether);
        assertEq(s.ownerOf(1), recipient);
    }

    function test_rejectingProceedsRecipientBlocksOnlyThisSale() public {
        art.mint(seller, 1);
        bytes memory config = abi.encode(
            NFTSale.Config(art, 1, _schedule(1 ether, 1 ether, 0, 0), address(new Rejecter()), 1000)
        );
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
        vm.expectRevert();
        _buy(order, config, 1 ether, 1 ether);
        // The seller recovers by closing.
        vm.startPrank(seller);
        order.close();
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.stopPrank();
        assertEq(art.ownerOf(1), seller);
    }

    function test_zeroProceedsRecipientRejected() public {
        art.mint(seller, 1);
        bytes memory config =
            abi.encode(NFTSale.Config(art, 1, _schedule(1 ether, 1 ether, 0, 0), address(0), 1000));
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
        vm.expectRevert(NFTTrade.ZeroAddress.selector);
        _buy(order, config, 1 ether, 1 ether);
    }

    function test_zeroRecipientRejected() public {
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        vm.prank(buyer);
        vm.expectRevert(NFTTrade.ZeroAddress.selector);
        order.fill{value: 1 ether}(config, abi.encode(address(0), 1 ether));
    }

    function test_soldOnce() public {
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        _buy(order, config, 1 ether, 1 ether);
        vm.expectRevert(Order.OrderClosed.selector);
        _buy(order, config, 1 ether, 1 ether);
    }

    function test_cancelAndRecover() public {
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        vm.deal(address(order), 0.5 ether); // stray ETH sent to the order

        // Active: the owner cannot take the token.
        vm.prank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));

        vm.startPrank(seller);
        order.close();
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        order.execute(seller, 0.5 ether, "");
        vm.stopPrank();
        assertEq(art.ownerOf(1), seller);
        assertEq(seller.balance, 0.5 ether);

        vm.expectRevert(Order.OrderClosed.selector);
        _buy(order, config, 1 ether, 1 ether);
    }

    function test_onlyOwnerCancels() public {
        (Order order,) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        order.close();
    }

    function test_withoutTokenTheFillReverts() public {
        art.mint(seller, 1);
        bytes memory config = _config(art, 1, _schedule(1 ether, 1 ether, 0, 0), 1000);
        Order order = _create(seller, sale, config); // never deposited
        vm.expectRevert();
        _buy(order, config, 1 ether, 1 ether);
    }

    function test_depositBeforeCreate() public {
        art.mint(seller, 1);
        bytes memory config = _config(art, 1, _schedule(1 ether, 1 ether, 0, 0), 1000);
        address predicted = market.orderAddress(seller, sale, keccak256(config), bytes32(uint256(99)));
        vm.prank(seller);
        art.safeTransferFrom(seller, predicted, 1); // no code yet: no callback
        vm.prank(seller);
        Order order = market.create(sale, config, bytes32(uint256(99)));
        assertEq(address(order), predicted);
        _buy(order, config, 1 ether, 1 ether);
        assertEq(art.ownerOf(1), recipient);
    }

    function test_lyingCollectionCannotFakeDelivery() public {
        LyingNFT lying = new LyingNFT();
        lying.mint(seller, 1);
        bytes memory config = _config(lying, 1, _schedule(1 ether, 1 ether, 0, 0), 0);
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        lying.mint(address(order), 2); // irrelevant token
        vm.expectRevert(NFTTrade.NotDelivered.selector);
        _buy(order, config, 1 ether, 1 ether);
    }

    function test_buyerCannotReenterOnRefund() public {
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        Reenterer contractBuyer = new Reenterer();
        vm.deal(address(contractBuyer), 2 ether);
        // The refund triggers a second fill of the same order, which must fail.
        contractBuyer.arm(address(order), abi.encodeCall(Order.fill, (config, abi.encode(recipient, 1 ether))));
        contractBuyer.call(address(order), 2 ether, abi.encodeCall(Order.fill, (config, abi.encode(recipient, 1 ether))));
        assertTrue(contractBuyer.attempted());
        assertFalse(contractBuyer.succeeded(), "reentrant fill refused");
        assertEq(art.ownerOf(1), recipient);
    }

    function test_royaltyReceiverCannotReenter() public {
        Reenterer r = new Reenterer();
        art.setRoyalty(address(r), 500);
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        r.arm(address(order), abi.encodeCall(Order.execute, (address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(order), address(r), 1)))));
        _buy(order, config, 1 ether, 1 ether);
        assertTrue(r.attempted());
        assertFalse(r.succeeded());
        assertEq(art.ownerOf(1), recipient);
        assertEq(address(r).balance, 0.05 ether);
    }

    function test_directHandlerCallMovesNothing() public {
        (Order order, bytes memory config) = _list(_schedule(1 ether, 1 ether, 0, 0), 1000);
        vm.prank(attacker);
        vm.expectRevert(); // the attacker is not an order: `execute` does not exist
        sale.onFill(attacker, 1 ether, config, abi.encode(attacker, 1 ether));
        assertEq(art.ownerOf(1), address(order));
    }

    /// Whatever the time and payment, money is conserved and the split matches the quote.
    function testFuzz_settlementConserves(uint96 startPrice, uint96 endPrice, uint32 duration, uint32 wait, uint96 extra, uint16 bps)
        public
    {
        bps = uint16(bound(bps, 0, 10_000));
        art.setRoyalty(royalty, bps);
        (Order order, bytes memory config) = _list(_schedule(startPrice, endPrice, duration, 0), 10_000);
        skip(wait);
        (uint256 price,, uint256 r) = sale.quote(abi.decode(config, (NFTSale.Config)));
        uint256 lo = startPrice < endPrice ? startPrice : endPrice;
        uint256 hi = startPrice < endPrice ? endPrice : startPrice;
        assertGe(price, lo);
        assertLe(price, hi);
        uint256 value = price + extra;
        vm.deal(buyer, value);
        _buy(order, config, value, price);
        assertEq(buyer.balance, extra, "buyer pays exactly the price");
        assertEq(royalty.balance, r);
        assertEq(proceeds.balance, price - r);
        assertEq(r, price * bps / 10_000);
        assertEq(address(order).balance, 0);
    }
}
