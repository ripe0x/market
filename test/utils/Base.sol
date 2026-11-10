// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../../src/Market.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {PaintAction} from "../../examples/PaintAction.sol";
import {TestNFT} from "./Mocks.sol";

abstract contract Base is Test {
    Market market;
    NFTSale sale;
    NFTBid bids;
    PaintAction paint;
    TestNFT nft;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");
    address royalty = makeAddr("royalty");

    uint256 salt;

    function setUp() public virtual {
        vm.warp(1_000_000);
        market = new Market();
        sale = new NFTSale(market);
        bids = new NFTBid(market);
        paint = new PaintAction();
        nft = new TestNFT();
        vm.deal(buyer, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    function _create(address owner, IOrderHandler handler, bytes memory config) internal returns (Order order) {
        vm.prank(owner);
        order = market.create(handler, config, bytes32(++salt));
    }

    function _fixed(uint256 price) internal view returns (NFTTrade.Schedule memory) {
        return NFTTrade.Schedule(price, price, block.timestamp, block.timestamp, 0);
    }

    /// Mints `id` of `nft` to `owner`, lists it at a fixed `price` paid to `owner` and deposits it.
    function _listSale(address owner, uint256 id, uint256 price) internal returns (Order order, bytes memory config) {
        nft.mint(owner, id);
        config = abi.encode(NFTSale.Config(nft, id, _fixed(price), owner, 0));
        order = _create(owner, sale, config);
        vm.prank(owner);
        nft.transferFrom(owner, address(order), id);
    }
}
