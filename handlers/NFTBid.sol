// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Order} from "../src/Order.sol";
import {NFTTrade} from "./NFTTrade.sol";

/// @title NFTBid
/// @notice A funded bid for ERC721s: one token, or any token of a collection, at a fixed, rising
/// or falling price (`NFTTrade.Schedule`). The bid pays from the ETH its order holds, sent with
/// `Market.create` or to the order at any time; a fill reverts while that is less than the price.
///
/// A holder approves this handler, not the order, for the token (`approve` or
/// `setApprovalForAll`), and fills with `abi.encode(uint256 tokenId, uint256 minProceeds)`. The
/// token goes from the holder straight to `recipient`; the holder receives `price - royalty`,
/// and the fill reverts if that is below `minProceeds`, so a stale quote or a changed royalty
/// cannot pay less than the holder accepted. The order pays exactly the scheduled price, never
/// more: that is the bidder's limit.
///
/// Why the handler holds the approval: an order's owner can close it at any moment and then
/// make any call as the order. An approval to a bid's order is therefore an approval to the
/// bidder, who could watch for it, close the bid and take the token unpaid. This handler has no
/// owner and fixed code, and moves a token only from the account that called `Order.fill` on a
/// genuine order bound to it, during that fill, to that order's `recipient`, for that order's
/// price. One approval serves every bid using this handler.
///
/// A bid can buy up to `maxFills` tokens, one per fill, and closes after the last; `maxFills`
/// 0 or 1 buys one. Each fill pays the schedule's price at that moment.
///
/// To cancel, the owner calls `Order.close` and withdraws the ETH through `Order.execute`.
contract NFTBid is NFTTrade {
    struct Config {
        IERC721 nft;
        bool anyToken; // true: any token of `nft`; false: only `tokenId`
        uint256 tokenId;
        Schedule schedule;
        address recipient;
        uint256 maxFills;
    }

    /// @dev Hash of the 45 byte ERC-1167 proxy code delegating to Market's order implementation.
    /// Any account whose code starts with it runs `Order`, whoever deployed it, so its `fill`
    /// reports the true caller.
    bytes32 private immutable proxyHash;
    /// @dev Proxy code plus the 104 bytes of arguments `Market` appends.
    uint256 private constant CLONE_SIZE = 149;

    /// @notice Tokens bought by each order, written only by that order's own fills.
    mapping(address order => uint256) public fills;

    event Bought(address indexed order, address indexed seller, uint256 indexed tokenId, uint256 price, uint256 royalty);

    error NotAFill();
    error WrongToken(uint256 tokenId);
    error InsufficientFunds(uint256 price, uint256 balance);
    error BelowMinProceeds(uint256 proceeds, uint256 minProceeds);

    constructor(Market market) {
        proxyHash = keccak256(
            abi.encodePacked(
                hex"363d3d373d3d3d363d73", market.implementation(), hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        // `caller` is trustworthy only from a genuine order, bound to this handler, inside its
        // fill: anyone can call this function, and after closing an order its owner can make
        // the order call it outside a fill.
        if (!_isOrder(msg.sender) || address(Order(payable(msg.sender)).handler()) != address(this)
            || !Order(payable(msg.sender)).filling()) revert NotAFill();
        if (value != 0) revert UnexpectedETH();
        Config memory c = abi.decode(config, (Config));
        (uint256 tokenId, uint256 minProceeds) = abi.decode(input, (uint256, uint256));
        (uint256 price, address royaltyTo, uint256 royalty) = quote(msg.sender, c, tokenId);
        if (price - royalty < minProceeds) revert BelowMinProceeds(price - royalty, minProceeds);

        // Count and, on the last fill, close before any external call.
        uint256 n = ++fills[msg.sender];
        if (n >= c.maxFills) _close();
        _deliver(c.nft, caller, c.recipient, tokenId);
        _sendETH(royaltyTo, royalty);
        _sendETH(caller, price - royalty);
        emit Bought(msg.sender, caller, tokenId, price, royalty);
        return abi.encode(price, royalty);
    }

    /// @notice What `order` would pay now for `tokenId` and how it splits; reverts when a fill
    /// would, except for the seller's own limit and the token transfer.
    function quote(address order, Config memory c, uint256 tokenId)
        public
        view
        returns (uint256 price, address royaltyTo, uint256 royalty)
    {
        if (!c.anyToken && tokenId != c.tokenId) revert WrongToken(tokenId);
        price = _currentPrice(c.schedule);
        if (order.balance < price) revert InsufficientFunds(price, order.balance);
        (royaltyTo, royalty) = royaltyOf(c.nft, tokenId, price);
    }

    /// @dev This handler moves the seller's token under the seller's approval to it.
    function _transfer(IERC721 nft, address from, address to, uint256 tokenId) internal override {
        nft.transferFrom(from, to, tokenId);
    }

    function _isOrder(address account) private view returns (bool) {
        if (account.code.length != CLONE_SIZE) return false;
        bytes32 h;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(account, p, 0, 45)
            h := keccak256(p, 45)
        }
        return h == proxyHash;
    }
}
