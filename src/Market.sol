// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IOrderHandler, Order} from "./Order.sol";
import {IExerciseHandler, Right} from "./Right.sol";
import {Rights} from "./Rights.sol";

/// @title Market
/// @notice Deploys orders, records when, and announces them. Holds nothing, owns nothing, takes
/// no fee and cannot call anything, so an approval or transfer to this contract grants no
/// authority.
contract Market {
    /// @notice The code every order runs, deployed with Market. Nothing can change it.
    address public immutable implementation = address(new Order());
    Rights public immutable rights;
    address public immutable rightImplementation;
    mapping(address account => bool) public isRight;

    constructor() {
        rights = new Rights(address(this));
        rightImplementation = address(new Right(address(this), rights));
    }

    /// @notice Timestamp of the block in which `create` deployed `order`; 0 for any account it
    /// did not deploy. Handlers can use it to apply terms in force when the order was created.
    mapping(Order order => uint256) public createdAt;

    /// @notice `config` is published here so anyone can rebuild and fill the order without an indexer.
    event Created(
        Order indexed order, address indexed owner, IOrderHandler indexed handler, bytes32 salt, bytes config
    );
    event RightCreated(
        Right indexed account, address indexed issuer, IExerciseHandler indexed handler, bytes32 salt, bytes config
    );

    error NoHandlerCode();
    error DelegatedHandler();
    error ZeroResidual();
    error BadDeadline();

    /// @notice Deploy an order owned by the caller. Any ETH sent funds the order.
    /// The address commits to the owner, handler, the handler's current code, config hash and
    /// salt; see `orderAddress`.
    function create(IOrderHandler handler, bytes calldata config, bytes32 salt) external payable returns (Order order) {
        _checkHandler(address(handler));
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            implementation, _args(msg.sender, handler, keccak256(config)), salt, msg.value
        );
        order = Order(payable(clone));
        createdAt[order] = block.timestamp;
        emit Created(order, msg.sender, handler, salt, config);
    }

    /// @notice Create a pending, untradeable right account. Backing is supplied from outside
    /// the account; activation validates it and mints the canonical entitlement to the issuer.
    function createRight(
        IExerciseHandler handler,
        bytes calldata config,
        uint256 deadline,
        address residual,
        bytes32 salt
    ) external payable returns (Right account) {
        _checkHandler(address(handler));
        if (residual == address(0)) revert ZeroResidual();
        if (deadline != 0 && deadline <= block.timestamp) revert BadDeadline();
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            rightImplementation, _rightArgs(msg.sender, handler, keccak256(config), deadline, residual), salt, msg.value
        );
        account = Right(payable(clone));
        isRight[clone] = true;
        emit RightCreated(account, msg.sender, handler, salt, config);
    }

    function rightAddress(
        address issuer,
        IExerciseHandler handler,
        bytes32 configHash,
        uint256 deadline,
        address residual,
        bytes32 salt
    ) external view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            rightImplementation, _rightArgs(issuer, handler, configHash, deadline, residual), salt
        );
    }

    /// @notice The address `create` deploys to while `handler` has its current code. Assets and
    /// approvals may be sent there first.
    function orderAddress(address owner, IOrderHandler handler, bytes32 configHash, bytes32 salt)
        external
        view
        returns (address)
    {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            implementation, _args(owner, handler, configHash), salt
        );
    }

    /// @dev Read back by `Order` at fixed offsets; see `Order._arg`.
    function _args(address owner, IOrderHandler handler, bytes32 configHash) private view returns (bytes memory) {
        return abi.encodePacked(owner, handler, address(handler).codehash, configHash);
    }

    function _rightArgs(
        address issuer,
        IExerciseHandler handler,
        bytes32 configHash,
        uint256 deadline,
        address residual
    ) private view returns (bytes memory) {
        return abi.encodePacked(issuer, handler, address(handler).codehash, configHash, deadline, residual);
    }

    function _checkHandler(address handler) private view {
        uint256 size = handler.code.length;
        if (size == 0) revert NoHandlerCode();
        if (size == 23 && bytes3(handler.code) == 0xef0100) revert DelegatedHandler();
    }
}
