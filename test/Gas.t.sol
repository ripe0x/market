// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {Artwork} from "../examples/Artwork.sol";
import {CapitalPool} from "../examples/CapitalPool.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {Base} from "./utils/Base.sol";
import {TestToken} from "./utils/Mocks.sol";

/// Records gas for creation and common fills in `snapshots/GasTest.json`.
/// Run with `forge test --match-path test/Gas.t.sol --isolate` so each call starts cold.
contract GasTest is Base {
    function test_gasDutchAuction() public {
        nft.mint(seller, 1);
        bytes memory config = abi.encode(_dutchConfig(1, seller));
        vm.prank(seller);
        Order order = market.create(dutch, config, 0);
        vm.snapshotGasLastCall("create: DutchAuction order");
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);
        skip(300);
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        vm.snapshotGasLastCall("fill: DutchAuction, 1 payee, refund");
    }

    function test_gasDutchAuctionTwoPayees() public {
        nft.mint(seller, 1);
        DutchAuction.Config memory c = _dutchConfig(1, seller);
        c.payees = _payees(royalty, 500, seller);
        bytes memory config = abi.encode(c);
        Order order = _create(seller, dutch, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 1);
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        vm.snapshotGasLastCall("fill: DutchAuction, 2 payees, exact");
    }

    function test_gasRecover() public {
        (Order order,) = _listDutch(seller, 1);
        vm.prank(seller);
        order.close();
        vm.snapshotGasLastCall("close");
        vm.prank(seller);
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        vm.snapshotGasLastCall("execute: owner withdraws NFT");
    }

    function test_gasTokenExchange() public {
        TestToken give = new TestToken("G");
        TestToken take = new TestToken("T");
        bytes memory config =
            abi.encode(TokenExchange.Config(give, take, 1, 2, royalty, block.timestamp + 1 days));
        vm.prank(seller);
        Order order = market.create(exchange, config, 0);
        vm.snapshotGasLastCall("create: TokenExchange order");
        give.mint(address(order), 100e18);
        take.mint(buyer, 1000e18);
        vm.prank(buyer);
        take.approve(address(order), type(uint256).max);
        vm.prank(buyer);
        order.fill(config, abi.encode(10e18, buyer));
        vm.snapshotGasLastCall("fill: TokenExchange, first partial");
        vm.prank(buyer);
        order.fill(config, abi.encode(10e18, buyer));
        vm.snapshotGasLastCall("fill: TokenExchange, repeat partial");
    }

    function test_gasPaintAction() public {
        Artwork art = new Artwork();
        art.mint(seller, 1);
        bytes memory config = abi.encode(PaintAction.Config(art, 1, type(uint256).max, 0.1 ether, _payees(seller)));
        Order order = _create(seller, paint, config);
        vm.prank(seller);
        art.setPainter(1, address(order));
        vm.prank(buyer);
        order.fill{value: 0.1 ether}(config, abi.encode(uint8(5)));
        vm.snapshotGasLastCall("fill: PaintAction, paint + resign + close");
    }

    function test_gasAcquisitionBid() public {
        CapitalPool pool = new CapitalPool(address(this));
        vm.deal(address(pool), 10 ether);
        bytes memory config =
            _bidConfig(royalty, 5 ether, rising, _risingParams(1 ether, 0.001 ether, 5000), address(pool));
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        Order bid = market.create{value: 1 ether}(acquisition, config, 0);
        vm.snapshotGasLastCall("create: AcquisitionBid order, funded");
        pool.setGrant(address(bid), 0.01 ether, 5 ether);
        nft.mint(buyer, 1);
        nft.mint(buyer, 2);
        vm.prank(buyer);
        nft.setApprovalForAll(address(bid), true);
        skip(100);
        vm.prank(buyer);
        bid.fill(config, abi.encode(1, 1 ether));
        vm.snapshotGasLastCall("fill: AcquisitionBid, order funds only");
        skip(1000);
        vm.prank(buyer);
        bid.fill(config, abi.encode(2, 1.2 ether));
        vm.snapshotGasLastCall("fill: AcquisitionBid, draws from pool");
    }
}
