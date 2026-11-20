// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FeeConfig
/// @notice The trading fee ExchangeAction applies. Each order snapshots `feeBps` when it
/// activates, bounded by its own maximum, and keeps that rate. Every execution pays the
/// recipient current at that moment. One admin sets both and hands the role on in two steps.
contract FeeConfig {
    uint256 public constant MAX_FEE_BPS = 100;

    address public admin;
    address public pendingAdmin;
    address public recipient;
    uint16 public feeBps;

    event AdminOffered(address pendingAdmin);
    event AdminSet(address admin);
    event RecipientSet(address recipient);
    event FeeSet(uint256 bps);

    error NotAdmin();
    error ZeroAddress();
    error FeeTooHigh(uint256 bps);

    constructor(address admin_, address recipient_) {
        if (admin_ == address(0) || recipient_ == address(0)) revert ZeroAddress();
        admin = admin_;
        recipient = recipient_;
        feeBps = uint16(MAX_FEE_BPS);
        emit AdminSet(admin_);
        emit RecipientSet(recipient_);
        emit FeeSet(MAX_FEE_BPS);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Offer the role; zero withdraws the offer.
    function setAdmin(address admin_) external onlyAdmin {
        pendingAdmin = admin_;
        emit AdminOffered(admin_);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminSet(msg.sender);
    }

    /// @notice A recipient that refuses ETH makes every execution with a nonzero fee revert
    /// until replaced.
    function setRecipient(address recipient_) external onlyAdmin {
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @notice Applies to orders activated afterwards.
    function setFee(uint16 bps) external onlyAdmin {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps = bps;
        emit FeeSet(bps);
    }
}
