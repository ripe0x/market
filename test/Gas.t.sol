// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Artwork} from "../examples/Artwork.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// Records gas for creation and common fills in `snapshots/GasTest.json`.
/// Run with `forge test --match-path test/Gas.t.sol --isolate` so each call starts cold.
contract GasTest is Base {
    RoyaltyNFT art;

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500);
    }

    function test_gasNFTSale() public {
        art.mint(seller, 1);
        NFTTrade.Schedule memory s = NFTTrade.Schedule(10 ether, 1 ether, block.timestamp, block.timestamp + 1000, 0);
        bytes memory config = abi.encode(NFTSale.Config(art, 1, s, seller, 1000));
        vm.prank(seller);
        Order order = market.create(sale, config, 0);
        vm.snapshotGasLastCall("create: NFTSale order");
        vm.prank(seller);
        art.transferFrom(seller, address(order), 1);
        skip(300);
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer, 10 ether));
        vm.snapshotGasLastCall("fill: NFTSale, falling price, royalty, refund");
    }

    function test_gasNFTSaleNoRoyalty() public {
        (Order order, bytes memory config) = _listSale(seller, 1, 1 ether);
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer, 1 ether));
        vm.snapshotGasLastCall("fill: NFTSale, fixed price, no royalty, exact");
    }

    function test_gasNFTBid() public {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(1 ether, 2 ether, block.timestamp, block.timestamp + 1000, 0);
        bytes memory config = abi.encode(NFTBid.Config(art, true, 0, s, royalty, 2));
        vm.deal(seller, 4 ether);
        vm.prank(seller);
        Order bid = market.create{value: 4 ether}(bids, config, 0);
        vm.snapshotGasLastCall("create: NFTBid order, funded");
        art.mint(buyer, 1);
        art.mint(buyer, 2);
        vm.prank(buyer);
        art.setApprovalForAll(address(bids), true);
        skip(100);
        vm.prank(buyer);
        bid.fill(config, abi.encode(1, 0, buyer));
        vm.snapshotGasLastCall("fill: NFTBid, rising collection bid, royalty");
        vm.prank(buyer);
        bid.fill(config, abi.encode(2, 0, buyer));
        vm.snapshotGasLastCall("fill: NFTBid, last fill closes");
    }

    function test_gasRecover() public {
        (Order order,) = _listSale(seller, 1, 1 ether);
        vm.prank(seller);
        order.close();
        vm.snapshotGasLastCall("close");
        vm.prank(seller);
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.snapshotGasLastCall("execute: owner withdraws NFT");
    }

    function test_gasPaintAction() public {
        Artwork artwork = new Artwork();
        artwork.mint(seller, 1);
        bytes memory config = abi.encode(PaintAction.Config(artwork, 1, type(uint256).max, 0.1 ether, seller));
        Order order = _create(seller, paint, config);
        vm.prank(seller);
        artwork.setPainter(1, address(order));
        vm.prank(buyer);
        order.fill{value: 0.1 ether}(config, abi.encode(uint8(5)));
        vm.snapshotGasLastCall("fill: PaintAction, paint + resign + close");
    }
}
