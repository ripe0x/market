// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {Order} from "../src/Order.sol";
import {AcquisitionBid} from "../examples/AcquisitionBid.sol";
import {Artwork} from "../examples/Artwork.sol";
import {RisingStrategy} from "../examples/BidStrategies.sol";
import {CapitalPool} from "../examples/CapitalPool.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {HandlerBase} from "../examples/HandlerBase.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {TestNFT, TestToken} from "../test/utils/Mocks.sol";

/// @notice Runs all four examples against one Market on a local anvil node, each step sent by
/// the account that would send it in practice. Use `script/demo.sh`, which starts anvil and
/// sends from anvil's unlocked default accounts; no private keys are involved.
contract Demo is Script {
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant SELLER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant BUYER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant ARTIST = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant FUNDER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant ROYALTY = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    Market market;
    TestNFT nft;

    function run() external {
        require(block.chainid == 31337, "local anvil only");
        vm.startBroadcast(DEPLOYER);
        market = new Market();
        nft = new TestNFT();
        vm.stopBroadcast();
        console.log("Market", address(market));

        nftSale();
        tokenExchange();
        artworkAction();
        acquisitionBid();
    }

    function _payees(address a, uint16 aBps, address b) internal pure returns (HandlerBase.Payee[] memory p) {
        p = new HandlerBase.Payee[](2);
        p[0] = HandlerBase.Payee(a, aBps);
        p[1] = HandlerBase.Payee(b, 10_000 - aBps);
    }

    function nftSale() internal {
        console.log("\n1. NFT sale, price falling from 1 ETH to 0.1 ETH over an hour");
        vm.startBroadcast(DEPLOYER);
        DutchAuction dutch = new DutchAuction();
        nft.mint(SELLER, 1);
        vm.stopBroadcast();

        DutchAuction.Config memory c = DutchAuction.Config(
            nft, 1, 1 ether, 0.1 ether, block.timestamp, block.timestamp + 1 hours, _payees(ROYALTY, 500, SELLER)
        );
        bytes memory config = abi.encode(c);
        vm.startBroadcast(SELLER);
        Order order = market.create(dutch, config, 0);
        nft.transferFrom(SELLER, address(order), 1);
        vm.stopBroadcast();
        console.log("  order", address(order));
        console.log("  price now / +30m / +1h", dutch.price(c, block.timestamp), dutch.price(c, block.timestamp + 30 minutes), dutch.price(c, block.timestamp + 1 hours));

        vm.broadcast(BUYER);
        order.fill{value: 1 ether}(config, abi.encode(BUYER));
        require(nft.ownerOf(1) == BUYER && order.closed(), "sale");
        console.log("  sold to buyer; order closed");
    }

    function tokenExchange() internal {
        console.log("\n2. ERC20 exchange, 2 TAKE per GIVE, partial fills");
        vm.startBroadcast(DEPLOYER);
        TokenExchange exchange = new TokenExchange();
        TestToken give = new TestToken("GIVE");
        TestToken take = new TestToken("TAKE");
        vm.stopBroadcast();

        bytes memory config =
            abi.encode(TokenExchange.Config(give, take, 1, 2, SELLER, block.timestamp + 1 days));
        vm.startBroadcast(SELLER);
        Order order = market.create(exchange, config, 0);
        give.mint(address(order), 100e18);
        vm.stopBroadcast();

        vm.startBroadcast(BUYER);
        take.mint(BUYER, 200e18);
        take.approve(address(order), 200e18);
        order.fill(config, abi.encode(40e18, BUYER));
        order.fill(config, abi.encode(20e18, BUYER));
        vm.stopBroadcast();
        require(give.balanceOf(BUYER) == 60e18 && take.balanceOf(SELLER) == 120e18, "exchange");
        console.log("  two fills: buyer got 60 GIVE, seller got 120 TAKE");

        // The seller may add inventory while the order is active, but takes it out only by
        // closing the order first.
        vm.startBroadcast(SELLER);
        give.mint(SELLER, 10e18);
        give.transfer(address(order), 10e18);
        order.close();
        order.execute(address(give), 0, abi.encodeCall(give.transfer, (SELLER, 50e18)));
        vm.stopBroadcast();
        require(order.closed() && give.balanceOf(SELLER) == 50e18, "recover");
        console.log("  topped up 10 GIVE, then closed and recovered the unsold 50 GIVE");
    }

    function artworkAction() internal {
        console.log("\n3. Artwork action: buy one repaint for 0.05 ETH");
        vm.broadcast(DEPLOYER);
        PaintAction paint = new PaintAction();
        vm.startBroadcast(ARTIST);
        Artwork art = new Artwork();
        art.mint(ARTIST, 1);
        bytes memory config = abi.encode(
            PaintAction.Config(art, 1, (1 << 1) | (1 << 2) | (1 << 3), 0.05 ether, _payees(ROYALTY, 1000, ARTIST))
        );
        Order order = market.create(paint, config, 0);
        art.setPainter(1, address(order)); // the artwork's own rule: lend the painter role
        vm.stopBroadcast();

        vm.broadcast(BUYER);
        order.fill{value: 0.05 ether}(config, abi.encode(uint8(2)));
        require(art.colorOf(1) == 2 && art.painterOf(1) == address(0) && order.closed(), "paint");
        console.log("  painted color 2; painter role returned; order closed");
    }

    function acquisitionBid() internal {
        console.log("\n4. Persistent rising bid funded by an external pool");
        vm.startBroadcast(DEPLOYER);
        AcquisitionBid acquisition = new AcquisitionBid();
        RisingStrategy rising = new RisingStrategy();
        nft.mint(BUYER, 10);
        nft.mint(BUYER, 11);
        vm.stopBroadcast();

        vm.startBroadcast(FUNDER);
        CapitalPool pool = new CapitalPool{value: 3 ether}(FUNDER);
        bytes memory config = abi.encode(
            AcquisitionBid.Config(
                nft,
                FUNDER,
                2 ether,
                rising,
                abi.encode(RisingStrategy.Params(0.2 ether, block.timestamp, 0.0001 ether, 5000)),
                pool
            )
        );
        Order bid = market.create{value: 0.1 ether}(acquisition, config, 0);
        pool.setGrant(address(bid), 0.001 ether, 1 ether);
        vm.stopBroadcast();
        AcquisitionBid.Config memory c = abi.decode(config, (AcquisitionBid.Config));
        console.log("  bid", address(bid));
        console.log("  current bid", acquisition.currentBid(address(bid), c));
        console.log("  (the pool grant starts at 0 and accrues 0.001 ETH/s; draws are exercised in test/AcquisitionBid.t.sol)");

        uint256 price = acquisition.currentBid(address(bid), c);
        vm.startBroadcast(BUYER);
        nft.setApprovalForAll(address(bid), true);
        bid.fill(config, abi.encode(10, price));
        vm.stopBroadcast();
        (uint128 last,, uint64 count) = acquisition.state(address(bid));
        console.log("  acquired #10 at", uint256(last), "count", uint256(count));

        // New capital arrives in the order itself; the same order keeps bidding.
        vm.broadcast(FUNDER);
        (bool ok,) = address(bid).call{value: 0.5 ether}("");
        require(ok);
        price = acquisition.currentBid(address(bid), c);
        console.log("  after top-up, current bid", price);
        vm.broadcast(BUYER);
        bid.fill(config, abi.encode(11, price));
        (, , count) = acquisition.state(address(bid));
        require(nft.ownerOf(10) == FUNDER && nft.ownerOf(11) == FUNDER && count == 2, "bid");
        console.log("  acquired #11; bid stays open:", !bid.closed());
    }
}
