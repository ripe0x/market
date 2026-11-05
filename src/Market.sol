// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPolicy, Order} from "./Order.sol";

/// @title Market
/// @notice Deploys orders and announces them. Holds nothing, owns nothing, takes no fee and
/// cannot call anything, so an approval or transfer to this contract grants no authority.
contract Market {
    /// @notice `config` is published here so anyone can rebuild and fill the order without an indexer.
    event Created(Order indexed order, address indexed owner, IPolicy indexed policy, bytes32 salt, bytes config);

    error NoPolicyCode();

    /// @notice Deploy an order owned by the caller. Any ETH sent funds the order.
    /// The address commits to the owner, policy, config hash and salt; see `orderAddress`.
    function create(IPolicy policy, bytes calldata config, bytes32 salt) external payable returns (Order order) {
        if (address(policy).code.length == 0) revert NoPolicyCode();
        order = new Order{salt: salt, value: msg.value}(msg.sender, policy, keccak256(config));
        emit Created(order, msg.sender, policy, salt, config);
    }

    /// @notice The address `create` deploys to. Assets and approvals may be sent there first.
    function orderAddress(address owner, IPolicy policy, bytes32 configHash, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCode = keccak256(abi.encodePacked(type(Order).creationCode, abi.encode(owner, policy, configHash)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCode)))));
    }
}
