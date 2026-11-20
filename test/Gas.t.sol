// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {Admission, Order, OrderSpec} from "../src/Order.sol";

/// Deterministic gas snapshots for the main Order/ExchangeAction/CoveredNFTPurchase operations.
/// Run with `--isolate` to refresh snapshots/GasTest.json.
contract GasTest is Base {
    function test_gas_lifecycle() public {
        // ---- sale: create + activate (NFT pre-positioned at the predicted address) ----
        uint256 price = 1 ether;
        bytes32 sSalt = keccak256("gas-sale");
        OrderSpec memory saleSpec =
            _spec(address(exchange), Admission.Public, 0, seller, _saleConfig(address(nft), 1, _fixed(price), seller, 10_000));
        address salePred = market.orderAddress(seller, saleSpec, sSalt);
        nft.mint(salePred, 1);
        vm.prank(seller);
        Order sale = market.createAndActivate(saleSpec, sSalt);
        vm.snapshotGasLastCall("create+activate sale");

        // ---- sale: execute ----
        vm.prank(buyer);
        sale.execute{value: price}(abi.encode(buyer, price, uint64(0)));
        vm.snapshotGasLastCall("sale execute");

        // ---- bid: create (funded, pending) ----
        bytes32 bSalt = keccak256("gas-bid");
        OrderSpec memory bidSpec =
            _spec(address(exchange), Admission.Public, 0, bidder, _bidConfig(address(nft), true, 0, _fixed(2 ether), bidder, 1, 0));
        vm.prank(bidder);
        Order bid = market.create{value: 2 ether}(bidSpec, bSalt);
        vm.snapshotGasLastCall("bid create");
        _activate(bid);

        // ---- bid: execute ----
        nft.mint(seller, 2);
        vm.startPrank(seller);
        nft.approve(address(exchange), 2);
        bid.execute(abi.encode(uint256(2), uint256(0), seller));
        vm.snapshotGasLastCall("bid execute");
        vm.stopPrank();

        // ---- covered: issue (create + escrow + activate; the activate is the measured issuance) ----
        nft.mint(issuer, 3);
        bytes32 cSalt = keccak256("gas-covered");
        OrderSpec memory covSpec = _spec(
            address(covered), Admission.Holder, uint64(T0 + 10 days), issuer, _coveredConfig(address(nft), 3, 3 ether, issuer, 10_000)
        );
        vm.prank(issuer);
        Order cov = market.create(covSpec, cSalt);
        vm.prank(issuer);
        nft.transferFrom(issuer, address(cov), 3);
        vm.prank(issuer);
        cov.activate();
        vm.snapshotGasLastCall("covered issue");

        // ---- covered: execute ----
        vm.prank(issuer);
        cov.execute{value: 3 ether}(abi.encode(issuer));
        vm.snapshotGasLastCall("covered execute");

        // ---- credit withdrawal ----
        cov.releaseCredit(issuer);
        vm.snapshotGasLastCall("credit withdrawal");
    }
}
