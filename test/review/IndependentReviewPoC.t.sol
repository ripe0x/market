// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Base} from "../utils/Base.sol";
import {Order, IOrderHandler} from "../../src/Order.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {TestNFT, RoyaltyNFT} from "../utils/Mocks.sol";

/// Independent adversarial review PoCs. Each test attempts a concrete attack from the brief and
/// asserts the outcome. Passing = the protocol behaved as the assertion says (most are "attack
/// refused"); the test name states what was tried.
contract IndependentReviewPoC is Base {
    // --- helpers ---------------------------------------------------------

    function _bidConfig(TestNFT collection, bool anyToken, uint256 tokenId, uint256 price, address recipient, uint256 maxFills)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            NFTBid.Config(IERC721(address(collection)), anyToken, tokenId, _fixed(price), recipient, maxFills)
        );
    }

    // --- (e) shared NFTBid approval cannot be abused ---------------------

    /// A victim approves the shared NFTBid handler (setApprovalForAll). An attacker deploys a
    /// fully genuine Order clone bound to NFTBid *without* going through Market (direct Clones),
    /// funds it, and tries to use the victim's approval to pull the victim's token for free.
    /// The handler always pulls from `caller` (the fill's msg.sender), so pulling the victim's
    /// token requires the attacker to be its owner. It is not, so the fill reverts.
    function test_rogueCloneCannotStealApprovedToken() public {
        uint256 id = 1;
        nft.mint(seller, id);
        vm.prank(seller);
        nft.setApprovalForAll(address(bids), true); // victim approves the shared handler

        // Attacker builds the Market-identical immutable args for a clone bound to NFTBid.
        bytes memory config = _bidConfig(nft, true, id, 1 ether, attacker, 1);
        bytes memory args = abi.encodePacked(
            attacker, address(bids), address(bids).codehash, keccak256(config)
        );
        vm.prank(attacker);
        address rogue = Clones.cloneDeterministicWithImmutableArgs(market.implementation(), args, bytes32(uint256(0xBAD)));
        vm.deal(rogue, 1 ether); // fund so the balance check passes

        // tokenId belongs to `seller`; attacker is the caller, so `from == attacker`.
        bytes memory input = abi.encode(id, uint256(0), attacker);
        vm.prank(attacker);
        vm.expectRevert(); // transferFrom(attacker, ...) fails: attacker is not the owner
        Order(payable(rogue)).fill(config, input);

        assertEq(nft.ownerOf(id), seller, "victim keeps the token");
    }

    /// Same handler, a genuine Market order, but the attacker names the victim's tokenId while
    /// being the caller. Still pulls from the attacker, so it reverts.
    function test_thirdPartyFillCannotPullVictimToken() public {
        uint256 id = 7;
        nft.mint(seller, id);
        vm.prank(seller);
        nft.setApprovalForAll(address(bids), true);

        bytes memory config = _bidConfig(nft, true, id, 1 ether, attacker, 1);
        Order order = _create(attacker, bids, config);
        vm.deal(address(order), 1 ether);

        bytes memory input = abi.encode(id, uint256(0), attacker);
        vm.prank(attacker);
        vm.expectRevert();
        order.fill(config, input);
        assertEq(nft.ownerOf(id), seller, "victim keeps the token");
    }

    /// Calling the handler's onFill directly (not inside a genuine fill) must revert, so no fake
    /// Bought event / result can be minted without real settlement.
    function test_directOnFillRevertsNotAFill() public {
        bytes memory config = _bidConfig(nft, true, 1, 1 ether, attacker, 1);
        bytes memory input = abi.encode(uint256(1), uint256(0), attacker);
        vm.prank(attacker);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        bids.onFill(seller, 0, config, input);
    }

    /// The owner of a *closed* order cannot make it call the handler to pull an approved token
    /// (filling() is false, so _requireFill rejects it).
    function test_closedOrderOwnerCannotUseHandlerApproval() public {
        uint256 id = 9;
        nft.mint(seller, id);
        vm.prank(seller);
        nft.setApprovalForAll(address(bids), true);

        bytes memory config = _bidConfig(nft, true, id, 1 ether, attacker, 1);
        Order order = _create(attacker, bids, config);
        vm.deal(address(order), 1 ether);

        vm.prank(attacker);
        order.close();

        // attacker (owner) drives the closed order to call onFill, spoofing caller=seller.
        bytes memory input = abi.encode(id, uint256(0), attacker);
        bytes memory onFillCall = abi.encodeCall(IOrderHandler.onFill, (seller, 0, config, input));
        vm.prank(attacker);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        order.execute(address(bids), 0, onFillCall);
        assertEq(nft.ownerOf(id), seller, "victim keeps the token");
    }

    // --- (d) lifecycle: active order owner has no execute -----------------

    function test_ownerCannotExecuteActiveOrder() public {
        (Order order,) = _listSale(seller, 1, 1 ether);
        // Owner tries to pull the escrowed NFT out without closing.
        vm.prank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        assertEq(nft.ownerOf(1), address(order), "token stays escrowed while active");
    }

    // --- (b) stated-limit enforcement ------------------------------------

    /// Buyer's maxPrice is honored: a sale priced above the buyer's cap reverts.
    function test_buyerMaxPriceEnforced() public {
        (Order order, bytes memory config) = _listSale(seller, 1, 2 ether);
        bytes memory input = abi.encode(buyer, 1 ether); // maxPrice below price
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.AboveMaxPrice.selector, 2 ether, 1 ether));
        order.fill{value: 2 ether}(config, input);
    }

    /// Seller's minProceeds is honored on a bid when a royalty eats into proceeds.
    function test_bidMinProceedsEnforcedAgainstRoyalty() public {
        RoyaltyNFT rnft = new RoyaltyNFT();
        uint256 id = 3;
        rnft.mint(seller, id);
        rnft.setRoyalty(royalty, 5000); // 50%
        vm.prank(seller);
        rnft.setApprovalForAll(address(bids), true);

        bytes memory config = abi.encode(
            NFTBid.Config(IERC721(address(rnft)), false, id, _fixed(1 ether), buyer, 1)
        );
        Order order = _create(buyer, bids, config);
        vm.deal(address(order), 1 ether);

        // proceeds would be 0.5 ETH; seller demands 0.9 -> revert.
        bytes memory input = abi.encode(id, uint256(0.9 ether), seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(NFTBid.BelowMinProceeds.selector, 0.5 ether, 0.9 ether));
        order.fill(config, input);
        assertEq(rnft.ownerOf(id), seller, "seller keeps token when underpaid");
    }

    /// Seller's maxRoyaltyBps is honored on a sale: a royalty above the cap reverts.
    function test_saleMaxRoyaltyBpsEnforced() public {
        RoyaltyNFT rnft = new RoyaltyNFT();
        uint256 id = 4;
        rnft.mint(seller, id);
        rnft.setRoyalty(royalty, 1000); // 10%

        NFTSale.Config memory c =
            NFTSale.Config(IERC721(address(rnft)), id, _fixed(1 ether), seller, 500); // cap 5%
        bytes memory config = abi.encode(c);
        Order order = _create(seller, sale, config);
        vm.prank(seller);
        rnft.transferFrom(seller, address(order), id);

        bytes memory input = abi.encode(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.RoyaltyAboveLimit.selector, 0.1 ether, 0.05 ether));
        order.fill{value: 1 ether}(config, input);
    }

    // --- (c) a genuine happy-path fill, for contrast ---------------------

    function test_honestSaleSettles() public {
        (Order order, bytes memory config) = _listSale(seller, 1, 1 ether);
        uint256 sellerBefore = seller.balance;
        bytes memory input = abi.encode(buyer, 1 ether);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, input);
        assertEq(nft.ownerOf(1), buyer, "buyer got token");
        assertEq(seller.balance, sellerBefore + 1 ether, "seller paid");
        assertTrue(order.closed(), "single-use order closed");
    }
}
