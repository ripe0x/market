// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {HandlerBase} from "../handlers/HandlerBase.sol";
import {Artwork} from "../examples/Artwork.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {RoyaltyNFT} from "../test/utils/Mocks.sol";
import {Addresses} from "./Deploy.s.sol";

/// @notice Exercises the deployed protocol end to end with real transactions from one account,
/// which plays every role: seller, buyer, bidder, holder and artist. Run after
/// `script/Deploy.s.sol` on the same chain. Spends about 0.012 ETH plus gas; 0.0006 ETH of it
/// goes to the fixed royalty and vault addresses below, which nobody controls.
///
///   forge script script/Lifecycle.s.sol --rpc-url <rpc> --broadcast <signer>
///   forge script script/Lifecycle.s.sol --sig "recover(address)" <bid order> --rpc-url <rpc> --broadcast <signer>
///
/// The second command cancels the bid and withdraws what it still holds. It is separate because
/// a script computes every amount when it simulates, and the bid's rising price makes its
/// remaining balance depend on the block each fill lands in.
///
/// Covers: order creation, ETH funding and top-up, a fixed-price sale with royalty, a falling
/// sale cancelled and recovered, a persistent rising collection bid filled twice, topped up, then
/// cancelled with its remaining ETH recovered, handler reuse across all of them, and the non-NFT
/// PaintAction example using a painter role granted by an independent Artwork contract.
contract Lifecycle is Addresses {
    address constant ROYALTY = address(uint160(uint256(keccak256("market.lifecycle.royalty"))));
    address constant VAULT = address(uint160(uint256(keccak256("market.lifecycle.vault"))));

    address me;
    uint256 salt;
    RoyaltyNFT nft;

    function run() external {
        require(address(market()).code.length != 0, "run script/Deploy.s.sol first");
        me = msg.sender;
        salt = uint256(keccak256(abi.encode(block.chainid, block.timestamp, me)));
        vm.startBroadcast();

        nft = new RoyaltyNFT();
        nft.setRoyalty(ROYALTY, 500);
        for (uint256 id = 1; id <= 4; ++id) {
            nft.mint(me, id);
        }
        console.log("Test collection (ERC2981 5%)", address(nft));

        fixedSale();
        cancelledSale();
        persistentBid();
        paint();

        vm.stopBroadcast();
    }

    function _schedule(uint256 startPrice, uint256 endPrice, uint256 duration)
        internal
        view
        returns (NFTTrade.Schedule memory)
    {
        return NFTTrade.Schedule(startPrice, endPrice, block.timestamp, block.timestamp + duration, block.timestamp + 30 days);
    }

    function fixedSale() internal {
        bytes memory config = abi.encode(NFTSale.Config(nft, 1, _schedule(0.002 ether, 0.002 ether, 0), me, 1000));
        Order order = market().create(nftSale(), config, bytes32(++salt));
        nft.transferFrom(me, address(order), 1);
        order.fill{value: 0.002 ether}(config, abi.encode(me, 0.002 ether));
        require(nft.ownerOf(1) == me && order.closed(), "fixed sale");
        console.log("Fixed sale filled and closed", address(order));
    }

    function cancelledSale() internal {
        bytes memory config = abi.encode(NFTSale.Config(nft, 2, _schedule(0.01 ether, 0.001 ether, 1 days), me, 1000));
        Order order = market().create(nftSale(), config, bytes32(++salt));
        nft.transferFrom(me, address(order), 2);
        order.close();
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), me, 2)));
        require(nft.ownerOf(2) == me, "recovered");
        console.log("Falling sale cancelled, NFT recovered", address(order));
    }

    function persistentBid() internal {
        bytes memory config = abi.encode(
            NFTBid.Config(nft, true, 0, _schedule(0.002 ether, 0.004 ether, 1 days), VAULT, 3)
        );
        Order order = market().create{value: 0.004 ether}(nftBid(), config, bytes32(++salt));
        nft.setApprovalForAll(address(nftBid()), true);
        order.fill(config, abi.encode(3, 0, me));
        (bool ok,) = address(order).call{value: 0.003 ether}(""); // top-up
        require(ok, "top-up");
        order.fill(config, abi.encode(4, 0, me));
        nft.setApprovalForAll(address(nftBid()), false);
        require(nft.ownerOf(3) == VAULT && nft.ownerOf(4) == VAULT, "bought");
        console.log("Persistent bid filled twice, topped up; recover with", address(order));
    }

    /// Cancels a bid and withdraws its remaining ETH, read at simulation time from the chain.
    function recover(Order order) external {
        vm.startBroadcast();
        order.close();
        order.execute(msg.sender, address(order).balance, "");
        vm.stopBroadcast();
        require(address(order).balance == 0, "recovered");
        console.log("Bid cancelled, ETH recovered", address(order));
    }

    function paint() internal {
        Artwork art = new Artwork();
        art.mint(me, 1);
        HandlerBase.Payee[] memory payees = new HandlerBase.Payee[](1);
        payees[0] = HandlerBase.Payee(me, 10_000);
        bytes memory config = abi.encode(PaintAction.Config(art, 1, 0x0e, 0.001 ether, payees)); // colors 1 to 3
        Order order = market().create(paintAction(), config, bytes32(++salt));
        art.setPainter(1, address(order));
        order.fill{value: 0.001 ether}(config, abi.encode(uint8(2)));
        require(art.colorOf(1) == 2 && art.painterOf(1) == address(0) && order.closed(), "painted");
        console.log("Artwork", address(art));
        console.log("PaintAction order painted, resigned and closed", address(order));
    }
}
