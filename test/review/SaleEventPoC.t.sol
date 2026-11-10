// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {Base} from "../utils/Base.sol";
import {RoyaltyNFT} from "../utils/Mocks.sol";

/// Shaped like an order: `execute` forwards token calls and silently drops ETH payments and
/// `close`.
contract CounterfeitSaleOrder {
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        if (value != 0 || data.length == 0 || bytes4(data) == Order.close.selector) return "";
        (, ret) = target.call(data);
    }

    function run(NFTSale handler, bytes calldata config, bytes calldata input) external {
        handler.onFill(msg.sender, 1000 ether, config, input);
    }
}

/// Finding S1 (fixed). Before `NFTTrade._requireFill`, NFTSale trusted `msg.sender` to be an
/// order in its fill. A counterfeit order made the real handler emit `Sold` for a real token at
/// 1,000 ETH with a 50 ETH royalty while no ETH moved and no royalty was paid: no asset loss,
/// but a false sale record for anyone reading the handler's events (wash prices, royalty
/// accounting). Before the fix both tests below emitted `Sold`.
contract SaleEventPoC is Base {
    RoyaltyNFT art;
    address alt = makeAddr("alt");

    function setUp() public override {
        super.setUp();
        art = new RoyaltyNFT();
        art.setRoyalty(royalty, 500);
    }

    function _config() internal view returns (bytes memory) {
        return abi.encode(NFTSale.Config(art, 1, _fixed(1000 ether), attacker, 10_000));
    }

    function test_counterfeitOrderCannotAnnounceASale() public {
        CounterfeitSaleOrder fake = new CounterfeitSaleOrder();
        art.mint(address(fake), 1);
        vm.prank(attacker);
        vm.expectRevert(NFTTrade.NotAFill.selector);
        fake.run(sale, _config(), abi.encode(alt, 1000 ether));
        assertEq(art.ownerOf(1), address(fake));
    }

    /// A genuine order, closed by its owner, calling the handler outside a fill.
    function test_closedOrderCannotAnnounceASale() public {
        bytes memory config = _config();
        Order order = _create(attacker, sale, config);
        art.mint(address(order), 1);
        vm.startPrank(attacker);
        order.close();
        vm.expectRevert(NFTTrade.NotAFill.selector);
        order.execute(
            address(sale), 0, abi.encodeCall(IOrderHandler.onFill, (attacker, 1000 ether, config, abi.encode(alt, 0)))
        );
        vm.stopPrank();
        assertEq(art.ownerOf(1), address(order));
    }
}
