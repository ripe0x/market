// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {HandlerBase} from "../handlers/HandlerBase.sol";

/// @notice Prices an acquisition bid. Read with `staticcall`; may not change state.
interface IBidStrategy {
    /// @param lastPrice clearing price of the previous acquisition, 0 if none
    /// @param lastTime time of the previous acquisition, 0 if none
    /// @param count acquisitions so far
    /// @param capital ETH the bid could spend right now
    function quote(uint256 lastPrice, uint256 lastTime, uint256 count, uint256 capital, bytes calldata params)
        external
        view
        returns (uint256);
}

/// @notice External capital an order may draw from during a fill. Not escrow: what is
/// available can change at any time.
interface ICapitalSource {
    function available(address spender) external view returns (uint256);
    /// @notice Send `amount` ETH to `msg.sender` or revert.
    function draw(uint256 amount) external;
}

/// @title AcquisitionBid
/// @notice Example 4. A persistent bid for any token of one ERC721 collection. Its maximum is
/// the lowest of the strategy's quote, the configured `maxPrice` and available capital
/// (the order's ETH plus whatever `source` will release). A holder approves this order for
/// the token and fills with `(tokenId, price)`; the holder is paid exactly `price` if it is
/// above zero and within the maximum. Each acquisition records its clearing price for the next
/// quote, so a gift at price zero is refused rather than recorded as a market price.
/// Capital may arrive at any time, in the order or in the source.
///
/// Unsafe for EOA sellers (SECURITY.md, finding A1): a holder approves this order, and the
/// order's owner can close it and use that approval before the holder's fill lands. Teaching
/// example only; `handlers/NFTBid.sol` is the production bid.
contract AcquisitionBid is HandlerBase {
    struct Config {
        IERC721 nft;
        address recipient; // receives acquired tokens
        uint256 maxPrice;
        IBidStrategy strategy;
        bytes strategyParams;
        ICapitalSource source; // address(0): only the order's own ETH
    }

    struct State {
        uint128 lastPrice;
        uint64 lastTime;
        uint64 count;
    }

    /// @notice Per order, written only by that order's own fills.
    mapping(address order => State) public state;

    event Acquired(address indexed order, uint256 indexed tokenId, address indexed seller, uint256 price);

    error AboveBid(uint256 price, uint256 bid);
    error ZeroPrice();
    error NotDelivered();

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        if (value != 0) revert UnexpectedETH();
        Config memory c = abi.decode(config, (Config));
        (uint256 tokenId, uint256 price) = abi.decode(input, (uint256, uint256));
        if (price == 0) revert ZeroPrice();
        uint256 bid = currentBid(msg.sender, c);
        if (price > bid) revert AboveBid(price, bid);

        // Delivery is checked independently of the seller: the recipient must not hold the
        // token before and must hold it after.
        if (c.nft.ownerOf(tokenId) == c.recipient) revert NotDelivered();
        _exec(address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (caller, c.recipient, tokenId)));
        if (c.nft.ownerOf(tokenId) != c.recipient) revert NotDelivered();

        uint256 held = msg.sender.balance;
        if (held < price) _exec(address(c.source), 0, abi.encodeCall(ICapitalSource.draw, (price - held)));

        State storage s = state[msg.sender];
        s.lastPrice = SafeCast.toUint128(price);
        s.lastTime = uint64(block.timestamp);
        s.count += 1;
        emit Acquired(msg.sender, tokenId, caller, price);

        _sendETH(caller, price);
        return abi.encode(price);
    }

    /// @notice The most `order` would pay now.
    function currentBid(address order, Config memory c) public view returns (uint256) {
        uint256 capital = order.balance;
        if (address(c.source) != address(0)) capital += c.source.available(order);
        State memory s = state[order];
        uint256 q = c.strategy.quote(s.lastPrice, s.lastTime, s.count, capital, c.strategyParams);
        if (q > c.maxPrice) q = c.maxPrice;
        return q < capital ? q : capital;
    }
}
