// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Base.t.sol";

contract RejectsEth {
    function buy(Market m, AdvancedOrder calldata l) external payable {
        m.buy{value: msg.value}(l);
    }
}

contract BuyTest is Base {
    address buyer = makeAddr("buyer");
    uint256 start;

    function setUp() public {
        loadFixture("item_offer");
        deployMarket();
        start = block.timestamp;
        vm.deal(buyer, 100 ether);
    }

    function decliningListing() internal returns (AdvancedOrder memory) {
        return listing(2 ether, 1 ether, start, start + 10 days, 1);
    }

    function total(uint256 price) internal pure returns (uint256) {
        return price + price * 20 / 10_000;
    }

    function test_buyAtCurrentPrice() public {
        AdvancedOrder memory l = decliningListing();
        vm.warp(start + 5 days);
        uint256 price = market.currentPrice(l.parameters);
        assertEq(price, 1.5 ether);

        vm.prank(buyer);
        uint256 gas = gasleft();
        market.buy{value: total(price)}(l);
        emit log_named_uint("buy gas", gas - gasleft());

        assertEq(IERC721(nft).ownerOf(tokenId), buyer);
        assertEq(WETH.balanceOf(seller.addr), price);
        assertEq(WETH.balanceOf(protocol), price * 20 / 10_000);
        assertEq(buyer.balance, 100 ether - total(price));
        assertEq(WETH.balanceOf(address(market)), 0);
        assertEq(address(market).balance, 0);
    }

    function test_excessRefunded() public {
        AdvancedOrder memory l = decliningListing();
        vm.warp(start + 1 days);
        uint256 quoted = total(market.currentPrice(l.parameters));
        vm.warp(start + 2 days); // price fell while the transaction waited
        uint256 due = total(market.currentPrice(l.parameters));
        vm.prank(buyer);
        market.buy{value: quoted}(l);
        assertEq(buyer.balance, 100 ether - due);
        assertEq(address(market).balance, 0);
    }

    function test_revertWhenUnderpaid() public {
        AdvancedOrder memory l = decliningListing();
        uint256 due = total(market.currentPrice(l.parameters));
        vm.prank(buyer);
        vm.expectRevert(Market.InsufficientPayment.selector);
        market.buy{value: due - 1}(l);
    }

    /// Market's price must equal Seaport's to the wei at every instant, or buy
    /// would revert (too little WETH) or strand WETH (too much).
    function testFuzz_priceMatchesSeaport(uint256 startAmount, uint256 endAmount, uint256 elapsed) public {
        startAmount = bound(startAmount, 1, 50 ether); // Seaport rejects zero-amount items
        endAmount = bound(endAmount, 0, startAmount);
        elapsed = bound(elapsed, 0, 10 days - 1);
        AdvancedOrder memory l = listing(startAmount, endAmount, start, start + 10 days, 7);
        vm.warp(start + elapsed);
        uint256 price = market.currentPrice(l.parameters);
        assertGe(price, endAmount);
        assertLe(price, startAmount);

        vm.prank(buyer);
        market.buy{value: total(price)}(l);
        assertEq(WETH.balanceOf(seller.addr), price, "seaport pulled exactly price");
        assertEq(WETH.balanceOf(address(market)), 0);
    }

    function testFuzz_priceNeverIncreases(uint256 t1, uint256 t2) public {
        AdvancedOrder memory l = listing(3 ether + 7, 1 ether - 3, start, start + 7 days + 13, 8);
        t1 = bound(t1, start, start + 7 days + 12);
        t2 = bound(t2, t1, start + 7 days + 12);
        vm.warp(t1);
        uint256 p1 = market.currentPrice(l.parameters);
        vm.warp(t2);
        assertLe(market.currentPrice(l.parameters), p1);
    }

    function test_zeroFloorReachesNearZero() public {
        AdvancedOrder memory l = listing(1 ether, 0, start, start + 1 days, 9);
        vm.warp(start + 1 days - 1);
        uint256 price = market.currentPrice(l.parameters);
        assertLt(price, 0.00002 ether);
        vm.prank(buyer);
        market.buy{value: total(price)}(l);
        assertEq(IERC721(nft).ownerOf(tokenId), buyer);
    }

    function test_revertOnSecondBuy() public {
        AdvancedOrder memory l = decliningListing();
        vm.prank(buyer);
        market.buy{value: 3 ether}(l);
        vm.expectRevert();
        vm.prank(buyer);
        market.buy{value: 3 ether}(l);
    }

    function test_revertOnReplayEvenIfSellerReacquires() public {
        AdvancedOrder memory l = decliningListing();
        vm.prank(buyer);
        market.buy{value: 3 ether}(l);
        vm.prank(buyer);
        IERC721Full(nft).transferFrom(buyer, seller.addr, tokenId);
        vm.prank(buyer);
        vm.expectRevert(); // Seaport marks the order filled
        market.buy{value: 3 ether}(l);
    }

    function test_revertWhenCancelled() public {
        AdvancedOrder memory l = decliningListing();
        OrderComponents[] memory c = new OrderComponents[](1);
        c[0] = components(2 ether, 1 ether, start, start + 10 days, 1);
        vm.prank(seller.addr);
        SEAPORT.cancel(c);
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 3 ether}(l);
    }

    function test_revertWhenCounterIncremented() public {
        AdvancedOrder memory l = decliningListing();
        vm.prank(seller.addr);
        SEAPORT.incrementCounter();
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 3 ether}(l);
    }

    function test_revertBeforeStartAndAtEnd() public {
        AdvancedOrder memory l = listing(2 ether, 1 ether, start + 1 hours, start + 2 hours, 10);
        vm.prank(buyer);
        vm.expectRevert(Market.NotListing.selector);
        market.buy{value: 3 ether}(l);
        vm.warp(start + 2 hours);
        vm.prank(buyer);
        vm.expectRevert(Market.NotListing.selector);
        market.buy{value: 3 ether}(l);
    }

    function test_revertWhenSellerRevokedApproval() public {
        AdvancedOrder memory l = decliningListing();
        vm.prank(seller.addr);
        IERC721Full(nft).setApprovalForAll(OS_CONDUIT, false);
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 3 ether}(l);
        assertEq(buyer.balance, 100 ether);
    }

    function test_revertWhenSignatureWrong() public {
        AdvancedOrder memory l = decliningListing();
        l.parameters.consideration[0].endAmount = 0; // not what the seller signed
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 3 ether}(l);
    }

    function test_revertWhenRefundRejected() public {
        RejectsEth c = new RejectsEth();
        vm.deal(address(c), 3 ether);
        AdvancedOrder memory l = decliningListing();
        vm.expectRevert(Market.RefundFailed.selector);
        c.buy{value: 3 ether}(market, l);
        assertEq(IERC721(nft).ownerOf(tokenId), seller.addr);
    }

    function test_rejectsOtherShapes() public {
        OrderComponents memory c = components(1 ether, 1 ether, start, start + 1 days, 11);
        c.orderType = OrderType.FULL_OPEN;
        expectNotListing(c);

        c = components(1 ether, 1 ether, start, start + 1 days, 12);
        c.zone = address(0);
        expectNotListing(c);

        c = components(1 ether, 1 ether, start, start + 1 days, 13);
        c.consideration[0].token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        expectNotListing(c);

        c = components(1 ether, 1 ether, start, start + 1 days, 14);
        c.consideration[0].recipient = payable(address(market));
        expectNotListing(c);

        c = components(1 ether, 1 ether, start, start + 1 days, 15);
        c.consideration[0].itemType = ItemType.NATIVE;
        c.consideration[0].token = address(0);
        expectNotListing(c);
    }

    function expectNotListing(OrderComponents memory c) internal {
        AdvancedOrder memory l = signed(seller, c);
        vm.prank(buyer);
        vm.expectRevert(Market.NotListing.selector);
        market.buy{value: 3 ether}(l);
    }
}
