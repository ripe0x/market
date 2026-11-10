// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {Base} from "../utils/Base.sol";
import {TestNFT, RoyaltyNFT} from "../utils/Mocks.sol";

/// A phishing intermediary: a holder is tricked into calling this contract, which then calls
/// `fill` on an attacker's bid for each of the holder's tokens. Because the intermediary is the
/// one calling `fill`, it becomes `caller`, so the handler can only move the intermediary's own
/// tokens, not the holder's. Used to show the approval model's strength.
contract PhishingRouter {
    function sweep(Order bid, bytes calldata config, uint256[] calldata ids, address stealTo) external {
        for (uint256 i; i < ids.length; ++i) {
            bid.fill(config, abi.encode(ids[i], 0, stealTo));
        }
    }
}

/// An ERC721 whose `transferFrom` re-enters a target mid-delivery. The bidder would have to put
/// this hostile collection in its own config and a holder would have to sell one of its tokens;
/// used to prove delivery-path reentrancy cannot buy extra tokens from the same persistent bid.
contract ReentrantNFT is TestNFT {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (target != address(0) && !attempted) {
            attempted = true;
            (succeeded,) = target.call(payload);
        }
        super.transferFrom(from, to, id);
    }
}

/// Review PoCs for the NFT handlers. Every test here PASSES, each one demonstrating that an
/// attack path is safely refused (or that a suspected issue has no effect). No finding above
/// informational was reproduced.
contract NFTReviewPoC is Base {
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

    function _config(bool anyToken, uint256 id, uint256 price, uint256 maxFills) internal view returns (bytes memory) {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(price, price, block.timestamp, block.timestamp, 0);
        return abi.encode(NFTBid.Config(art, anyToken, id, s, vault, maxFills));
    }

    function _bid(bytes memory config, uint256 funds) internal returns (Order order) {
        vm.prank(bidder);
        order = market.create{value: funds}(bids, config, bytes32(++salt));
    }

    // -------------------------------------------------------------------------------------------
    // N-check 1: A genuine, from-scratch clone of the real implementation (so it passes
    // `_isOrder`) still cannot be used to call `onFill` with an arbitrary `caller`, because
    // `caller` can only be set by `Order.fill`, and `onFill` requires `filling() == true`.
    // This is the strongest look-alike: real Order code, attacker-chosen immutable args.
    // -------------------------------------------------------------------------------------------
    function test_lookAlikeCloneCannotSpoofCaller() public {
        bytes memory config = _config(true, 0, 1 ether, 1);
        // Attacker crafts a real clone with handler == bids and themselves as owner.
        bytes memory args =
            abi.encodePacked(attacker, address(bids), address(bids).codehash, keccak256(config));
        Order clone = Order(payable(Clones.cloneWithImmutableArgs(market.implementation(), args)));
        vm.deal(address(clone), 1 ether);

        // It passes _isOrder, handler()==bids, but filling() is false outside a real fill.
        // Attacker (owner) closes it and tries to drive onFill naming the holder as caller.
        vm.startPrank(attacker);
        clone.close();
        vm.expectRevert(NFTTrade.NotAFill.selector);
        clone.execute(address(bids), 0, abi.encodeCall(IOrderHandler.onFill, (holder, 0, config, abi.encode(1, 0, attacker))));
        vm.stopPrank();

        assertEq(art.ownerOf(1), holder, "holder keeps the token");
    }

    // -------------------------------------------------------------------------------------------
    // N-check 2: setApprovalForAll to the shared handler cannot be swept by a phishing
    // intermediary contract. When a contract calls `fill`, IT becomes `caller`, so the handler
    // moves only that contract's tokens, never the approver's. This bounds the approval risk to
    // the holder's own directly-signed fills (one token per tx).
    // -------------------------------------------------------------------------------------------
    function test_phishingRouterCannotSweepApprovedTokens() public {
        bytes memory config = _config(true, 0, 1 ether, 10);
        Order order = _bid(config, 10 ether);

        PhishingRouter router = new PhishingRouter();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;

        // Even if the holder is tricked into calling the router, the router is `caller` and owns
        // none of the holder's tokens, so every transferFrom reverts.
        vm.prank(holder);
        vm.expectRevert();
        router.sweep(order, config, ids, attacker);

        for (uint256 i = 1; i <= 3; ++i) {
            assertEq(art.ownerOf(i), holder, "holder keeps all tokens");
        }
    }

    // -------------------------------------------------------------------------------------------
    // N-check 3: A hostile collection placed in a bid's own config cannot, by re-entering during
    // delivery, buy an extra token from the same persistent bid: the order's `filling` flag
    // blocks the nested fill, so `fills` advances by exactly one.
    // -------------------------------------------------------------------------------------------
    function test_deliveryReentrancyCannotOverfillSameBid() public {
        ReentrantNFT evil = new ReentrantNFT();
        evil.mint(holder, 1);
        evil.mint(holder, 2);
        vm.prank(holder);
        evil.setApprovalForAll(address(bids), true);

        NFTTrade.Schedule memory s =
            NFTTrade.Schedule(1 ether, 1 ether, block.timestamp, block.timestamp, 0);
        bytes memory config = abi.encode(NFTBid.Config(IERC721(address(evil)), true, 0, s, vault, 5));
        Order order = _bid(config, 5 ether);

        // During delivery of token 1, re-enter the same order to buy token 2.
        evil.arm(address(order), abi.encodeCall(Order.fill, (config, abi.encode(2, 0, holder))));

        vm.prank(holder);
        order.fill(config, abi.encode(1, 0, holder));

        assertTrue(evil.attempted(), "reentrancy was attempted");
        assertFalse(evil.succeeded(), "nested fill of the same order refused");
        assertEq(bids.fills(address(order)), 1, "exactly one fill counted");
        assertEq(evil.ownerOf(1), vault);
        assertEq(evil.ownerOf(2), holder, "second token not taken");
    }

    // -------------------------------------------------------------------------------------------
    // INFO: NFTSale.Config.maxRoyaltyBps is a uint16 that may exceed 10_000, making the seller's
    // cap `price * bps / 10_000` larger than `price`. This has no adverse effect: royaltyOf
    // already reverts if royalty > price, so the buyer never overpays and proceeds never
    // underflow. Shown here for completeness.
    // -------------------------------------------------------------------------------------------
    function test_info_maxRoyaltyBpsAboveDenominatorIsHarmless() public {
        NFTSale saleH = new NFTSale(market);
        RoyaltyNFT c = new RoyaltyNFT();
        c.setRoyalty(royalty, 10_000); // 100% royalty, the maximum royaltyOf allows
        c.mint(seller, 1);
        NFTTrade.Schedule memory s =
            NFTTrade.Schedule(1 ether, 1 ether, block.timestamp, block.timestamp, 0);
        bytes memory config = abi.encode(NFTSale.Config(c, 1, s, seller, 20_000)); // cap = 2x price
        Order order = _create(seller, saleH, config);
        vm.prank(seller);
        c.transferFrom(seller, address(order), 1);

        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));

        assertEq(royalty.balance, 1 ether, "royalty capped at price, never above");
        assertEq(seller.balance, 0, "proceeds are price - royalty = 0, no underflow");
        assertEq(c.ownerOf(1), buyer);
    }
}
