// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReservedActionTarget} from "./IReservedActionTarget.sol";

/// @title ReservedActionTarget
/// @notice Reservation bookkeeping for an IReservedActionTarget. The inheriting contract
/// authorizes `_reserve` with its own rules and implements `_perform`.
///
/// Each executor address holds at most one reservation, ever. A scope is the application
/// resource a reservation occupies; a scope holds one live reservation at a time. Once
/// recorded, a reservation can end only by consumption, by its executor's release, or by its
/// deadline on this contract's clock. Releasing or consuming an old reservation never clears a
/// newer one in the same scope. A perpetual reservation to an executor that never acts
/// occupies its scope permanently.
abstract contract ReservedActionTarget is IReservedActionTarget {
    struct Reservation {
        bytes32 operationHash;
        bytes32 scope;
        uint64 deadline;
        uint256 value;
        ReservationState state;
    }

    mapping(address executor => Reservation) private _reservations;
    mapping(bytes32 scope => address) public scopeExecutor;

    error ExecutorUsed();
    error ScopeReserved();
    error BadReservation();
    error NotReserved();
    error WrongOperation();
    error WrongValue(uint256 expected, uint256 actual);

    function reservationOf(address executor)
        external
        view
        returns (bytes32 operationHash, uint64 deadline, uint256 value, ReservationState state)
    {
        Reservation storage r = _reservations[executor];
        return (r.operationHash, r.deadline, r.value, r.state);
    }

    function scopeOfReservation(address executor) external view returns (bytes32) {
        return _reservations[executor].scope;
    }

    function isReservationLive(address executor) public view returns (bool) {
        Reservation storage r = _reservations[executor];
        return r.state == ReservationState.Reserved && (r.deadline == 0 || block.timestamp < r.deadline);
    }

    function isScopeReserved(bytes32 scope) public view returns (bool) {
        return isReservationLive(scopeExecutor[scope]);
    }

    function performAction(bytes calldata operation, bytes calldata input) external payable returns (bytes memory) {
        Reservation storage r = _reservations[msg.sender];
        if (!isReservationLive(msg.sender)) revert NotReserved();
        if (keccak256(operation) != r.operationHash) revert WrongOperation();
        if (msg.value != r.value) revert WrongValue(r.value, msg.value);
        r.state = ReservationState.Consumed;
        _clearScope(r.scope);
        emit ReservationConsumed(msg.sender);
        return _perform(operation, input);
    }

    function releaseReservation() external {
        Reservation storage r = _reservations[msg.sender];
        if (r.state != ReservationState.Reserved) return;
        r.state = ReservationState.Released;
        _clearScope(r.scope);
        emit ReservationReleased(msg.sender);
    }

    function _reserve(address executor, bytes32 scope, bytes memory operation, uint64 deadline, uint256 value)
        internal
    {
        if (executor == address(0) || operation.length == 0 || (deadline != 0 && deadline <= block.timestamp)) {
            revert BadReservation();
        }
        if (_reservations[executor].state != ReservationState.None) revert ExecutorUsed();
        if (isScopeReserved(scope)) revert ScopeReserved();
        bytes32 operationHash = keccak256(operation);
        _reservations[executor] = Reservation(operationHash, scope, deadline, value, ReservationState.Reserved);
        scopeExecutor[scope] = executor;
        emit ReservationGranted(executor, scope, operationHash, deadline, value);
    }

    /// @dev Only the scope's current executor clears it.
    function _clearScope(bytes32 scope) private {
        if (scopeExecutor[scope] == msg.sender) delete scopeExecutor[scope];
    }

    /// @dev Runs after the reservation is consumed. Revert to reject the input.
    function _perform(bytes calldata operation, bytes calldata input) internal virtual returns (bytes memory);
}
