// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IReservedActionTarget
/// @notice This project's proposed interface for a contract that grants one exact executor
/// address the right to perform one committed operation once. It is not an established
/// Ethereum standard. A target needs no knowledge of Market: it enforces the executor, the
/// operation, the deadline, the exact call value and single consumption itself.
interface IReservedActionTarget {
    enum ReservationState {
        None,
        Reserved,
        Consumed,
        Released
    }

    event ReservationGranted(
        address indexed executor, bytes32 indexed scope, bytes32 operationHash, uint64 deadline, uint256 value
    );
    event ReservationConsumed(address indexed executor);
    event ReservationReleased(address indexed executor);

    /// @notice The executor's one reservation. `deadline` is exclusive; zero never expires.
    function reservationOf(address executor)
        external
        view
        returns (bytes32 operationHash, uint64 deadline, uint256 value, ReservationState state);

    /// @notice Consume the caller's reservation and perform `operation` with `input`.
    /// `msg.value` must equal the reserved value. A revert leaves the reservation intact.
    function performAction(bytes calldata operation, bytes calldata input) external payable returns (bytes memory);

    /// @notice Release the caller's reservation if it is still Reserved; otherwise do nothing.
    function releaseReservation() external;
}
