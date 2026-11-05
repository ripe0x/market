// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PolicyBase} from "./PolicyBase.sol";

/// @title DutchAuction
/// @notice Example 1. Sells one ERC721 held by the order for ETH. The price falls linearly from
/// `startPrice` at `startTime` to `endPrice` at `endTime` and stays there. Anyone may buy;
/// input is the address that receives the NFT. Excess ETH returns to the caller.
/// The order closes after the sale.
contract DutchAuction is PolicyBase {
    struct Config {
        IERC721 nft;
        uint256 tokenId;
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        Payee[] payees;
    }

    error Underpaid(uint256 price, uint256 value);

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        Config memory c = abi.decode(config, (Config));
        address recipient = abi.decode(input, (address));
        uint256 p = price(c, block.timestamp);
        if (value < p) revert Underpaid(p, value);

        _exec(address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (msg.sender, recipient, c.tokenId)));
        _pay(c.payees, p);
        _sendETH(caller, value - p);
        _close();
        return abi.encode(p);
    }

    /// @notice Price at time `t`, rounded up (toward the seller). Reverts if the price rises.
    function price(Config memory c, uint256 t) public pure returns (uint256) {
        if (t <= c.startTime) return c.startPrice;
        if (t >= c.endTime) return c.endPrice;
        return c.startPrice - (c.startPrice - c.endPrice) * (t - c.startTime) / (c.endTime - c.startTime);
    }
}
