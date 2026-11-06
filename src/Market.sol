// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IOrderHandler, Order} from "./Order.sol";

/// @title Market
/// @notice Deploys orders and announces them. Holds nothing, owns nothing, takes no fee and
/// cannot call anything, so an approval or transfer to this contract grants no authority.
contract Market {
    /// @notice The code every order runs, deployed with Market. Nothing can change it.
    address public immutable implementation = address(new Order());

    /// @notice `config` is published here so anyone can rebuild and fill the order without an indexer.
    event Created(Order indexed order, address indexed owner, IOrderHandler indexed handler, bytes32 salt, bytes config);

    error NoHandlerCode();
    error DelegatedHandler();

    /// @notice Deploy an order owned by the caller. Any ETH sent funds the order.
    /// The address commits to the owner, handler, the handler's current code, config hash and
    /// salt; see `orderAddress`.
    function create(IOrderHandler handler, bytes calldata config, bytes32 salt) external payable returns (Order order) {
        uint256 size = address(handler).code.length;
        if (size == 0) revert NoHandlerCode();
        // An EIP-7702 account's code is a pointer its key holder can change at any time, so
        // reading it says nothing about what the handler will do. Contracts cannot start with
        // 0xef (EIP-3541), so this prefix identifies a delegated account.
        if (size == 23 && bytes3(address(handler).code) == 0xef0100) revert DelegatedHandler();
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            implementation, _args(msg.sender, handler, keccak256(config)), salt, msg.value
        );
        order = Order(payable(clone));
        emit Created(order, msg.sender, handler, salt, config);
    }

    /// @notice The address `create` deploys to while `handler` has its current code. Assets and
    /// approvals may be sent there first.
    function orderAddress(address owner, IOrderHandler handler, bytes32 configHash, bytes32 salt)
        external
        view
        returns (address)
    {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(implementation, _args(owner, handler, configHash), salt);
    }

    /// @dev Read back by `Order` at fixed offsets; see `Order._arg`.
    function _args(address owner, IOrderHandler handler, bytes32 configHash) private view returns (bytes memory) {
        return abi.encodePacked(owner, handler, address(handler).codehash, configHash);
    }
}
