// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HandlerBase} from "../handlers/HandlerBase.sol";

/// @title TokenExchange
/// @notice Example 2. The order holds `give` tokens and releases them at a fixed rate for
/// `take` tokens paid to `payee`. Fills may be partial and repeat until the order runs out,
/// expires or is closed. Anyone may top it up while it is active; unsold inventory comes back
/// to the owner only after closing, since this handler offers no maintenance fill.
/// Input: `(amount of give, recipient)`.
/// The filler approves this order (not the handler) for the `take` owed.
contract TokenExchange is HandlerBase {
    struct Config {
        IERC20 give;
        IERC20 take;
        uint256 giveAmount; // rate: `takeAmount` of `take` per `giveAmount` of `give`
        uint256 takeAmount;
        address payee;
        uint256 expiry;
    }

    error Expired();
    error ShortPayment(uint256 received, uint256 owed);
    error ShortDelivery(uint256 received, uint256 amount);

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        if (value != 0) revert UnexpectedETH();
        Config memory c = abi.decode(config, (Config));
        if (block.timestamp > c.expiry) revert Expired();
        (uint256 amount, address recipient) = abi.decode(input, (uint256, address));
        uint256 owed = owedFor(c, amount);

        // The payee's actual balance change is the payment. Fee-on-transfer, self-payment and
        // tokens that lie about success all fail here.
        uint256 before = c.take.balanceOf(c.payee);
        _tokenCall(address(c.take), abi.encodeCall(IERC20.transferFrom, (caller, c.payee, owed)));
        uint256 received = c.take.balanceOf(c.payee) - before;
        if (received < owed) revert ShortPayment(received, owed);

        // Delivery is measured the same way, so the filler gets exactly `amount` or nothing.
        before = c.give.balanceOf(recipient);
        _tokenCall(address(c.give), abi.encodeCall(IERC20.transfer, (recipient, amount)));
        received = c.give.balanceOf(recipient) - before;
        if (received < amount) revert ShortDelivery(received, amount);
        return abi.encode(owed);
    }

    /// @notice `take` owed for `amount` of `give`, rounded up (toward the order).
    function owedFor(Config memory c, uint256 amount) public pure returns (uint256) {
        return Math.mulDiv(amount, c.takeAmount, c.giveAmount, Math.Rounding.Ceil);
    }
}
