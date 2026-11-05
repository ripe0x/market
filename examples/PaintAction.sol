// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Artwork} from "./Artwork.sol";
import {PolicyBase} from "./PolicyBase.sol";

/// @title PaintAction
/// @notice Example 3. Sells one change to an artwork: the buyer picks a color from the
/// creator's allowed set and pays ETH. The order must be the token's painter, which only the
/// token's owner can arrange. The fill paints, resigns the painter role and closes the
/// order, so the authority cannot be used again. Input: the color.
contract PaintAction is PolicyBase {
    struct Config {
        Artwork art;
        uint256 tokenId;
        uint256 allowedColors; // bit i set: color i allowed
        uint256 price;
        Payee[] payees;
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
        _pay(c.payees, c.price);
        _sendETH(caller, value - c.price);
        _close();
        return "";
    }
}
