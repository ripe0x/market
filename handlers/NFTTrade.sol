// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Market} from "../src/Market.sol";
import {Order} from "../src/Order.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @title NFTTrade
/// @notice Pricing, ERC2981 royalties and ERC721 delivery shared by `NFTSale` and `NFTBid`.
///
/// Money terms, the same in both handlers:
/// - `price` is everything the buyer spends. Nothing is added on top.
/// - `fee` is the order's fee rate (`feeBpsOf`, at most `MAX_FEE_BPS`, 1%) of `price`, rounded
///   down, paid out of `price` to `feeTo`. A `feeTo` that refuses ETH makes every fill revert.
/// - `royalty` is what the collection's ERC2981 `royaltyInfo(tokenId, price)` asks, capped at
///   `price - fee`, paid out of `price`. Collections that do not report ERC2981 through ERC165
///   pay none. A collection that reports it but reverts, or asks a royalty with no receiver, or
///   whose receiver refuses ETH, makes the fill revert: a royalty is never skipped.
/// - `proceeds = price - fee - royalty` goes to the seller.
///
/// Both handlers act only inside a genuine fill (`_requireFill`), so their `Sold` and `Bought`
/// events always describe a settlement that happened.
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
    error NotAFill();
    error NotFeeTo();
    error FeeTooHigh(uint256 bps);

    /// @notice A fee rate and the first order creation time it applies to.
    struct FeeRate {
        uint64 since;
        uint16 bps;
    }

    event FeeSet(uint256 bps, uint256 since);

    /// @notice The highest fee rate, in basis points of the price: 1%.
    uint256 public constant MAX_FEE_BPS = 100;
    /// @notice Receives every fill's fee and alone can change the rate for new orders. Fixed at
    /// deployment; nobody can change it.
    address public immutable feeTo;
    Market public immutable market;
    /// @notice Every rate ever set, oldest first. The first starts at `MAX_FEE_BPS`.
    FeeRate[] public feeRates;

    /// @dev Hash of the 45 byte ERC-1167 proxy code delegating to Market's order implementation.
    /// Any account whose code starts with it runs `Order`, whoever deployed it, so its `fill`
    /// reports the true caller and value.
    bytes32 private immutable proxyHash;
    /// @dev Proxy code plus the 104 bytes of arguments `Market` appends.
    uint256 private constant CLONE_SIZE = 149;

    constructor(Market market_, address feeTo_) {
        if (feeTo_ == address(0)) revert ZeroAddress();
        feeTo = feeTo_;
        market = market_;
        feeRates.push(FeeRate(0, uint16(MAX_FEE_BPS)));
        proxyHash = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", market_.implementation(), hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    /// @dev Revert unless `msg.sender` is an order bound to this handler, inside its own fill.
    /// Anyone can call `onFill` directly, with any `caller`, `value` and `config`, and an owner
    /// can make its closed order call it outside a fill. Only a genuine fill vouches that
    /// `caller` called, `value` was paid and `config` is the order's.
    function _requireFill() internal view {
        Order order = Order(payable(msg.sender));
        if (!_isOrder(msg.sender) || address(order.handler()) != address(this) || !order.filling()) {
            revert NotAFill();
        }
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

    /// @notice Set the fee rate for orders created from the next second on. Orders created
    /// earlier keep the rate in force at their creation. Only `feeTo`, at most `MAX_FEE_BPS`.
    function setFee(uint16 bps) external {
        if (msg.sender != feeTo) revert NotFeeTo();
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        uint64 since = uint64(block.timestamp + 1);
        feeRates.push(FeeRate(since, bps));
        emit FeeSet(bps, since);
    }

    /// @notice The rate new orders get.
    function feeBps() external view returns (uint256) {
        return feeRates[feeRates.length - 1].bps;
    }

    /// @notice The fee rate of `order`: the rate in force when `Market` created it. An order
    /// `Market` did not create pays the latest rate.
    /// ponytail: scans back from the latest rate, one storage read per later change; fine while
    /// changes are rare.
    function feeBpsOf(address order) public view returns (uint256) {
        uint256 i = feeRates.length - 1;
        if (i != 0) {
            uint256 t = market.createdAt(Order(payable(order)));
            if (t != 0) while (feeRates[i].since > t) --i;
        }
        return feeRates[i].bps;
    }

    /// @notice The fee and the ERC2981 royalty on a fill of `order` for `tokenId` at `price`.
    /// The royalty is capped at what the fee leaves.
    function _split(address order, IERC721 nft, uint256 tokenId, uint256 price)
        internal
        view
        returns (uint256 fee, address royaltyTo, uint256 royalty)
    {
        fee = price * feeBpsOf(order) / 10_000;
        (royaltyTo, royalty) = royaltyOf(nft, tokenId, price);
        if (royalty > price - fee) royalty = price - fee;
    }

    /// @notice The ERC2981 royalty `nft` asks on a sale of `tokenId` at `price`, uncapped.
    function royaltyOf(IERC721 nft, uint256 tokenId, uint256 price)
        public
        view
        returns (address receiver, uint256 royalty)
    {
        if (!ERC165Checker.supportsInterface(address(nft), type(IERC2981).interfaceId)) return (address(0), 0);
        (receiver, royalty) = IERC2981(address(nft)).royaltyInfo(tokenId, price);
        if (royalty != 0 && receiver == address(0)) revert BadRoyalty(receiver, royalty, price);
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
