// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPolicy, Order} from "./Order.sol";

/// @title Market
/// @notice Deploys orders and announces them. Holds nothing, owns nothing, takes no fee and
/// cannot call anything, so an approval or transfer to this contract grants no authority.
contract Market {
    /// @notice The code every order runs, deployed with Market. Nothing can change it.
    address public immutable implementation = address(new Order());

    /// @notice `config` is published here so anyone can rebuild and fill the order without an indexer.
    event Created(Order indexed order, address indexed owner, IPolicy indexed policy, bytes32 salt, bytes config);

    error NoPolicyCode();
    error DelegatedPolicy();

    /// @notice Deploy an order owned by the caller. Any ETH sent funds the order.
    /// The address commits to the owner, policy, the policy's current code, config hash and
    /// salt; see `orderAddress`.
    function create(IPolicy policy, bytes calldata config, bytes32 salt) external payable returns (Order order) {
        uint256 size = address(policy).code.length;
        if (size == 0) revert NoPolicyCode();
        // An EIP-7702 account's code is a pointer its key holder can change at any time, so
        // reading it says nothing about what the policy will do. Contracts cannot start with
        // 0xef (EIP-3541), so this prefix identifies a delegated account.
        if (size == 23 && bytes3(address(policy).code) == 0xef0100) revert DelegatedPolicy();
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            implementation, _args(msg.sender, policy, keccak256(config)), salt, msg.value
        );
        order = Order(payable(clone));
        emit Created(order, msg.sender, policy, salt, config);
    }

    /// @notice The address `create` deploys to while `policy` has its current code. Assets and
    /// approvals may be sent there first.
    function orderAddress(address owner, IPolicy policy, bytes32 configHash, bytes32 salt)
        external
        view
        returns (address)
    {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(implementation, _args(owner, policy, configHash), salt);
    }

    /// @dev Read back by `Order` at fixed offsets; see `Order._arg`.
    function _args(address owner, IPolicy policy, bytes32 configHash) private view returns (bytes memory) {
        return abi.encodePacked(owner, policy, address(policy).codehash, configHash);
    }
}
