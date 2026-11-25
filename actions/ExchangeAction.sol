// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Market} from "../src/Market.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, Order} from "../src/Order.sol";
import {ActionBase} from "./ActionBase.sol";
import {FeeConfig} from "./FeeConfig.sol";

/// @title ExchangeAction
/// @notice ERC721 for native ETH, as a sale or a bid, through Public orders whose residual is
/// the issuer.
///
/// Money terms, for both sides: `price` is all the buyer spends. `fee` is the rate the order
/// snapshotted at activation, at most its `maxFeeBps`, rounded down, paid to the fee recipient
/// current at execution. `royalty` is the collection's ERC2981 answer for the price, capped at
/// `price - fee` so a large royalty cannot block trading; a reverting lookup or a royalty with no
/// receiver reverts. `proceeds = price - fee - royalty`. Settlement, refunds and delivery are immediate and
/// atomic with the execution.
///
/// Sale: the order holds one token before activation and completes on delivery. Input
/// `abi.encode(address recipient, uint256 maxPrice, uint64 minActionTimeLeft)`; ETH above the
/// price returns to the actor.
///
/// Bid: the order pays from its free ETH balance, which anyone may top up. Each execution buys
/// one token, up to `maxExecutions`. Input `abi.encode(uint256 tokenId, uint256 minProceeds,
/// address proceedsTo)`. The seller approves this contract, never the order: this contract
/// moves only the executing actor's selected token, inside that order's genuine execution, to
/// the bid's fixed recipient. It has no other way to use an approval.
///
/// Actions tokens: trading one requires its underlying order to be live, with at least the
/// requested time left before its deadline. Collection-wide bids on Actions are refused. The
/// resale price of an Actions token is separate from any price its own action charges.
contract ExchangeAction is ActionBase {
    enum Side {
        Sale,
        Bid
    }

    /// @notice Moves linearly from startPrice at startTime to endPrice at endTime and holds
    /// there. Executions before startTime revert. Between the endpoints the movement rounds
    /// down, so the price never moves further from startPrice than the line.
    struct Schedule {
        uint256 startPrice;
        uint256 endPrice;
        uint64 startTime;
        uint64 endTime;
    }

    struct Config {
        Side side;
        IERC721 nft;
        Schedule schedule;
        uint16 maxFeeBps;
        /// abi.encode(SaleTerms) or abi.encode(BidTerms)
        bytes terms;
    }

    struct SaleTerms {
        uint256 tokenId;
        address proceedsTo;
        uint16 maxRoyaltyBps;
    }

    struct BidTerms {
        bool anyToken;
        /// Zero when anyToken.
        uint256 tokenId;
        address recipient;
        uint64 maxExecutions;
        /// Zero unless nft is the Actions collection.
        uint64 minActionTimeLeft;
    }

    struct Quote {
        uint256 price;
        uint256 fee;
        address feeTo;
        uint256 royalty;
        address royaltyTo;
        uint256 proceeds;
    }

    FeeConfig public immutable fees;
    Actions public immutable actions;
    /// @notice Tokens bought by each bid order.
    mapping(address order => uint256) public executions;

    event Exchanged(
        address indexed order,
        uint256 indexed tokenId,
        Side side,
        address actor,
        address nftRecipient,
        address proceedsTo,
        uint256 price,
        uint256 fee,
        uint256 royalty
    );

    error Unsupported();
    error InvalidConfig();
    error FeeAboveMax(uint256 bps, uint256 maxBps);
    error NotEscrowed();
    error NotStarted(uint256 startTime);
    error AboveMaxPrice(uint256 price, uint256 maxPrice);
    error Underpaid(uint256 price, uint256 value);
    error RoyaltyAboveLimit(uint256 royalty, uint256 limit);
    error BadRoyalty();
    error WrongToken(uint256 tokenId);
    error BelowMinProceeds(uint256 proceeds, uint256 minProceeds);
    error InsufficientFunds(uint256 price, uint256 available);
    error UnexpectedValue();
    error ZeroAddress();
    error NotHeld();
    error NotDelivered();
    error ActionNotLive();
    error ActionTimeLeft(uint256 left, uint256 required);
    error InvalidLifetime();

    constructor(Market market_, FeeConfig fees_) ActionBase(market_) {
        fees = fees_;
        actions = market_.actions();
    }

    function validate(address order, bytes calldata config) external view returns (bytes memory) {
        Order o = _validating(order);
        if (o.admission() != Admission.Public || o.residual() != o.issuer()) revert Unsupported();
        Config memory c = abi.decode(config, (Config));
        Schedule memory s = c.schedule;
        uint256 end = o.deadline();
        if (address(c.nft).code.length == 0 || s.startTime > s.endTime || (end != 0 && end <= s.startTime)) {
            revert InvalidConfig();
        }
        uint256 bps = fees.feeBps();
        if (bps > c.maxFeeBps) revert FeeAboveMax(bps, c.maxFeeBps);
        if (c.side == Side.Sale) {
            SaleTerms memory t = abi.decode(c.terms, (SaleTerms));
            if (t.proceedsTo == address(0) || t.maxRoyaltyBps > 10_000) revert InvalidConfig();
            if (c.nft.ownerOf(t.tokenId) != order) revert NotEscrowed();
            if (address(c.nft) == address(actions) && !actions.isLive(t.tokenId)) revert ActionNotLive();
        } else {
            BidTerms memory t = abi.decode(c.terms, (BidTerms));
            if (t.recipient == address(0) || t.recipient == order || t.maxExecutions == 0) revert InvalidConfig();
            if (t.anyToken && t.tokenId != 0) revert InvalidConfig();
            if (address(c.nft) == address(actions) ? t.anyToken : t.minActionTimeLeft != 0) revert InvalidConfig();
        }
        return abi.encode(bps);
    }

    function onExecute(
        address actor,
        uint256 value,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bool, bytes memory) {
        Order o = _executing(actor, value, config, terms);
        Config memory c = abi.decode(config, (Config));
        uint256 bps = abi.decode(terms, (uint256));
        return c.side == Side.Sale ? _sell(o, actor, value, c, bps, input) : _buy(o, actor, value, c, bps, input);
    }

    /// @notice Return a sale's escrowed token to the residual beneficiary's choice of recipient.
    /// Only the residual may trigger it. A canonical Actions token whose order is no longer live
    /// cannot move, and reverts ActionNotLive.
    function onRelease(address actor, address recipient, bytes calldata config, bytes calldata terms, bytes calldata)
        external
        returns (bytes memory)
    {
        Order o = _releasing(actor, recipient, config, terms);
        Config memory c = abi.decode(config, (Config));
        if (c.side != Side.Sale) revert NothingToRelease();
        if (actor != o.residual()) revert NotAuthorized();
        uint256 id = abi.decode(c.terms, (SaleTerms)).tokenId;
        if (address(c.nft) == address(actions) && !actions.isLive(id)) revert ActionNotLive();
        _sendHeld(o, c.nft, id, recipient);
        return "";
    }

    /// @notice Advisory price and split for executing `order` now with `input`. Does not check
    /// custody, funding, approvals, remaining executions or order liveness.
    function quote(Order order, bytes calldata input) external view returns (Quote memory) {
        Config memory c = abi.decode(order.config(), (Config));
        uint256 bps = abi.decode(order.activationTerms(), (uint256));
        uint256 id;
        if (c.side == Side.Sale) id = abi.decode(c.terms, (SaleTerms)).tokenId;
        else (id,,) = abi.decode(input, (uint256, uint256, address));
        return _quote(c, bps, id);
    }

    function priceAt(Schedule memory s, uint256 t) public pure returns (uint256) {
        if (t >= s.endTime) return s.endPrice;
        if (t <= s.startTime) return s.startPrice;
        uint256 elapsed = t - s.startTime;
        uint256 duration = s.endTime - s.startTime;
        return s.endPrice < s.startPrice
            ? s.startPrice - Math.mulDiv(s.startPrice - s.endPrice, elapsed, duration)
            : s.startPrice + Math.mulDiv(s.endPrice - s.startPrice, elapsed, duration);
    }

    /// @notice The collection's ERC2981 royalty for `price`. Collections that do not report
    /// ERC2981 through ERC165 pay none.
    function royaltyOf(IERC721 nft, uint256 tokenId, uint256 price) public view returns (address to, uint256 amount) {
        if (!ERC165Checker.supportsInterface(address(nft), type(IERC2981).interfaceId)) return (address(0), 0);
        (to, amount) = IERC2981(address(nft)).royaltyInfo(tokenId, price);
        if (amount != 0 && to == address(0)) revert BadRoyalty();
    }

    function _sell(Order o, address actor, uint256 value, Config memory c, uint256 bps, bytes calldata input)
        private
        returns (bool, bytes memory)
    {
        SaleTerms memory t = abi.decode(c.terms, (SaleTerms));
        (address recipient, uint256 maxPrice, uint64 minLeft) = abi.decode(input, (address, uint256, uint64));
        if (recipient == address(0) || recipient == address(o)) revert ZeroAddress();
        _requireLifetime(c.nft, t.tokenId, minLeft);
        Quote memory q = _quote(c, bps, t.tokenId);
        if (q.price > maxPrice) revert AboveMaxPrice(q.price, maxPrice);
        if (value < q.price) revert Underpaid(q.price, value);
        uint256 limit = Math.mulDiv(q.price, t.maxRoyaltyBps, 10_000);
        if (q.royalty > limit) revert RoyaltyAboveLimit(q.royalty, limit);

        _sendHeld(o, c.nft, t.tokenId, recipient);
        _settle(o, q, t.proceedsTo);
        _pay(o, actor, value - q.price);
        emit Exchanged(
            address(o), t.tokenId, Side.Sale, actor, recipient, t.proceedsTo, q.price, q.fee, q.royalty
        );
        return (true, abi.encode(q));
    }

    function _buy(Order o, address actor, uint256 value, Config memory c, uint256 bps, bytes calldata input)
        private
        returns (bool complete, bytes memory)
    {
        BidTerms memory t = abi.decode(c.terms, (BidTerms));
        if (value != 0) revert UnexpectedValue();
        (uint256 id, uint256 minProceeds, address proceedsTo) = abi.decode(input, (uint256, uint256, address));
        if (proceedsTo == address(0)) revert ZeroAddress();
        if (!t.anyToken && id != t.tokenId) revert WrongToken(id);
        _requireLifetime(c.nft, id, t.minActionTimeLeft);
        complete = ++executions[address(o)] >= t.maxExecutions;
        Quote memory q = _quote(c, bps, id);
        if (q.proceeds < minProceeds) revert BelowMinProceeds(q.proceeds, minProceeds);
        uint256 available = o.freeBalance();
        if (q.price > available) revert InsufficientFunds(q.price, available);

        if (c.nft.ownerOf(id) != actor) revert NotHeld();
        c.nft.transferFrom(actor, t.recipient, id);
        if (c.nft.ownerOf(id) != t.recipient) revert NotDelivered();
        _settle(o, q, proceedsTo);
        emit Exchanged(address(o), id, Side.Bid, actor, t.recipient, proceedsTo, q.price, q.fee, q.royalty);
        return (complete, abi.encode(q));
    }

    function _quote(Config memory c, uint256 bps, uint256 tokenId) private view returns (Quote memory q) {
        if (block.timestamp < c.schedule.startTime) revert NotStarted(c.schedule.startTime);
        q.price = priceAt(c.schedule, block.timestamp);
        q.fee = q.price * bps / 10_000;
        q.feeTo = fees.recipient();
        (q.royaltyTo, q.royalty) = royaltyOf(c.nft, tokenId, q.price);
        if (q.royalty > q.price - q.fee) q.royalty = q.price - q.fee;
        q.proceeds = q.price - q.fee - q.royalty;
    }

    function _settle(Order o, Quote memory q, address proceedsTo) private {
        _pay(o, q.royaltyTo, q.royalty);
        _pay(o, q.feeTo, q.fee);
        _pay(o, proceedsTo, q.proceeds);
    }

    /// @dev The order transfers a token it holds and the result is checked by ownerOf.
    function _sendHeld(Order o, IERC721 nft, uint256 id, address to) private {
        if (nft.ownerOf(id) != address(o)) revert NotHeld();
        o.call(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(o), to, id)));
        if (nft.ownerOf(id) != to) revert NotDelivered();
    }

    function _requireLifetime(IERC721 nft, uint256 id, uint64 minLeft) private view {
        if (address(nft) != address(actions)) {
            if (minLeft != 0) revert InvalidLifetime();
            return;
        }
        Order u = actions.orderOf(id);
        if (!u.isLive()) revert ActionNotLive();
        uint256 end = u.deadline();
        if (end != 0 && end - block.timestamp < minLeft) revert ActionTimeLeft(end - block.timestamp, minLeft);
    }
}
