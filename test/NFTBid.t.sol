// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {HandlerBase} from "../handlers/HandlerBase.sol";
import {Base} from "./utils/Base.sol";
import {Reenterer, RoyaltyNFT, ScriptHandler, LyingNFT} from "./utils/Mocks.sol";

/// Claims to be an order in the middle of a fill, bound to whatever handler it is asked about.
contract FakeOrder {
    IOrderHandler public handler;
    bool public constant filling = true;

    constructor(IOrderHandler h) {
        handler = h;
    }

    function attack(bytes calldata config, address victim, uint256 id) external {
        handler.onFill(victim, 0, config, abi.encode(id, 0, msg.sender));
    }
}

contract NFTBidTest is Base {
    RoyaltyNFT art;
    address bidder = makeAddr("bidder");
    address vault = makeAddr("vault");
    address holder = makeAddr("holder");

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500);
        for (uint256 i = 1; i <= 5; ++i) {
            art.mint(holder, i);
        }
        vm.deal(bidder, 100 ether);
        vm.prank(holder);
        art.setApprovalForAll(address(bids), true);
    }

    function _config(bool anyToken, uint256 id, NFTTrade.Schedule memory s, uint256 maxFills)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(NFTBid.Config(art, anyToken, id, s, vault, maxFills));
    }

    function _bid(bytes memory config, uint256 funds) internal returns (Order order) {
        vm.prank(bidder);
        order = market.create{value: funds}(bids, config, bytes32(++salt));
    }

    function _sell(Order order, bytes memory config, uint256 id, uint256 minProceeds) internal returns (bytes memory) {
        vm.prank(holder);
        return order.fill(config, abi.encode(id, minProceeds, holder));
    }

    function test_singleTokenBid() public {
        bytes memory config = _config(false, 3, _fixed(2 ether), 1);
        Order order = _bid(config, 2 ether);
        _sell(order, config, 3, 1.9 ether);
        assertEq(art.ownerOf(3), vault);
        assertEq(holder.balance, 1.9 ether);
        assertEq(royalty.balance, 0.1 ether);
        assertEq(address(order).balance, 0);
        assertTrue(order.closed());
    }

    function test_wrongTokenRejected() public {
        bytes memory config = _config(false, 3, _fixed(2 ether), 1);
        Order order = _bid(config, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.WrongToken.selector, 4));
        _sell(order, config, 4, 0);
    }

    function test_risingBidAndSellerMinimum() public {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(1 ether, 3 ether, block.timestamp, block.timestamp + 1000, 0);
        bytes memory config = _config(true, 0, s, 1);
        Order order = _bid(config, 3 ether);
        skip(500);
        (uint256 price,, uint256 r) = bids.quote(address(order), abi.decode(config, (NFTBid.Config)), 1);
        assertEq(price, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.BelowMinProceeds.selector, 1.9 ether, 2 ether));
        _sell(order, config, 1, 2 ether);
        _sell(order, config, 1, price - r);
        assertEq(holder.balance, 1.9 ether);
        assertEq(bidder.balance, 97 ether, "bidder spent only what it deposited");
    }

    function test_persistentCollectionBid() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 3);
        Order order = _bid(config, 2 ether);
        _sell(order, config, 1, 0);
        _sell(order, config, 2, 0);
        assertEq(bids.fills(address(order)), 2);

        // Out of funds: reverts until anyone tops it up.
        vm.expectRevert(abi.encodeWithSelector(NFTBid.InsufficientFunds.selector, 1 ether, 0));
        _sell(order, config, 3, 0);
        vm.prank(buyer);
        (bool ok,) = address(order).call{value: 1 ether}("");
        assertTrue(ok);

        _sell(order, config, 3, 0);
        assertTrue(order.closed(), "closed after maxFills");
        vm.expectRevert(Order.OrderClosed.selector);
        _sell(order, config, 4, 0);
        for (uint256 i = 1; i <= 3; ++i) {
            assertEq(art.ownerOf(i), vault);
        }
    }

    function test_cancelAndRecoverFunds() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 10);
        Order order = _bid(config, 5 ether);
        _sell(order, config, 1, 0);
        vm.prank(bidder);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(bidder, 4 ether, "");
        vm.startPrank(bidder);
        order.close();
        order.execute(bidder, 4 ether, "");
        vm.stopPrank();
        assertEq(bidder.balance, 99 ether);
        vm.expectRevert(Order.OrderClosed.selector);
        _sell(order, config, 2, 0);
    }

    function test_windowIsEnforced() public {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(1 ether, 1 ether, block.timestamp, block.timestamp, block.timestamp + 10);
        bytes memory config = _config(true, 0, s, 1);
        Order order = _bid(config, 1 ether);
        vm.warp(block.timestamp + 10);
        vm.expectRevert(abi.encodeWithSelector(NFTTrade.Expired.selector, s.expiry));
        _sell(order, config, 1, 0);
    }

    function test_zeroProceedsRecipientRejected() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 1);
        Order order = _bid(config, 1 ether);
        vm.prank(holder);
        vm.expectRevert(NFTTrade.ZeroAddress.selector);
        order.fill(config, abi.encode(1, 0, address(0)));
    }

    /// `maxFills` 0 means one token, like 1.
    function test_zeroMaxFillsBuysOne() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 0);
        Order order = _bid(config, 2 ether);
        _sell(order, config, 1, 0);
        assertTrue(order.closed());
        assertEq(art.ownerOf(1), vault);
    }

    function test_ethWithFillRejected() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 1);
        Order order = _bid(config, 1 ether);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        vm.expectRevert(HandlerBase.UnexpectedETH.selector);
        order.fill{value: 1}(config, abi.encode(1, 0, holder));
    }

    function test_onlyTheFillerCanBeTakenFrom() public {
        bytes memory config = _config(true, 0, _fixed(1 ether), 1);
        Order order = _bid(config, 1 ether);
        // The attacker fills naming the holder's token; it is taken from the attacker, who does
        // not own it.
        vm.prank(attacker);
        vm.expectRevert();
        order.fill(config, abi.encode(1, 0, holder));
        assertEq(art.ownerOf(1), holder);
    }

    /// The front-running theft an approval to a bid's order would allow
    /// (`test_approvalToAnOrderBelongsToItsOwner`), refused by `NFTBid`.
    function test_bidderCannotStealApprovedTokens() public {
        bytes memory config = _config(false, 1, _fixed(1 ether), 1);
        Order order = _bid(config, 1 ether);

        // The bidder closes and tries everything as the order.
        vm.startPrank(bidder);
        order.close();
        vm.expectRevert(); // the holder approved the handler, not the order
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (holder, bidder, 1)));
        vm.expectRevert(NFTTrade.NotAFill.selector); // a genuine order, but not filling
        order.execute(address(bids), 0, abi.encodeCall(IOrderHandler.onFill, (holder, 0, config, abi.encode(1, 0, holder))));
        vm.stopPrank();

        // Pretending to be an order.
        FakeOrder fake = new FakeOrder(bids);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        fake.attack(config, holder, 1);
        vm.prank(attacker);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        bids.onFill(holder, 0, config, abi.encode(1, 0, holder));

        assertEq(art.ownerOf(1), holder);
    }

    /// Finding A1, the reason the holder approves the handler: an approval to any order is an
    /// approval to its owner, who can close the order and use it before the holder's fill lands.
    function test_approvalToAnOrderBelongsToItsOwner() public {
        Order order = _create(bidder, new ScriptHandler(), "");
        vm.prank(holder);
        art.approve(address(order), 1);
        vm.startPrank(bidder);
        order.close();
        order.execute(address(art), 0, abi.encodeCall(IERC721.transferFrom, (holder, bidder, 1)));
        vm.stopPrank();
        assertEq(art.ownerOf(1), bidder);
    }

    function test_otherOrdersCannotUseTheHandlersApproval() public {
        // A genuine order bound to a hostile handler makes itself call NFTBid during its fill.
        ScriptHandler script = new ScriptHandler();
        bytes memory bidConfig = _config(true, 0, _fixed(0), 1);
        Order hostile = _create(attacker, script, "");
        bytes memory steps = script.script(
            true, address(bids), 0, abi.encodeCall(IOrderHandler.onFill, (holder, 0, bidConfig, abi.encode(1, 0, holder)))
        );
        vm.prank(attacker);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        hostile.fill("", steps);
        assertEq(art.ownerOf(1), holder);
    }

    function test_cloneOutsideMarketIsStillAnHonestOrder() public {
        // Anyone can deploy a clone of the implementation without Market. It runs Order's code,
        // so it still reports the true caller and is as safe to accept as a Market order.
        bytes memory config = _config(true, 0, _fixed(1 ether), 1);
        bytes memory args = abi.encodePacked(bidder, address(bids), address(bids).codehash, keccak256(config));
        Order order = Order(payable(Clones.cloneWithImmutableArgs(market.implementation(), args)));
        vm.deal(address(order), 1 ether);
        vm.prank(attacker);
        vm.expectRevert(); // the attacker owns no token
        order.fill(config, abi.encode(1, 0, holder));
        _sell(order, config, 1, 0);
        assertEq(art.ownerOf(1), vault);
    }

    function test_royaltyReceiverCannotReenter() public {
        Reenterer r = new Reenterer();
        art.setRoyalty(address(r), 500);
        bytes memory config = _config(true, 0, _fixed(1 ether), 5);
        Order order = _bid(config, 5 ether);
        r.arm(address(order), abi.encodeCall(Order.fill, (config, abi.encode(2, 0, holder))));
        _sell(order, config, 1, 0);
        assertTrue(r.attempted());
        assertFalse(r.succeeded(), "same order cannot be reentered");
        assertEq(bids.fills(address(order)), 1);
    }

    function test_lyingCollectionCannotFakeDelivery() public {
        LyingNFT lying = new LyingNFT();
        lying.mint(holder, 1);
        bytes memory config = abi.encode(NFTBid.Config(lying, true, 0, _fixed(1 ether), vault, 1));
        Order order = _bid(config, 1 ether);
        vm.prank(holder);
        vm.expectRevert(NFTTrade.NotDelivered.selector);
        order.fill(config, abi.encode(1, 0, holder));
    }

    function test_recipientAlreadyOwningIsRejected() public {
        vm.prank(holder);
        art.transferFrom(holder, vault, 1);
        bytes memory config = _config(true, 0, _fixed(1 ether), 1);
        Order order = _bid(config, 1 ether);
        vm.prank(vault);
        vm.expectRevert(NFTTrade.NotDelivered.selector);
        order.fill(config, abi.encode(1, 0, holder));
    }

    function testFuzz_bidSettlementConserves(uint96 price, uint16 bps, uint96 extraFunds) public {
        bps = uint16(bound(bps, 0, 10_000));
        price = uint96(bound(price, 0, 50 ether));
        extraFunds = uint96(bound(extraFunds, 0, 40 ether));
        art.setRoyalty(royalty, bps);
        bytes memory config = _config(true, 0, _fixed(price), 1);
        Order order = _bid(config, uint256(price) + extraFunds);
        uint256 funded = address(order).balance;
        _sell(order, config, 1, 0);
        uint256 r = uint256(price) * bps / 10_000;
        assertEq(royalty.balance, r);
        assertEq(holder.balance, price - r);
        assertEq(address(order).balance, funded - price);
        assertEq(address(bids).balance, 0);
    }
}
