// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "../src/Market.sol";
import {Order, OrderState} from "../src/Order.sol";
import {IReservedActionTarget} from "../reservations/IReservedActionTarget.sol";
import {ActionBase} from "./ActionBase.sol";

/// @title ReservedAction
/// @notice Executes one operation a target has reserved for the order's address. The promise
/// is the target's: the target records the reservation before activation and enforces the
/// executor, operation, deadline, call value and single use. Activation checks that the
/// reservation matches this order's operation, deadline and value, and commits the target's
/// runtime code hash. Execution takes exactly `price`, forwards `targetValue` with the call,
/// checks consumption and credits the rest to `proceedsTo`. Works with either admission.
///
/// The target code hash does not freeze a proxy target, mutable storage or dependencies.
contract ReservedAction is ActionBase {
    struct Config {
        IReservedActionTarget target;
        bytes operation;
        uint256 price;
        uint256 targetValue;
        address proceedsTo;
    }

    event ActionPerformed(address indexed order, address indexed actor, address indexed target, uint256 price);

    error InvalidConfig();
    error ReservationMismatch();
    error TargetChanged();
    error WrongPayment(uint256 expected, uint256 actual);
    error NotConsumed();

    constructor(Market market_) ActionBase(market_) {}

    /// @return abi.encode(bytes32 targetCodehash)
    function validate(address order, bytes calldata config) external view returns (bytes memory) {
        Order o = _validating(order);
        Config memory c = abi.decode(config, (Config));
        if (
            address(c.target).code.length == 0 || c.operation.length == 0 || c.targetValue > c.price
                || (c.proceedsTo == address(0) && c.price != c.targetValue)
        ) revert InvalidConfig();
        (bytes32 opHash, uint64 end, uint256 value, IReservedActionTarget.ReservationState s) =
            c.target.reservationOf(order);
        if (
            s != IReservedActionTarget.ReservationState.Reserved || opHash != keccak256(c.operation)
                || end != o.deadline() || value != c.targetValue
        ) revert ReservationMismatch();
        return abi.encode(address(c.target).codehash);
    }

    /// @param input Passed to the target unchanged; the target validates it.
    function onExecute(
        address actor,
        uint256 value,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bool, bytes memory result) {
        Order o = _executing(actor, value, config, terms);
        Config memory c = abi.decode(config, (Config));
        if (address(c.target).codehash != abi.decode(terms, (bytes32))) revert TargetChanged();
        if (value != c.price) revert WrongPayment(c.price, value);
        result = o.call(
            address(c.target),
            c.targetValue,
            abi.encodeCall(IReservedActionTarget.performAction, (c.operation, input))
        );
        (,,, IReservedActionTarget.ReservationState s) = c.target.reservationOf(address(o));
        if (s != IReservedActionTarget.ReservationState.Consumed) revert NotConsumed();
        if (c.price > c.targetValue) o.credit(c.proceedsTo, c.price - c.targetValue);
        emit ActionPerformed(address(o), actor, address(c.target), c.price);
        return (true, result);
    }

    /// @notice Release this order's reservation on the target. Anyone may clean up an ended
    /// order; while Pending only the residual beneficiary may, so a stranger cannot void a
    /// setup before activation. After activation the committed target code must be unchanged.
    function onRelease(address actor, address recipient, bytes calldata config, bytes calldata terms, bytes calldata)
        external
        returns (bytes memory)
    {
        Order o = _releasing(actor, recipient, config, terms);
        if (o.state() == OrderState.Pending && actor != o.residual()) revert NotAuthorized();
        Config memory c = abi.decode(config, (Config));
        if (terms.length != 0 && address(c.target).codehash != abi.decode(terms, (bytes32))) revert TargetChanged();
        o.call(address(c.target), 0, abi.encodeCall(IReservedActionTarget.releaseReservation, ()));
        return "";
    }
}
