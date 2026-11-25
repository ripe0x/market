// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {Order, OrderState} from "../src/Order.sol";

contract SmokeTest is Base {
    function test_saleBidCovered() public {
        Order sale = _listSale(seller, 1, 1 ether);
        vm.prank(buyer);
        sale.execute{value: 1 ether}(abi.encode(buyer, 1 ether, uint64(0)));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 1_000 ether + 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(uint8(sale.state()), uint8(OrderState.Completed));

        Order bid = _bid(2 ether, 1, 2 ether);
        vm.startPrank(buyer);
        nft.approve(address(exchange), 1);
        bid.execute(abi.encode(uint256(1), 1.98 ether, buyer));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bidder);

        nft.mint(issuer, 7);
        Order c = _issueCovered(address(nft), 7, 3 ether, uint64(T0 + 1 days));
        assertEq(actions.ownerOf(_id(c)), issuer);
        vm.prank(issuer);
        actions.transferFrom(issuer, holder, _id(c));
        vm.prank(holder);
        c.execute{value: 3 ether}(abi.encode(holder));
        assertEq(nft.ownerOf(7), holder);
        assertEq(c.creditOf(issuer), 3 ether);
        c.releaseCredit(issuer);
        assertEq(issuer.balance, 1_000 ether + 3 ether);
    }
}
