// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {NFTTrade} from "./NFTTrade.sol";

/// @title NFTSale
/// @notice Sells one ERC721 that the order holds, for ETH, at a fixed, falling or rising price
/// (`NFTTrade.Schedule`). The order is the escrow: the seller creates it, then transfers the
/// token to it (or transfers to `Market.orderAddress` first and creates after). The first
/// successful fill sells the token and closes the order.
///
/// Fill input: `abi.encode(address recipient, uint256 maxPrice)`. The buyer sends at least the
/// current price as ETH, and at most `maxPrice` is charged, so a quote that changes before the
/// transaction lands cannot cost more than the buyer accepted. ETH sent above the price returns
/// to the caller. `recipient` receives the token through `transferFrom`, without a callback.
///
/// Seller's limits: the schedule, and `maxRoyaltyBps`. If the collection's royalty is more than
/// that share of the price, the fill reverts instead of paying the seller less than agreed.
/// Proceeds go to `proceedsTo`.
///
/// To cancel, the owner calls `Order.close` and then takes the token and any ETH back through
/// `Order.execute`. The order holds no allowance, so closing revokes nothing.
contract NFTSale is NFTTrade {
    struct Config {
        IERC721 nft;
        uint256 tokenId;
        Schedule schedule;
        address proceedsTo;
        uint16 maxRoyaltyBps;
    }

    event Sold(address indexed order, address indexed buyer, address recipient, uint256 price, uint256 royalty);

    error AboveMaxPrice(uint256 price, uint256 maxPrice);
    error Underpaid(uint256 price, uint256 value);
    error RoyaltyAboveLimit(uint256 royalty, uint256 limit);

    constructor(Market market) NFTTrade(market) {}

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        // Without this, any contract could make this handler announce a sale that never settled.
        _requireFill();
        Config memory c = abi.decode(config, (Config));
        (address recipient, uint256 maxPrice) = abi.decode(input, (address, uint256));
        (uint256 price, address royaltyTo, uint256 royalty) = quote(c);
        if (price > maxPrice) revert AboveMaxPrice(price, maxPrice);
        if (value < price) revert Underpaid(price, value);

        // Close first: anything reached from the calls below finds the order already sold.
        _close();
        _deliver(c.nft, msg.sender, recipient, c.tokenId);
        _sendETH(royaltyTo, royalty);
        _sendETH(c.proceedsTo, price - royalty);
        _sendETH(caller, value - price);
        emit Sold(msg.sender, caller, recipient, price, royalty);
        return abi.encode(price, royalty);
    }

    /// @dev The order sends the token it holds.
    function _transfer(IERC721 nft, address from, address to, uint256 tokenId) internal override {
        _exec(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (from, to, tokenId)));
    }

    /// @notice What a fill would cost now and where the money would go; reverts when a fill
    /// would, except for the buyer's own limits and whether the order still holds the token.
    function quote(Config memory c) public view returns (uint256 price, address royaltyTo, uint256 royalty) {
        if (c.proceedsTo == address(0)) revert ZeroAddress();
        price = _currentPrice(c.schedule);
        (royaltyTo, royalty) = royaltyOf(c.nft, c.tokenId, price);
        uint256 limit = price * c.maxRoyaltyBps / 10_000;
        if (royalty > limit) revert RoyaltyAboveLimit(royalty, limit);
    }
}
