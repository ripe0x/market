// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Artwork} from "./Artwork.sol";
import {HandlerBase} from "../handlers/HandlerBase.sol";

/// @title PaintAction
/// @notice A handler that is not about trading: it sells one change to an artwork. The buyer
/// picks a color from the creator's allowed set and pays ETH to `payee`. The order must be the
/// token's painter, a permission `Artwork` grants and Market knows nothing about. The fill
/// paints, resigns the painter role and closes the order, so the permission is used once.
/// Input: the color.
///
/// Only the token's owner can make the order its painter, and should do so only for an order it
/// owns: once an order is closed, its owner can use every permission the order holds.
contract PaintAction is HandlerBase {
    struct Config {
        Artwork art;
        uint256 tokenId;
        uint256 allowedColors; // bit i set: color i allowed
        uint256 price;
        address payee;
    }

    error ColorNotAllowed(uint8 color);
    error Underpaid(uint256 price, uint256 value);

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        Config memory c = abi.decode(config, (Config));
        uint8 color = abi.decode(input, (uint8));
        if ((c.allowedColors >> color) & 1 == 0) revert ColorNotAllowed(color);
        if (value < c.price) revert Underpaid(c.price, value);

        _exec(address(c.art), 0, abi.encodeCall(Artwork.paint, (c.tokenId, color)));
        _exec(address(c.art), 0, abi.encodeCall(Artwork.resign, (c.tokenId)));
        _sendETH(c.payee, c.price);
        _sendETH(caller, value - c.price);
        _close();
        return "";
    }
}
