// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Market} from "../../src/Market.sol";
import {Order} from "../../src/Order.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";

/// Sales and bids of real mainnet ERC721s, on a fork pinned at `BLOCK`. Holders are
/// impersonated; every NFT contract, royalty setting and royalty receiver is the deployed one,
/// except where a test says it changes one to force a failure.
///
/// `forge test --match-path test/fork/NFTFork.t.sol --isolate` (writes snapshots/NFTFork.json).
/// RPC: `MAINNET_RPC_URL`, default https://mainnet.gateway.tenderly.co.
contract NFTForkTest is Test {
    uint256 constant BLOCK = 26_357_000;

    IERC721 constant BAYC = IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D); // OpenZeppelin ERC721, no ERC2981
    IERC721 constant AZUKI = IERC721(0xED5AF388653567Af2F388E6224dC7C4b3241C544); // ERC721A, no ERC2981
    IERC721 constant MOONBIRDS = IERC721(0x23581767a106ae21c074b2276D25e5C3e136a68b); // ERC2981 1%, nesting locks transfers
    IERC721 constant OPEPEN = IERC721(0x6339e5E072086621540D0362C4e3Cea0d643E114); // Manifold creator core, ERC2981 2.5%
    IERC721 constant CHIMPERS = IERC721(0x80336Ad7A747236ef41F47ed2C7641828a480BAA); // ERC2981 5.5%, contract receiver
    IERC721 constant ENS = IERC721(0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85); // ENS BaseRegistrar
    address constant PUNKS = 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB; // CryptoPunks, not ERC721

    Market market;
    NFTSale sale;
    NFTBid bids;
    address buyer = makeAddr("buyer");
    address bidder = makeAddr("bidder");
    address vault = makeAddr("vault");
    address proceeds = makeAddr("proceeds");
    uint256 salt;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), BLOCK);
        market = new Market();
        sale = new NFTSale();
        bids = new NFTBid(market);
        vm.deal(buyer, 1000 ether);
        vm.deal(bidder, 1000 ether);
    }

    function _royalty(IERC721 nft, uint256 id, uint256 price) internal view returns (address to, uint256 amount) {
        try IERC2981(address(nft)).supportsInterface(type(IERC2981).interfaceId) returns (bool yes) {
            if (yes) return IERC2981(address(nft)).royaltyInfo(id, price);
        } catch {}
    }

    function _schedule(uint256 startPrice, uint256 endPrice) internal view returns (NFTTrade.Schedule memory) {
        return NFTTrade.Schedule(startPrice, endPrice, block.timestamp, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function _list(IERC721 nft, uint256 id, uint16 maxRoyaltyBps) internal returns (Order order, bytes memory config) {
        address holder = nft.ownerOf(id);
        config = abi.encode(NFTSale.Config(nft, id, _schedule(10 ether, 1 ether), proceeds, maxRoyaltyBps));
        vm.prank(holder);
        order = market.create(sale, config, bytes32(++salt));
        vm.prank(holder);
        nft.transferFrom(holder, address(order), id);
        assertEq(nft.ownerOf(id), address(order), "escrowed");
    }

    /// A falling-price sale filled halfway down by an EOA buyer, checked to the wei.
    function _saleRoundTrip(IERC721 nft, uint256 id, string memory label) internal {
        (Order order, bytes memory config) = _list(nft, id, 1000);
        skip(12 hours);
        uint256 price = 5.5 ether;
        (address royaltyTo, uint256 royalty) = _royalty(nft, id, price);
        uint256 buyerBefore = buyer.balance;
        // Receivers may forward what they get (Chimpers' is a splitter), so check the payment
        // itself rather than the receiver's balance.
        if (royalty != 0) vm.expectCall(royaltyTo, royalty, "");

        vm.prank(buyer);
        order.fill{value: 6 ether}(config, abi.encode(buyer, price));
        vm.snapshotGasLastCall("NFTFork", string.concat("sale fill: ", label));

        assertEq(nft.ownerOf(id), buyer, "delivered");
        assertEq(buyerBefore - buyer.balance, price, "buyer pays the price");
        assertEq(proceeds.balance, price - royalty, "seller proceeds");
        assertEq(address(order).balance, 0);
        assertTrue(order.closed());
    }

    /// A collection bid sold into by the token's real holder.
    function _bidRoundTrip(IERC721 nft, uint256 id, string memory label) internal {
        address holder = nft.ownerOf(id);
        bytes memory config = abi.encode(NFTBid.Config(nft, true, 0, _schedule(1 ether, 3 ether), vault, 2));
        vm.prank(bidder);
        Order order = market.create{value: 6 ether}(bids, config, bytes32(++salt));
        skip(12 hours);
        uint256 price = 2 ether;
        (address royaltyTo, uint256 royalty) = _royalty(nft, id, price);
        uint256 holderBefore = holder.balance;

        vm.prank(holder);
        nft.setApprovalForAll(address(bids), true);
        if (royalty != 0) vm.expectCall(royaltyTo, royalty, "");
        vm.prank(holder);
        order.fill(config, abi.encode(id, price - royalty, holder));
        vm.snapshotGasLastCall("NFTFork", string.concat("bid fill: ", label));

        assertEq(nft.ownerOf(id), vault, "delivered");
        assertEq(holder.balance - holderBefore, price - royalty, "seller proceeds");
        assertEq(address(order).balance, 4 ether, "bid keeps the rest");
        assertFalse(order.closed(), "one of two fills used");
    }

    function test_BAYC() public {
        _saleRoundTrip(BAYC, 1, "BAYC, no royalty");
        _bidRoundTrip(BAYC, 2, "BAYC, no royalty");
    }

    function test_Azuki() public {
        _saleRoundTrip(AZUKI, 1, "Azuki (ERC721A), no royalty");
        _bidRoundTrip(AZUKI, 2, "Azuki (ERC721A), no royalty");
    }

    function test_Opepen() public {
        (, uint256 r) = _royalty(OPEPEN, 1, 1 ether);
        assertEq(r, 0.025 ether, "2.5% at this block");
        _saleRoundTrip(OPEPEN, 1, "Opepen, 2.5% to EOA");
    }

    /// Opepen #1's holder is an EIP-7702 delegated account: a real smart-account seller.
    function test_OpepenBid() public {
        assertEq(bytes3(OPEPEN.ownerOf(1).code), bytes3(0xef0100));
        _bidRoundTrip(OPEPEN, 1, "Opepen, 2.5% to EOA");
    }

    function test_Chimpers() public {
        (address to, uint256 r) = _royalty(CHIMPERS, 3000, 1 ether);
        assertEq(r, 0.055 ether, "5.5% at this block");
        assertGt(to.code.length, 0, "receiver is a contract");
        _saleRoundTrip(CHIMPERS, 3000, "Chimpers, 5.5% to contract");
    }

    function test_ChimpersBid() public {
        _bidRoundTrip(CHIMPERS, 3000, "Chimpers, 5.5% to contract");
    }

    /// Moonbirds #1 is held by a contract, which deposits it like any holder.
    function test_Moonbirds() public {
        _saleRoundTrip(MOONBIRDS, 1, "Moonbirds, 1% to EOA");
    }

    /// The seller allowed at most 5% royalty; Chimpers asks 5.5%. The sale refuses to fill.
    function test_royaltyAboveSellerLimitReverts() public {
        (Order order, bytes memory config) = _list(CHIMPERS, 3000, 500);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NFTSale.RoyaltyAboveLimit.selector, 0.55 ether, 0.5 ether));
        order.fill{value: 10 ether}(config, abi.encode(buyer, 10 ether));
        assertEq(CHIMPERS.ownerOf(3000), address(order), "still escrowed");
    }

    /// Changed state: Opepen's royalty receiver is given code that rejects ETH. The fill must
    /// revert rather than pay the seller the royalty.
    function test_royaltyReceiverFailureReverts() public {
        (Order order, bytes memory config) = _list(OPEPEN, 1, 1000);
        (address to,) = _royalty(OPEPEN, 1, 1 ether);
        vm.etch(to, hex"5f5ffd"); // PUSH0 PUSH0 REVERT
        vm.prank(buyer);
        vm.expectRevert();
        order.fill{value: 10 ether}(config, abi.encode(buyer, 10 ether));
        assertEq(OPEPEN.ownerOf(1), address(order));
    }

    /// A nested Moonbird cannot be transferred, so it can be neither listed nor sold into a
    /// bid; the bid's funds are untouched.
    function test_nestedMoonbirdIsIncompatible() public {
        (bool nested,,) = IMoonbirds(address(MOONBIRDS)).nestingPeriod(7);
        assertTrue(nested);
        address holder = MOONBIRDS.ownerOf(7);
        bytes memory config = abi.encode(NFTBid.Config(MOONBIRDS, true, 0, _schedule(1 ether, 1 ether), vault, 1));
        vm.prank(bidder);
        Order order = market.create{value: 1 ether}(bids, config, bytes32(++salt));
        vm.prank(holder);
        MOONBIRDS.setApprovalForAll(address(bids), true);
        vm.prank(holder);
        vm.expectRevert();
        order.fill(config, abi.encode(7, 0, holder));
        assertEq(MOONBIRDS.ownerOf(7), holder);
        assertEq(address(order).balance, 1 ether);
    }

    /// ENS .eth names are ERC721s of the base registrar. The sale moves the registration; the
    /// buyer must then `reclaim` to control the name's records, as after any ENS transfer.
    function test_ENSName() public {
        uint256 id = uint256(keccak256("vitalik"));
        address holder = ENS.ownerOf(id);
        bytes memory config =
            abi.encode(NFTSale.Config(ENS, id, _schedule(1 ether, 1 ether), proceeds, 0));
        vm.prank(holder);
        Order order = market.create(sale, config, bytes32(++salt));
        vm.prank(holder);
        ENS.transferFrom(holder, address(order), id);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        assertEq(ENS.ownerOf(id), buyer);
        assertEq(proceeds.balance, 1 ether);
    }

    /// CryptoPunks predate ERC721: no `ownerOf` or `transferFrom`. Bids for them revert and
    /// keep their funds; use a wrapper collection instead.
    function test_cryptoPunksAreIncompatible() public {
        bytes memory config =
            abi.encode(NFTBid.Config(IERC721(PUNKS), false, 1, _schedule(1 ether, 1 ether), vault, 1));
        vm.prank(bidder);
        Order order = market.create{value: 1 ether}(bids, config, bytes32(++salt));
        address holder = IPunks(PUNKS).punkIndexToAddress(1);
        vm.prank(holder);
        vm.expectRevert();
        order.fill(config, abi.encode(1, 0, holder));
        assertEq(IPunks(PUNKS).punkIndexToAddress(1), holder);
        assertEq(address(order).balance, 1 ether);
    }

    function test_depositGas() public {
        address holder = BAYC.ownerOf(1);
        bytes memory config = abi.encode(NFTSale.Config(BAYC, 1, _schedule(10 ether, 1 ether), proceeds, 1000));
        vm.prank(holder);
        Order listing = market.create(sale, config, bytes32(++salt));
        vm.prank(holder);
        BAYC.transferFrom(holder, address(listing), 1);
        vm.snapshotGasLastCall("NFTFork", "deposit: BAYC into sale");
    }

    /// Cancel a real listing and a funded bid; everything returns to its owner.
    function test_cancelAndRecover() public {
        address holder = AZUKI.ownerOf(1);
        bytes memory saleConfig = abi.encode(NFTSale.Config(AZUKI, 1, _schedule(10 ether, 1 ether), proceeds, 1000));
        vm.prank(holder);
        Order listing = market.create(sale, saleConfig, bytes32(++salt));
        vm.snapshotGasLastCall("NFTFork", "create: sale");
        vm.prank(holder);
        AZUKI.transferFrom(holder, address(listing), 1);
        vm.snapshotGasLastCall("NFTFork", "deposit: Azuki into sale");
        vm.startPrank(holder);
        listing.close();
        vm.snapshotGasLastCall("NFTFork", "close: sale");
        listing.execute(address(AZUKI), 0, abi.encodeCall(IERC721.transferFrom, (address(listing), holder, 1)));
        vm.snapshotGasLastCall("NFTFork", "recover: NFT from closed sale");
        vm.stopPrank();
        assertEq(AZUKI.ownerOf(1), holder);

        bytes memory config = abi.encode(NFTBid.Config(AZUKI, true, 0, _schedule(1 ether, 1 ether), vault, 1));
        vm.prank(bidder);
        Order bid = market.create{value: 2 ether}(bids, config, bytes32(++salt));
        vm.snapshotGasLastCall("NFTFork", "create: funded bid");
        uint256 before = bidder.balance;
        vm.startPrank(bidder);
        bid.close();
        bid.execute(bidder, 2 ether, "");
        vm.snapshotGasLastCall("NFTFork", "recover: ETH from closed bid");
        vm.stopPrank();
        assertEq(bidder.balance - before, 2 ether);
    }
}

interface IMoonbirds {
    function nestingPeriod(uint256 tokenId) external view returns (bool nesting, uint256 current, uint256 total);
}

interface IPunks {
    function punkIndexToAddress(uint256 index) external view returns (address);
}
