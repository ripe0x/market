// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
}

/// @notice Read-only price source for a listing or bid. Anyone may write one. Market
/// clamps its answer to the order's own bounds (`floor` for a listing, `maxPrice` and
/// the remaining budget for a bid), so a strategy can only move the price inside what
/// the order's owner already authorized.
interface IPricingStrategy {
    /// @param orderId the listing or bid id
    /// @param isBid true when pricing a bid (what the buyer pays), false for a listing
    ///        (the seller's minimum net proceeds)
    /// @param fills completed fills of this order before this one (always 0 for a listing)
    function price(uint256 orderId, bool isBid, address nft, uint256 tokenId, uint256 fills, bytes32 data)
        external
        view
        returns (uint256);
}

/// @notice Optional sale notification. A collection opts in by reporting this
/// interface id through ERC-165. Market calls it after every completed sale of the
/// collection's tokens, with a fixed gas limit and no value. A failed call is ignored.
interface ISaleObserver {
    function onMarketSale(uint256 tokenId, address seller, address buyer, address currency, uint256 price) external;
}

/// @notice Shared escrow exchange for ERC721 tokens.
///
/// Listings: a seller deposits one NFT with `safeTransferFrom(seller, market, id, data)`
/// where `data` encodes the listing terms. The terms set the seller's minimum net
/// proceeds. A listing sells to a direct buyer (`buy`), into a Market bid (`matchBid`),
/// or into an OpenSea offer (`fillOffer`). OpenSea signs offers only for the NFT's
/// owner, which is why NFTs are escrowed here.
///
/// Bids: a buyer deposits a budget (`createBid`) to acquire up to `quantity` NFTs whose
/// token ids fall in a range of one collection: one token, a whole collection, or a
/// contiguous range. A bid fills when a holder sells into it (`safeTransferFrom` with
/// sell data) or when an escrowed listing matches it (`matchBid`).
///
/// Economics: the sale price is what the buyer pays. Royalty (ERC-2981), the protocol
/// fee and, on executor-run fills, the executor fee come out of the sale price. The
/// rest goes to the seller and must cover the seller's minimum. A buyer never pays more
/// than its bound. On an OpenSea fill the offer's own consideration settles royalties
/// and OpenSea's fee; Market adds no royalty there.
///
/// Storage holds a hash of each order's terms and the state needed to settle, fund
/// and cancel it. Every call that names an order passes its full terms, which are
/// emitted when the order is created.
///
/// Invariants:
/// - An NFT leaves Market only to the buyer of a sale or to its seller's chosen address
///   on withdrawal.
/// - For each currency, Market's balance covers every live bid's unspent budget.
///   A call that would leave less reverts.
/// - Users grant Market no NFT approvals. Market approves Seaport only for the one
///   token and the exact currency amount of an OpenSea fill, inside that call.
/// - The owner can enable currencies and OpenSea zones and nothing else. Withdrawals
///   and cancellations never depend on the owner, a strategy, a callback or OpenSea.
contract Market {
    struct Price {
        uint128 start; // built-in: amount at startTime and before
        uint128 end; // built-in: amount at endTime and after; linear in between
        uint40 startTime;
        uint40 endTime;
        address strategy; // zero: built-in linear. Otherwise an IPricingStrategy
        bytes32 data; // passed to the strategy
    }

    struct Listing {
        address seller; // set from the transfer
        address nft; // set from the transfer
        uint256 tokenId; // set from the transfer
        address currency;
        address recipient; // receives the seller's proceeds
        uint128 floor; // minimum net proceeds, whatever the price says
        uint40 expiry;
        Price price; // the seller's minimum net proceeds over time
    }

    struct Bid {
        address buyer; // set to the creator
        address recipient; // receives acquired NFTs
        address nft;
        uint256 minTokenId;
        uint256 maxTokenId;
        address currency;
        uint128 budget; // total the buyer may spend, deposited at creation
        uint128 maxPrice; // most the buyer pays for one NFT, whatever the price says
        uint32 quantity; // most NFTs acquired
        uint40 expiry;
        Price price; // what the buyer pays for one NFT
    }

    struct Order {
        bytes32 hash; // zero: no such order, or sold, or withdrawn
        uint128 spent; // bids only
        uint32 fills; // bids only
        bool cancelled; // cannot fill; assets remain withdrawable
    }

    /// @dev Every amount in the currency of the order. `price` is what the buyer pays;
    /// `proceeds` is what the seller's recipient receives.
    struct Quote {
        uint256 price;
        uint256 royalty;
        address royaltyRecipient;
        uint256 protocolFee; // includes the referral share, if any
        uint256 executorFee;
        uint256 proceeds;
    }

    ConsiderationInterface public constant SEAPORT = ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 public constant PROTOCOL_FEE_BPS = 20;
    uint256 public constant REFERRAL_FEE_BPS = 10; // paid out of the protocol fee
    uint256 public constant EXECUTOR_FEE_BPS = 30; // only on matchBid and fillOffer
    uint256 internal constant BPS = 10_000;

    uint256 public constant STRATEGY_GAS = 100_000;
    uint256 public constant ROYALTY_GAS = 50_000;
    uint256 public constant CALLBACK_GAS = 100_000;
    uint256 internal constant ERC165_GAS = 30_000;

    bytes32 internal constant LISTING_TAG = keccak256("Market.Listing");
    bytes32 internal constant BID_TAG = keccak256("Market.Bid");
    bytes1 internal constant LIST = 0x00;
    bytes1 internal constant SELL = 0x01;

    address public immutable PROTOCOL_FEE_RECIPIENT;

    address public owner;
    mapping(address => bool) public currencies; // WETH is always enabled
    mapping(address => bool) public zones; // OpenSea zones whose offers fillOffer accepts
    mapping(uint256 => Order) public orders;
    uint256 public lastId;

    bool transient locked;

    event Listed(uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, Listing listing);
    event ListingUpdated(uint256 indexed id, Listing listing);
    event BidCreated(uint256 indexed id, address indexed buyer, address indexed nft, Bid bid);
    event Cancelled(uint256 indexed id);
    event Withdrawn(uint256 indexed id, address to);
    event Sale(
        uint256 indexed listingId, // 0 when a holder sold straight into a bid
        uint256 indexed bidId, // 0 for a direct buy or an OpenSea fill
        address indexed nft,
        uint256 tokenId,
        address seller,
        address buyer,
        address currency,
        Quote quote,
        address referrer
    );
    event CurrencySet(address indexed token, bool enabled);
    event ZoneSet(address indexed zone, bool enabled);
    event OwnerSet(address indexed owner);

    error Locked();
    error Unauthorized();
    error InvalidTerms();
    error NotActive();
    error NotEligible();
    error CurrencyDisabled();
    error PriceAboveLimit();
    error ProceedsBelowMinimum();
    error Incompatible();
    error StrategyFailed();
    error PaymentFailed();
    error NftNotDelivered();
    error CallbackGas();

    modifier lock() {
        if (locked) revert Locked();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address protocolFeeRecipient, address owner_, address openSeaZone) {
        PROTOCOL_FEE_RECIPIENT = protocolFeeRecipient;
        owner = owner_;
        zones[openSeaZone] = true;
        emit OwnerSet(owner_);
        emit ZoneSet(openSeaZone, true);
    }

    // ---------------------------------------------------------------- listings

    /// @notice Deposit entry point. `data` is `0x00 ‖ abi.encode(Listing)` to list, or
    /// `0x01 ‖ abi.encode(Bid, bidId, minProceeds, referrer)` to sell into a bid. The
    /// transfer must be made by the owner itself (`operator == from`).
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        lock
        returns (bytes4)
    {
        if (operator != from) revert Unauthorized();
        // A legitimate ERC721 calls this after the transfer.
        if (IERC721(msg.sender).ownerOf(tokenId) != address(this)) revert NftNotDelivered();
        if (data.length == 0) revert InvalidTerms();
        if (data[0] == LIST) {
            Listing memory l = abi.decode(data[1:], (Listing));
            (l.seller, l.nft, l.tokenId) = (from, msg.sender, tokenId);
            _checkListing(l);
            uint256 id = ++lastId;
            orders[id].hash = hashListing(l);
            emit Listed(id, from, msg.sender, tokenId, l);
        } else if (data[0] == SELL) {
            (Bid memory b, uint256 bidId, uint256 minProceeds, address referrer) =
                abi.decode(data[1:], (Bid, uint256, uint256, address));
            Order storage o = _liveBid(b, bidId, msg.sender, tokenId);
            Quote memory q = _quote(msg.sender, tokenId, _bidPrice(b, bidId, tokenId, o), 0);
            if (q.proceeds < minProceeds) revert ProceedsBelowMinimum();
            _fillBid(o, q.price);
            _deliver(msg.sender, tokenId, b.recipient);
            _pay(b.currency, q, from, address(0), referrer);
            emit Sale(0, bidId, msg.sender, tokenId, from, b.recipient, b.currency, q, referrer);
            _notify(msg.sender, tokenId, from, b.recipient, b.currency, q.price);
        } else {
            revert InvalidTerms();
        }
        return this.onERC721Received.selector;
    }

    /// @notice Replace a live listing's terms. The NFT and seller cannot change.
    function updateListing(Listing calldata l, uint256 id, Listing memory next) external lock {
        if (msg.sender != l.seller) revert Unauthorized();
        _liveListing(l, id);
        (next.seller, next.nft, next.tokenId) = (l.seller, l.nft, l.tokenId);
        _checkListing(next);
        orders[id].hash = hashListing(next);
        emit ListingUpdated(id, next);
    }

    /// @notice Buy a listing. Pay with ETH (WETH listings only; send at least the price,
    /// the excess returns as WETH) or with the listing's currency (approve Market for the
    /// price). Reverts if the price exceeds `maxPrice`.
    function buy(Listing calldata l, uint256 id, uint256 maxPrice, address recipient, address referrer)
        external
        payable
        lock
        returns (Quote memory q)
    {
        _liveListing(l, id);
        q = _buyQuote(l, id);
        if (q.price > maxPrice) revert PriceAboveLimit();
        delete orders[id];
        if (recipient == address(0)) recipient = msg.sender;
        _collect(l.currency, q.price);
        _deliver(l.nft, l.tokenId, recipient);
        _pay(l.currency, q, l.recipient, address(0), referrer);
        emit Sale(id, 0, l.nft, l.tokenId, l.seller, recipient, l.currency, q, referrer);
        _notify(l.nft, l.tokenId, l.seller, recipient, l.currency, q.price);
    }

    /// @notice Sell an escrowed listing into a Market bid at the bid's price. Anyone may
    /// call and earns the executor fee.
    function matchBid(Listing calldata l, uint256 listingId, Bid calldata b, uint256 bidId)
        external
        lock
        returns (Quote memory q)
    {
        _liveListing(l, listingId);
        Order storage o = _liveBid(b, bidId, l.nft, l.tokenId);
        if (l.currency != b.currency) revert NotEligible();
        q = _quote(l.nft, l.tokenId, _bidPrice(b, bidId, l.tokenId, o), EXECUTOR_FEE_BPS);
        if (q.proceeds < _ask(l, listingId)) revert ProceedsBelowMinimum();
        delete orders[listingId];
        _fillBid(o, q.price);
        _deliver(l.nft, l.tokenId, b.recipient);
        _pay(l.currency, q, l.recipient, msg.sender, address(0));
        emit Sale(listingId, bidId, l.nft, l.tokenId, l.seller, b.recipient, l.currency, q, address(0));
        _notify(l.nft, l.tokenId, l.seller, b.recipient, l.currency, q.price);
    }

    /// @notice Sell an escrowed listing into a signed OpenSea offer through
    /// `Seaport.fulfillAdvancedOrder`, with Market as fulfiller. Anyone may call and
    /// earns the executor fee. `offer` carries the zone extraData OpenSea signed for
    /// Market; `resolvers` index the offer as order 0.
    ///
    /// The sale price is the bidder's currency decrease. Market keeps the currency the
    /// offer releases after its own consideration (OpenSea fee, royalties), takes the
    /// protocol and executor fees on the sale price, and pays the rest to the seller.
    function fillOffer(
        Listing calldata l,
        uint256 listingId,
        AdvancedOrder calldata offer,
        CriteriaResolver[] calldata resolvers
    ) external lock returns (Quote memory q) {
        _liveListing(l, listingId);
        OfferItem[] calldata offered = offer.parameters.offer;
        if (
            !zones[offer.parameters.zone] || offered.length != 1 || offered[0].itemType != ItemType.ERC20
                || offered[0].token != l.currency
        ) revert Incompatible();
        uint256 minimum = _ask(l, listingId);
        delete orders[listingId];

        address buyer;
        uint256 gained;
        (buyer, gained, q.price) = _fulfill(l.nft, l.tokenId, l.currency, offer, resolvers);
        q.protocolFee = q.price * PROTOCOL_FEE_BPS / BPS;
        q.executorFee = q.price * EXECUTOR_FEE_BPS / BPS;
        if (gained < q.protocolFee + q.executorFee + minimum) revert ProceedsBelowMinimum();
        q.proceeds = gained - q.protocolFee - q.executorFee;
        _pay(l.currency, q, l.recipient, msg.sender, address(0));
        emit Sale(listingId, 0, l.nft, l.tokenId, l.seller, buyer, l.currency, q, address(0));
        _notify(l.nft, l.tokenId, l.seller, buyer, l.currency, q.price);
    }

    /// @notice Stop a listing from filling. The NFT stays in escrow until withdrawn.
    function cancelListing(Listing calldata l, uint256 id) external lock {
        if (msg.sender != l.seller) revert Unauthorized();
        Order storage o = orders[id];
        // No expiry or currency check: cancelling never depends on the owner.
        if (o.hash != hashListing(l) || o.cancelled) revert NotActive();
        o.cancelled = true;
        emit Cancelled(id);
    }

    /// @notice Return a listed or cancelled NFT to `to`. If the transfer fails, the
    /// listing is unchanged; `cancelListing` still stops it from filling.
    function withdrawListing(Listing calldata l, uint256 id, address to) external lock {
        if (msg.sender != l.seller) revert Unauthorized();
        if (orders[id].hash != hashListing(l)) revert NotActive();
        delete orders[id];
        IERC721(l.nft).transferFrom(address(this), to, l.tokenId);
        emit Withdrawn(id, to);
    }

    // -------------------------------------------------------------------- bids

    /// @notice Create a bid and deposit its whole budget: ETH for WETH bids (exactly
    /// `budget`), otherwise the currency (approve Market for `budget`).
    function createBid(Bid memory b) external payable lock returns (uint256 id) {
        b.buyer = msg.sender;
        if (!_currencyEnabled(b.currency)) revert CurrencyDisabled();
        if (
            b.recipient == address(0) || b.budget == 0 || b.quantity == 0 || b.minTokenId > b.maxTokenId
                || b.expiry <= block.timestamp || (msg.value != 0 && msg.value != b.budget)
        ) revert InvalidTerms();
        _collect(b.currency, b.budget);
        id = ++lastId;
        orders[id].hash = hashBid(b);
        emit BidCreated(id, msg.sender, b.nft, b);
    }

    /// @notice Stop a bid from filling. The unspent budget stays until withdrawn.
    function cancelBid(Bid calldata b, uint256 id) external lock {
        if (msg.sender != b.buyer) revert Unauthorized();
        Order storage o = orders[id];
        if (o.hash != hashBid(b) || o.cancelled) revert NotActive();
        o.cancelled = true;
        emit Cancelled(id);
    }

    /// @notice Return a bid's unspent budget to `to` and close the bid. Works for live,
    /// cancelled, expired and exhausted bids, and for disabled currencies.
    function withdrawBid(Bid calldata b, uint256 id, address to) external lock {
        if (msg.sender != b.buyer) revert Unauthorized();
        Order storage o = orders[id];
        if (o.hash != hashBid(b)) revert NotActive();
        uint256 refund = b.budget - o.spent;
        delete orders[id];
        _send(b.currency, to, refund);
        emit Withdrawn(id, to);
    }

    // ------------------------------------------------------------------ quotes

    /// @notice What a direct buyer pays now and how it splits. Reverts if not buyable.
    function quoteBuy(Listing calldata l, uint256 id) external view returns (Quote memory) {
        _liveListing(l, id);
        return _buyQuote(l, id);
    }

    /// @notice What a holder of `tokenId` receives by selling into a bid now.
    function quoteSell(Bid calldata b, uint256 id, uint256 tokenId) external view returns (Quote memory) {
        Order storage o = _liveBid(b, id, b.nft, tokenId);
        return _quote(b.nft, tokenId, _bidPrice(b, id, tokenId, o), 0);
    }

    /// @notice The split of `matchBid` now. Reverts if the bid does not cover the ask.
    function quoteMatch(Listing calldata l, uint256 listingId, Bid calldata b, uint256 bidId)
        external
        view
        returns (Quote memory q)
    {
        _liveListing(l, listingId);
        Order storage o = _liveBid(b, bidId, l.nft, l.tokenId);
        if (l.currency != b.currency) revert NotEligible();
        q = _quote(l.nft, l.tokenId, _bidPrice(b, bidId, l.tokenId, o), EXECUTOR_FEE_BPS);
        if (q.proceeds < _ask(l, listingId)) revert ProceedsBelowMinimum();
    }

    /// @notice The seller's current minimum net proceeds.
    function ask(Listing calldata l, uint256 id) external view returns (uint256) {
        return _ask(l, id);
    }

    function hashListing(Listing memory l) public pure returns (bytes32) {
        return keccak256(abi.encode(LISTING_TAG, l));
    }

    function hashBid(Bid memory b) public pure returns (bytes32) {
        return keccak256(abi.encode(BID_TAG, b));
    }

    // ------------------------------------------------------------------- owner

    /// @notice Enable or disable a payment currency. Disabling stops new orders and
    /// fills in it; withdrawals and cancellations continue.
    function setCurrency(address token, bool enabled) external onlyOwner {
        currencies[token] = enabled;
        emit CurrencySet(token, enabled);
    }

    /// @notice Enable or disable an OpenSea zone for `fillOffer`.
    function setZone(address zone, bool enabled) external onlyOwner {
        zones[zone] = enabled;
        emit ZoneSet(zone, enabled);
    }

    function setOwner(address next) external onlyOwner {
        owner = next;
        emit OwnerSet(next);
    }

    // ---------------------------------------------------------------- internal

    function _checkListing(Listing memory l) internal view {
        if (!_currencyEnabled(l.currency)) revert CurrencyDisabled();
        if (l.recipient == address(0) || l.expiry <= block.timestamp) revert InvalidTerms();
    }

    function _liveListing(Listing calldata l, uint256 id) internal view {
        Order storage o = orders[id];
        if (o.hash != hashListing(l) || o.cancelled || block.timestamp >= l.expiry) revert NotActive();
        if (!_currencyEnabled(l.currency)) revert CurrencyDisabled();
    }

    function _liveBid(Bid memory b, uint256 id, address nft, uint256 tokenId) internal view returns (Order storage o) {
        o = orders[id];
        if (
            o.hash != hashBid(b) || o.cancelled || block.timestamp >= b.expiry || o.fills >= b.quantity
                || o.spent >= b.budget
        ) {
            revert NotActive();
        }
        if (!_currencyEnabled(b.currency)) revert CurrencyDisabled();
        if (nft != b.nft || tokenId < b.minTokenId || tokenId > b.maxTokenId) revert NotEligible();
    }

    function _fillBid(Order storage o, uint256 price) internal {
        o.spent += uint128(price); // price <= budget - spent, see _bidPrice
        o.fills += 1;
    }

    function _currencyEnabled(address token) internal view returns (bool) {
        return token == WETH || currencies[token];
    }

    /// @dev The seller's minimum net proceeds: the price, never below the floor.
    function _ask(Listing calldata l, uint256 id) internal view returns (uint256 a) {
        a = _price(l.price, id, false, l.nft, l.tokenId, 0);
        if (a < l.floor) a = l.floor;
    }

    /// @dev What the buyer pays: the price, never above maxPrice or the unspent budget.
    function _bidPrice(Bid memory b, uint256 id, uint256 tokenId, Order storage o) internal view returns (uint256 p) {
        p = _price(b.price, id, true, b.nft, tokenId, o.fills);
        if (p > b.maxPrice) p = b.maxPrice;
        uint256 left = b.budget - o.spent;
        if (p > left) p = left;
    }

    /// @dev Built-in linear prices round toward the order's owner: up for a seller's
    /// minimum, down for a buyer's payment.
    function _price(Price memory p, uint256 id, bool isBid, address nft, uint256 tokenId, uint256 fills)
        internal
        view
        returns (uint256)
    {
        if (p.strategy != address(0)) {
            (bool ok, bytes memory ret) = p.strategy.staticcall{gas: STRATEGY_GAS}(
                abi.encodeCall(IPricingStrategy.price, (id, isBid, nft, tokenId, fills, p.data))
            );
            if (!ok || ret.length != 32) revert StrategyFailed();
            return abi.decode(ret, (uint256));
        }
        if (block.timestamp >= p.endTime) return p.end;
        if (block.timestamp <= p.startTime) return p.start;
        uint256 duration = p.endTime - p.startTime;
        uint256 elapsed = block.timestamp - p.startTime;
        uint256 total = uint256(p.start) * (duration - elapsed) + uint256(p.end) * elapsed;
        return isBid ? total / duration : (total + duration - 1) / duration;
    }

    /// @dev Split a sale price. Fees round down, in the seller's favor.
    function _quote(address nft, uint256 tokenId, uint256 price, uint256 executorBps)
        internal
        view
        returns (Quote memory q)
    {
        q.price = price;
        (q.royaltyRecipient, q.royalty) = _royalty(nft, tokenId, price);
        q.protocolFee = price * PROTOCOL_FEE_BPS / BPS;
        q.executorFee = price * executorBps / BPS;
        uint256 cost = q.royalty + q.protocolFee + q.executorFee;
        if (cost > price) revert Incompatible();
        q.proceeds = price - cost;
    }

    /// @dev Smallest found price whose proceeds cover the ask. Two steps suffice for a
    /// proportional royalty; a royalty that is not proportional gets four.
    function _buyQuote(Listing calldata l, uint256 id) internal view returns (Quote memory q) {
        uint256 target = _ask(l, id);
        uint256 p = target;
        for (uint256 i; i < 4; i++) {
            q = _quote(l.nft, l.tokenId, p, 0);
            if (q.proceeds >= target) return q;
            if (q.proceeds == 0) break;
            p = (target * p + q.proceeds - 1) / q.proceeds;
        }
        revert Incompatible();
    }

    /// @dev ERC-2981 only, read with a gas limit. Anything malformed means no royalty.
    function _royalty(address nft, uint256 tokenId, uint256 price) internal view returns (address, uint256) {
        if (price == 0 || !_supports(nft, 0x2a55205a)) return (address(0), 0);
        (bool ok, bytes memory ret) =
            nft.staticcall{gas: ROYALTY_GAS}(abi.encodeWithSelector(0x2a55205a, tokenId, price));
        if (!ok || ret.length < 64) return (address(0), 0);
        (uint256 who, uint256 amount) = abi.decode(ret, (uint256, uint256));
        if (who == 0 || who > type(uint160).max || address(uint160(who)) == address(this) || amount == 0) {
            return (address(0), 0);
        }
        return (address(uint160(who)), amount);
    }

    function _supports(address target, bytes4 interfaceId) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            target.staticcall{gas: ERC165_GAS}(abi.encodeWithSelector(0x01ffc9a7, interfaceId));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) == 1;
    }

    /// @dev Best effort: a reverting or gas-hungry observer cannot undo the sale. The
    /// caller must forward enough gas for the full allowance, so an executor cannot
    /// starve the call on purpose.
    function _notify(address nft, uint256 tokenId, address seller, address buyer, address currency, uint256 price)
        internal
    {
        if (!_supports(nft, ISaleObserver.onMarketSale.selector)) return;
        if (gasleft() < CALLBACK_GAS * 64 / 63 + 5_000) revert CallbackGas();
        bytes memory data = abi.encodeCall(ISaleObserver.onMarketSale, (tokenId, seller, buyer, currency, price));
        uint256 limit = CALLBACK_GAS;
        assembly ("memory-safe") {
            pop(call(limit, nft, 0, add(data, 32), mload(data), 0, 0))
        }
    }

    /// @dev Fill `offer` with Market as fulfiller. Market pays the offer's currency
    /// consideration items, so it approves exactly their maximum and only this token.
    /// Returns the NFT's new owner, Market's net currency gain (reverts on a loss, so
    /// other users' escrow cannot fund the fill) and the bidder's currency decrease.
    function _fulfill(
        address nft,
        uint256 tokenId,
        address currency,
        AdvancedOrder calldata offer,
        CriteriaResolver[] calldata resolvers
    ) internal returns (address buyer, uint256 gained, uint256 paid) {
        uint256 owed;
        ConsiderationItem[] calldata c = offer.parameters.consideration;
        for (uint256 i; i < c.length; i++) {
            if (c[i].itemType == ItemType.ERC20 && c[i].token == currency) {
                owed += c[i].startAmount > c[i].endAmount ? c[i].startAmount : c[i].endAmount;
            }
        }
        IERC721(nft).approve(address(SEAPORT), tokenId);
        if (owed != 0) _approve(currency, owed);
        address bidder = offer.parameters.offerer;
        uint256 marketBefore = _balance(currency, address(this));
        uint256 bidderBefore = _balance(currency, bidder);

        SEAPORT.fulfillAdvancedOrder(offer, resolvers, bytes32(0), address(this));

        buyer = IERC721(nft).ownerOf(tokenId);
        if (buyer == address(this)) revert NftNotDelivered();
        if (owed != 0) _approve(currency, 0);
        gained = _balance(currency, address(this)) - marketBefore;
        paid = bidderBefore - _balance(currency, bidder);
    }

    function _deliver(address nft, uint256 tokenId, address to) internal {
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }

    /// @dev Pay out a sale whose funds are already in Market.
    function _pay(address currency, Quote memory q, address seller, address executor, address referrer) internal {
        _send(currency, seller, q.proceeds);
        _send(currency, q.royaltyRecipient, q.royalty);
        _send(currency, executor, q.executorFee);
        uint256 referral = referrer == address(0) ? 0 : q.price * REFERRAL_FEE_BPS / BPS;
        _send(currency, referrer, referral);
        _send(currency, PROTOCOL_FEE_RECIPIENT, q.protocolFee - referral);
    }

    /// @dev Take `amount` from the caller: ETH wrapped to WETH (excess refunded as WETH),
    /// or the currency itself. Tokens that deliver less than `amount` are rejected.
    function _collect(address currency, uint256 amount) internal {
        if (msg.value != 0) {
            if (currency != WETH || msg.value < amount) revert PaymentFailed();
            IWETH(WETH).deposit{value: msg.value}();
            _send(WETH, msg.sender, msg.value - amount);
            return;
        }
        uint256 before = _balance(currency, address(this));
        _call(currency, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));
        if (_balance(currency, address(this)) - before != amount) revert PaymentFailed();
    }

    function _send(address currency, address to, uint256 amount) internal {
        if (amount != 0) _call(currency, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _approve(address currency, uint256 amount) internal {
        _call(currency, abi.encodeWithSelector(0x095ea7b3, address(SEAPORT), amount));
    }

    /// @dev ERC20 call that accepts tokens returning nothing or true.
    function _call(address token, bytes memory data) internal {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length == 0 ? token.code.length == 0 : !abi.decode(ret, (bool)))) revert PaymentFailed();
    }

    function _balance(address token, address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }
}
