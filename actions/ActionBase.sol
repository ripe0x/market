// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAction, Order, Phase} from "../src/Order.sol";
import {Market} from "../src/Market.sol";

/// @notice Authentication shared by the action implementations. Anyone can call a callback
/// directly with any arguments, and an order's own calls can reach it; only an order Market
/// created, bound to this implementation, in the matching phase and with matching readable
/// context vouches for its arguments.
abstract contract ActionBase is IAction {
    Market public immutable market;

    error NotAuthorized();
    error NothingToRelease();

    constructor(Market market_) {
        market = market_;
    }

    /// @dev For validate: the order itself asks, during activation or a preview.
    function _validating(address order) internal view returns (Order o) {
        if (msg.sender != order) revert NotAuthorized();
        o = _bound();
    }

    function _executing(address actor, uint256 value, bytes calldata config, bytes calldata terms)
        internal
        view
        returns (Order o)
    {
        o = _bound();
        if (o.phase() != Phase.Executing || o.actor() != actor || o.suppliedValue() != value) revert NotAuthorized();
        _matches(o, config, terms);
    }

    function _releasing(address actor, address recipient, bytes calldata config, bytes calldata terms)
        internal
        view
        returns (Order o)
    {
        o = _bound();
        if (o.phase() != Phase.Releasing || o.actor() != actor || o.releaseRecipient() != recipient) {
            revert NotAuthorized();
        }
        _matches(o, config, terms);
    }

    function _bound() private view returns (Order o) {
        o = Order(payable(msg.sender));
        if (!market.isOrder(msg.sender) || o.action() != address(this)) revert NotAuthorized();
    }

    function _matches(Order o, bytes calldata config, bytes calldata terms) private view {
        if (keccak256(config) != keccak256(o.config()) || keccak256(terms) != keccak256(o.activationTerms())) {
            revert NotAuthorized();
        }
    }

    /// @dev Pay from the order's free balance. Zero amounts make no call.
    function _pay(Order o, address to, uint256 amount) internal {
        if (amount != 0) o.call(to, amount, "");
    }
}
