// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Admission, Order, OrderState, Phase} from "./Order.sol";

interface IOrderRegistry {
    function isOrder(address account) external view returns (bool);
}

/// @title Actions
/// @notice ERC721 ownership of the right to execute Holder orders. The token id is the order's
/// address. Only the order mints its token, once, while activating; only the order burns it, on
/// its terminal transition. A token moves only while its order is live, and never to the order
/// itself. An approved operator cannot execute or surrender, but can transfer the token to
/// itself and then act as owner.
contract Actions is ERC721 {
    using Strings for uint256;
    using Strings for address;

    IOrderRegistry public immutable market;

    error NotOrder();
    error InvalidTransfer();

    constructor(address market_) ERC721("Market Actions", "ACTION") {
        market = IOrderRegistry(market_);
    }

    function orderOf(uint256 id) public view returns (Order) {
        if (id > type(uint160).max || !market.isOrder(address(uint160(id)))) revert NotOrder();
        return Order(payable(address(uint160(id))));
    }

    function isLive(uint256 id) external view returns (bool) {
        return orderOf(id).isLive();
    }

    function mint(address to, uint256 id) external {
        Order order = orderOf(id);
        if (msg.sender != address(order) || order.admission() != Admission.Holder || order.phase() != Phase.Activating)
        {
            revert NotOrder();
        }
        _mint(to, id);
    }

    function burn(uint256 id) external {
        Order order = orderOf(id);
        OrderState s = order.state();
        if (msg.sender != address(order) || s == OrderState.Pending || s == OrderState.Live) revert NotOrder();
        _burn(id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        if (from != address(0) && to != address(0)) {
            Order order = orderOf(id);
            if (to == address(order) || !order.isLive()) revert InvalidTransfer();
        }
        return super._update(to, id, auth);
    }

    /// @notice Metadata built only from the order's own commitments and state. No action or
    /// target contract is called.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Order order = orderOf(id);
        uint256 end = order.deadline();
        bytes memory json = abi.encodePacked(
            '{"name":"Market Action ',
            address(order).toHexString(),
            '","description":"Right to execute one committed contract action through its own account.",',
            '"attributes":[{"trait_type":"issuer","value":"',
            order.issuer().toHexString(),
            '"},{"trait_type":"action","value":"',
            order.action().toHexString(),
            '"},{"trait_type":"actionCodehash","value":"',
            uint256(order.actionCodehash()).toHexString(32),
            '"},{"trait_type":"configHash","value":"',
            uint256(keccak256(order.config())).toHexString(32),
            '"},{"trait_type":"activationTermsHash","value":"',
            uint256(keccak256(order.activationTerms())).toHexString(32)
        );
        json = abi.encodePacked(
            json,
            '"},{"trait_type":"residual","value":"',
            order.residual().toHexString(),
            '"},{"trait_type":"deadline","value":"',
            end == 0 ? "perpetual" : end.toString(),
            '"},{"trait_type":"status","value":"',
            order.isExpired() ? "expired" : order.phase() != Phase.Idle ? "busy" : "live",
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }
}
