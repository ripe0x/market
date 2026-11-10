// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderHandler, Order} from "../src/Order.sol";

/// @notice Helpers for handlers. Every effect goes through the order that called the handler,
/// so other contracts see that order, never the handler, as the actor.
abstract contract HandlerBase is IOrderHandler {
    error UnexpectedETH();

    /// @dev Make the calling order perform one call. Works only inside that order's fill.
    function _exec(address target, uint256 value, bytes memory data) internal returns (bytes memory) {
        return Order(payable(msg.sender)).execute(target, value, data);
    }

    function _sendETH(address to, uint256 amount) internal {
        if (amount != 0) _exec(to, amount, "");
    }

    /// @dev End a single use order: the order calls its own `close`.
    function _close() internal {
        _exec(msg.sender, 0, abi.encodeCall(Order.close, ()));
    }
}
