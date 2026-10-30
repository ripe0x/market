// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Base.t.sol";

/// ERC721 whose transfer re-enters Market while Seaport is mid-execution.
contract ReentrantNft {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    Market public market;
    bytes public payload;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function arm(Market m, bytes calldata p) external {
        market = m;
        payload = p;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || isApprovedForAll[from][msg.sender]), "auth");
        ownerOf[id] = to;
        if (address(market) != address(0)) {
            (bool ok, bytes memory ret) = address(market).call(payload);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

contract AdversarialTest is Base {
    Vm.Wallet bidder = vm.createWallet("bidder");

    function setUp() public {
        loadFixture("item_offer");
        deployMarket();
    }

    function nftToBidder() internal view returns (ConsiderationItem[] memory c) {
        c = new ConsiderationItem[](1);
        c[0] = ConsiderationItem(ItemType.ERC721, nft, tokenId, 1, 1, payable(bidder.addr));
    }

    function twoWay() internal pure returns (Fulfillment[] memory f) {
        f = new Fulfillment[](2);
        f[0] = pair(0, 0, 1, 0);
        f[1] = pair(1, 0, 0, 0);
    }

    function test_syntheticMatchSplitsSurplus() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftToBidder());
        vm.prank(keeper);
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
        // 2 ether released: 0.6% executor, 0.4% protocol, rest seller.
        assertEq(WETH.balanceOf(keeper), 0.006 ether);
        assertEq(WETH.balanceOf(protocol), 0.004 ether);
        assertEq(WETH.balanceOf(seller.addr), 1.99 ether);
        assertEq(IERC721(nft).ownerOf(tokenId), bidder.addr);
        assertEq(WETH.balanceOf(address(market)), 0);
    }

    /// A self-made "bid" that takes no NFT would leave it unspent, which Seaport
    /// sends to the match recipient (Market). Market refuses to keep it.
    function test_revertWhenNftLeftInMarket() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, new ConsiderationItem[](0));
        Fulfillment[] memory f = new Fulfillment[](1);
        f[0] = pair(1, 0, 0, 0);
        vm.expectRevert(Market.NftNotDelivered.selector);
        market.matchOffer(l, b, new CriteriaResolver[](0), f);
        assertEq(IERC721(nft).ownerOf(tokenId), seller.addr);
    }

    /// Fulfillments that send the bid's WETH anywhere other than declared
    /// consideration items are rejected by Seaport; nothing can route to the caller.
    function test_revertWhenFulfillmentsIncomplete() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftToBidder());
        Fulfillment[] memory f = new Fulfillment[](1);
        f[0] = pair(0, 0, 1, 0); // seller consideration never met
        vm.expectRevert();
        market.matchOffer(l, b, new CriteriaResolver[](0), f);
    }

    function test_revertWhenOfferNotWeth() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftToBidder());
        b.parameters.offer[0].token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        vm.expectRevert(Market.NotWethOffer.selector);
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
    }

    function test_revertWhenOfferTooSmall() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 1 ether, nftToBidder()); // nothing left for fees
        vm.expectRevert();
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
    }

    /// Seller's own Seaport authority cannot be borrowed: an order whose offerer is
    /// Market needs no signature when Market calls Seaport, but Market owns nothing.
    function test_marketAsOffererHasNothingToGive() public {
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftToBidder());
        b.parameters.offerer = address(market);
        b.signature = "";
        vm.expectRevert();
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
    }

    function test_reentryDuringSettlementReverts() public {
        ReentrantNft bad = new ReentrantNft();
        nft = address(bad);
        tokenId = 1;
        bad.mint(seller.addr, 1);
        vm.prank(seller.addr);
        bad.setApprovalForAll(OS_CONDUIT, true);
        AdvancedOrder memory l = listing(1 ether, 1 ether, block.timestamp - 1, block.timestamp + 1 days, 1);
        AdvancedOrder memory b = syntheticBid(bidder, 2 ether, nftToBidder());
        bad.arm(market, abi.encodeCall(Market.buy, (l)));
        vm.expectRevert();
        market.matchOffer(l, b, new CriteriaResolver[](0), twoWay());
        assertEq(bad.ownerOf(1), seller.addr);
        assertEq(WETH.balanceOf(bidder.addr), 2 ether);
    }
}
