// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../src/Order.sol";
import {ICapitalSource} from "./AcquisitionBid.sol";

/// @title CapitalPool
/// @notice Example 4's external funding, independent of Market. Anyone may deposit ETH. The
/// owner grants specific order addresses an allowance that accrues at `rate` wei per second
/// up to `cap`. An order can draw only while it is filling, so the order's policy can spend
/// the grant and the order's owner cannot. Funds stay here until drawn, and the owner may
/// withdraw or revoke at any time: a grant is a conditional permission, not escrow.
contract CapitalPool is ICapitalSource {
    struct Grant {
        uint128 rate;
        uint128 cap;
        uint128 accrued;
        uint64 updated;
    }

    address public immutable owner;
    mapping(address spender => Grant) public grants;

    event GrantSet(address indexed spender, uint256 rate, uint256 cap);
    event Drawn(address indexed spender, uint256 amount);

    error NotOwner();
    error NotFilling();
    error OverAllowance(uint256 amount, uint256 allowance);
    error SendFailed();

    constructor(address owner_) payable {
        owner = owner_;
    }

    receive() external payable {}

    /// @notice Allowance accrued so far, ignoring this pool's balance.
    function allowance(address spender) public view returns (uint256) {
        Grant memory g = grants[spender];
        uint256 a = g.accrued + g.rate * (block.timestamp - g.updated);
        return a < g.cap ? a : g.cap;
    }

    function available(address spender) external view returns (uint256) {
        uint256 a = allowance(spender);
        return a < address(this).balance ? a : address(this).balance;
    }

    /// @notice Set or replace a grant; `(0, 0)` revokes. Allowance already accrued is kept up to the new cap.
    function setGrant(address spender, uint128 rate, uint128 cap) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 a = allowance(spender);
        grants[spender] = Grant(rate, cap, uint128(a < cap ? a : cap), uint64(block.timestamp));
        emit GrantSet(spender, rate, cap);
    }

    function draw(uint256 amount) external {
        if (!Order(payable(msg.sender)).filling()) revert NotFilling();
        uint256 a = allowance(msg.sender);
        if (amount > a) revert OverAllowance(amount, a);
        Grant storage g = grants[msg.sender];
        g.accrued = uint128(a - amount);
        g.updated = uint64(block.timestamp);
        emit Drawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    function withdraw(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }
}
