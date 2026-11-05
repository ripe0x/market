// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPolicy, Order} from "../src/Order.sol";

/// @notice Helpers shared by the example policies. Every effect goes through the order that
/// called the policy, so other contracts see that order, never the policy, as the actor.
abstract contract PolicyBase is IPolicy {
    /// @notice A share of a payment. Shares are basis points and must total 10,000.
    struct Payee {
        address to;
        uint16 bps;
    }

    error BadPayees();
    error TokenCallFailed(address token);
    error UnexpectedETH();

    /// @dev Make the calling order perform one call. Works only inside that order's fill.
    function _exec(address target, uint256 value, bytes memory data) internal returns (bytes memory) {
        return Order(payable(msg.sender)).execute(target, value, data);
    }

    function _sendETH(address to, uint256 amount) internal {
        if (amount != 0) _exec(to, amount, "");
    }

    /// @dev ERC20 call as the order. Accepts tokens that return nothing; rejects `false` and
    /// addresses without code, which would otherwise "succeed" silently.
    function _tokenCall(address token, bytes memory data) internal {
        bytes memory ret = _exec(token, 0, data);
        if (token.code.length == 0 || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(token);
    }

    /// @dev Split `amount` of the order's ETH. The last payee receives the rounding remainder.
    function _pay(Payee[] memory payees, uint256 amount) internal {
        uint256 total;
        uint256 left = amount;
        for (uint256 i; i < payees.length; ++i) {
            total += payees[i].bps;
            uint256 share = i == payees.length - 1 ? left : amount * payees[i].bps / 10_000;
            left -= share;
            _sendETH(payees[i].to, share);
        }
        if (total != 10_000) revert BadPayees();
    }

    /// @dev End a single use order: the order calls its own `close`.
    function _close() internal {
        _exec(msg.sender, 0, abi.encodeCall(Order.close, ()));
    }
}
