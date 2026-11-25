// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Order, OrderSpec} from "./Order.sol";
import {Actions} from "./Actions.sol";

/// @title Market
/// @notice Immutable factory and canonical registry of Order accounts, and deployer of the
/// Actions collection. Creation forwards the supplied ETH to the new order. Market has no fee,
/// no admin, no allowlist and no function that moves assets it holds.
contract Market {
    Actions public immutable actions;
    /// @notice The fixed Order implementation every order delegates to.
    address public immutable implementation;
    /// @notice True for every order this Market created. Set before any callback runs.
    mapping(address account => bool) public isOrder;

    /// @notice Publishes every commitment, including the full configuration. The same
    /// commitments remain readable from the order's code.
    event Created(Order indexed order, address indexed issuer, address indexed action, bytes32 salt, OrderSpec spec);

    error NoActionCode();
    error DelegatedAction();
    error ZeroResidual();

    constructor() {
        actions = new Actions(address(this));
        implementation = address(new Order(address(this), actions));
    }

    /// @notice Deploy a Pending order issued by the caller. Any ETH sent funds the order. A
    /// config too long for a clone's code reverts with Clones.CloneArgumentsTooLong.
    /// @dev A deadline already passed is accepted: the order can never activate, but backing sent
    /// to its predicted address ahead of time stays recoverable through `release`. No check here
    /// may depend on time for the same reason. The address commits the action's code hash, so an
    /// action whose code can change moves its predicted addresses.
    function create(OrderSpec calldata spec, bytes32 salt) public payable returns (Order order) {
        if (spec.residual == address(0)) revert ZeroResidual();
        _checkAction(spec.action);
        order = Order(
            payable(Clones.cloneDeterministicWithImmutableArgs(implementation, _args(msg.sender, spec), salt, msg.value))
        );
        isOrder[address(order)] = true;
        emit Created(order, msg.sender, spec.action, salt, spec);
    }

    /// @notice Create an order and activate it in the same call. Backing must already be at the
    /// predicted address or be the ETH sent.
    function createAndActivate(OrderSpec calldata spec, bytes32 salt) external payable returns (Order order) {
        order = create(spec, salt);
        order.activate();
    }

    /// @notice The address `create` deploys to for `issuer` while `spec.action` has its current
    /// runtime code. Does not check the deadline, so it stays usable for history.
    function orderAddress(address issuer, OrderSpec calldata spec, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(implementation, _args(issuer, spec), salt);
    }

    /// @dev Read back by Order at fixed offsets.
    function _args(address issuer, OrderSpec calldata spec) private view returns (bytes memory) {
        return abi.encodePacked(
            issuer, spec.action, spec.action.codehash, uint8(spec.admission), spec.deadline, spec.residual, spec.config
        );
    }

    /// @dev Requires code that is not an EIP-7702 delegation designator.
    function _checkAction(address action) private view {
        uint256 size = action.code.length;
        if (size == 0) revert NoActionCode();
        if (size == 23 && bytes3(action.code) == 0xef0100) revert DelegatedAction();
    }
}
