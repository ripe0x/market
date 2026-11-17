// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {Order} from "../src/Order.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

contract RightsGasTest is Base {
    RoyaltyNFT art;
    CoveredNFTPurchase purchase;

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500);
        purchase = new CoveredNFTPurchase(market);
    }

    function _config(uint256 id) internal view returns (bytes memory) {
        return abi.encode(CoveredNFTPurchase.Config(art, id, 1 ether, seller, 500));
    }

    function test_gasCreateActivateTransferSaleExercise() public {
        Rights rights = market.rights();
        art.mint(seller, 1);
        bytes memory config = _config(1);
        uint256 end = block.timestamp + 7 days;
        vm.prank(seller);
        Right right = market.createRight(purchase, config, end, seller, bytes32(uint256(1)));
        vm.snapshotGasLastCall("right: create pending");
        vm.prank(seller);
        art.transferFrom(seller, address(right), 1);
        vm.prank(seller);
        right.activate(config);
        vm.snapshotGasLastCall("right: activate covered NFT");
        uint256 id = right.tokenId();
        vm.prank(seller);
        rights.transferFrom(seller, buyer, id);
        vm.snapshotGasLastCall("right: transfer entitlement");

        NFTTrade.Schedule memory s =
            NFTTrade.Schedule(0.2 ether, 0.2 ether, block.timestamp, block.timestamp, end - 1 days);
        bytes memory saleConfig = abi.encode(NFTSale.Config(rights, id, s, buyer, 0));
        vm.prank(buyer);
        Order listing = market.create(sale, saleConfig, bytes32(uint256(2)));
        vm.prank(buyer);
        rights.transferFrom(buyer, address(listing), id);
        vm.prank(attacker);
        listing.fill{value: 0.2 ether}(saleConfig, abi.encode(attacker, 0.2 ether));
        vm.snapshotGasLastCall("right: sale premium");
        vm.prank(attacker);
        right.exercise{value: 1 ether}(config, abi.encode(attacker));
        vm.snapshotGasLastCall("right: exercise covered NFT");
    }

    function test_gasExpiryRecovery() public {
        art.mint(seller, 2);
        bytes memory config = _config(2);
        uint256 end = block.timestamp + 7 days;
        vm.prank(seller);
        Right right = market.createRight(purchase, config, end, seller, bytes32(uint256(3)));
        vm.prank(seller);
        art.transferFrom(seller, address(right), 2);
        vm.prank(seller);
        right.activate(config);
        vm.warp(end);
        right.finalizeExpiry();
        vm.snapshotGasLastCall("right: finalize expiry");
        vm.prank(seller);
        right.recover(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(right), seller, 2)));
        vm.snapshotGasLastCall("right: recover NFT");
    }
}
