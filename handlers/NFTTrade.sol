// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @title NFTTrade
/// @notice Pricing, ERC2981 royalties and ERC721 delivery shared by `NFTSale` and `NFTBid`.
///
/// Money terms, the same in both handlers:
/// - `price` is everything the buyer spends. Nothing is added on top.
/// - `royalty` is what the collection's ERC2981 `royaltyInfo(tokenId, price)` asks, paid out of
///   `price`. Collections that do not report ERC2981 through ERC165 pay none. A collection that
///   reports it but reverts, asks more than `price`, names no receiver, or whose receiver refuses
///   ETH makes the fill revert: a royalty is never skipped.
/// - `proceeds = price - royalty` goes to the seller.
abstract contract NFTTrade is HandlerBase {
    /// @notice A price that moves linearly from `startPrice` at `startTime` to `endPrice` at
    /// `endTime` and then stays at `endPrice`. Equal prices give a fixed price; a lower
    /// `endPrice` a falling one, a higher one a rising one. Fills are refused before `startTime`
    /// and from `expiry` on; `expiry` 0 never expires.
    struct Schedule {
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        uint256 expiry;
    }

    error NotStarted(uint256 startTime);
    error Expired(uint256 expiry);
    error ZeroAddress();
    error BadRoyalty(address receiver, uint256 royalty, uint256 price);
    error NotDelivered();

    /// @notice The price at the current block, or a revert outside the schedule's window.
    function _currentPrice(Schedule memory s) internal view returns (uint256) {
        if (block.timestamp < s.startTime) revert NotStarted(s.startTime);
        if (s.expiry != 0 && block.timestamp >= s.expiry) revert Expired(s.expiry);
        return priceAt(s, block.timestamp);
    }

    /// @notice The schedule's price at time `t`, ignoring the fill window. Between the end
    /// points the movement is rounded down, so the price is never further from `startPrice`
    /// than the line: a falling price rounds up (for the seller), a rising one down (for the
    /// bidder).
    function priceAt(Schedule memory s, uint256 t) public pure returns (uint256) {
        if (t >= s.endTime) return s.endPrice;
        if (t <= s.startTime) return s.startPrice;
        uint256 elapsed = t - s.startTime;
        uint256 duration = s.endTime - s.startTime;
        return s.endPrice < s.startPrice
            ? s.startPrice - (s.startPrice - s.endPrice) * elapsed / duration
            : s.startPrice + (s.endPrice - s.startPrice) * elapsed / duration;
    }

    /// @notice The ERC2981 royalty `nft` asks on a sale of `tokenId` at `price`.
    function royaltyOf(IERC721 nft, uint256 tokenId, uint256 price)
        public
        view
        returns (address receiver, uint256 royalty)
    {
        if (!ERC165Checker.supportsInterface(address(nft), type(IERC2981).interfaceId)) return (address(0), 0);
        (receiver, royalty) = IERC2981(address(nft)).royaltyInfo(tokenId, price);
        if (royalty > price || (royalty != 0 && receiver == address(0))) revert BadRoyalty(receiver, royalty, price);
    }

    /// @dev Moves `tokenId` from `from` to `to` with `transferFrom` (see `_transfer`), which
    /// gives `to` no callback; whoever picks `to` must make sure it can handle ERC721s. Delivery
    /// is judged by `ownerOf`, so it is only as honest as the collection.
    function _deliver(IERC721 nft, address from, address to, uint256 tokenId) internal {
        if (to == address(0)) revert ZeroAddress();
        if (nft.ownerOf(tokenId) == to) revert NotDelivered();
        _transfer(nft, from, to, tokenId);
        if (nft.ownerOf(tokenId) != to) revert NotDelivered();
    }

    /// @dev Who makes the transfer, and so whose approval it uses, is each handler's decision.
    function _transfer(IERC721 nft, address from, address to, uint256 tokenId) internal virtual;
}
