// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderHandler, Order} from "../src/Order.sol";
import {Base} from "./utils/Base.sol";

/// A contract written with no knowledge of Market: only its ringer may ring it.
contract Bell {
    address public owner = msg.sender;
    address public ringer;
    uint256 public rings;

    function setRinger(address r) external {
        require(msg.sender == owner);
        ringer = r;
    }

    function ring() external {
        require(msg.sender == ringer, "not ringer");
        rings++;
    }
}

/// The README's example of a new order type, verbatim.
contract BellHandler is IOrderHandler {
    function onFill(address, uint256 value, bytes calldata config, bytes calldata) external returns (bytes memory) {
        (address bell, uint256 fee, address payee) = abi.decode(config, (address, uint256, address));
        require(value == fee, "fee");
        Order(payable(msg.sender)).execute(bell, 0, abi.encodeWithSignature("ring()"));
        Order(payable(msg.sender)).execute(payee, value, "");
        return "";
    }
}

/// Acceptance test for the core question: a developer creates an order type nobody
/// anticipated, using Market unchanged.
contract NewOrderTypeTest is Base {
    function test_payToRingBell() public {
        vm.prank(seller);
        Bell bell = new Bell();
        BellHandler handler = new BellHandler();
        bytes memory config = abi.encode(address(bell), 0.01 ether, seller);
        Order order = _create(seller, handler, config);
        vm.prank(seller);
        bell.setRinger(address(order));

        vm.prank(buyer);
        order.fill{value: 0.01 ether}(config, "");
        vm.prank(attacker);
        order.fill{value: 0.01 ether}(config, "");
        assertEq(bell.rings(), 2);
        assertEq(seller.balance, 0.02 ether);

        vm.prank(buyer);
        vm.expectRevert(bytes("fee"));
        order.fill{value: 0}(config, "");
        vm.prank(buyer);
        vm.expectRevert(bytes("not ringer"));
        bell.ring();
    }
}
