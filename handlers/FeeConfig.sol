// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "../src/Market.sol";
import {Order} from "../src/Order.sol";

/// @title FeeConfig
/// @notice The fee terms `NFTSale` and `NFTBid` read on every fill: who receives the fee and at
/// what rate. One `admin` sets both. Market never calls this contract and has no fee.
///
/// - The rate is at most `MAX_FEE_BPS` (1%) and starts there. A change applies to orders
///   created from the next second on; every order keeps the rate in force when `Market` created
///   it (`feeBpsOf`). An order `Market` did not create pays the latest rate.
/// - The recipient applies at once to every fill, including orders created earlier.
/// - The admin can hand the role to another account. Nothing else is privileged.
contract FeeConfig {
    /// @notice A fee rate and the first order creation time it applies to.
    struct Rate {
        uint64 since;
        uint16 bps;
    }

    /// @notice The highest fee rate, in basis points of the price: 1%.
    uint256 public constant MAX_FEE_BPS = 100;

    Market public immutable market;
    /// @notice Sets the rate, the recipient and the next admin.
    address public admin;
    /// @notice Receives every fill's fee.
    address public recipient;
    /// @notice Every rate ever set, oldest first; `since` never decreases.
    Rate[] public rates;

    event AdminSet(address admin);
    event RecipientSet(address recipient);
    event FeeSet(uint256 bps, uint256 since);

    error NotAdmin();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);

    constructor(Market market_, address admin_, address recipient_) {
        if (admin_ == address(0) || recipient_ == address(0)) revert ZeroAddress();
        market = market_;
        admin = admin_;
        recipient = recipient_;
        rates.push(Rate(0, uint16(MAX_FEE_BPS)));
        emit AdminSet(admin_);
        emit RecipientSet(recipient_);
        emit FeeSet(MAX_FEE_BPS, 0);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Hand the admin role to `admin_`. Takes effect at once; a wrong address loses it.
    function setAdmin(address admin_) external onlyAdmin {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @notice Send every later fee, from every order, to `recipient_`. If it refuses ETH, fills
    /// revert until the admin sets one that accepts.
    function setRecipient(address recipient_) external onlyAdmin {
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @notice Set the rate for orders created from the next second on. Earlier orders keep
    /// theirs.
    function setFee(uint16 bps) external onlyAdmin {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        uint64 since = uint64(block.timestamp + 1);
        rates.push(Rate(since, bps));
        emit FeeSet(bps, since);
    }

    /// @notice The rate new orders get.
    function feeBps() external view returns (uint256) {
        return rates[rates.length - 1].bps;
    }

    /// @notice Where `order`'s fee goes now and at what rate.
    function terms(address order) external view returns (address, uint256) {
        return (recipient, feeBpsOf(order));
    }

    /// @notice The fee rate of `order`: the rate in force when `Market` created it. An order
    /// `Market` did not create (`createdAt` 0) pays the latest rate.
    function feeBpsOf(address order) public view returns (uint256) {
        uint256 hi = rates.length - 1;
        if (hi == 0) return rates[0].bps;
        uint256 t = market.createdAt(Order(payable(order)));
        if (t == 0 || rates[hi].since <= t) return rates[hi].bps;
        // rates[0].since is 0. Keep rates[lo].since <= t < rates[hi].since, so the search costs
        // O(log n) reads however many changes follow.
        uint256 lo;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (rates[mid].since <= t) lo = mid;
            else hi = mid;
        }
        return rates[lo].bps;
    }
}
