// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    OfferItem,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Zone and sole fulfiller for declining-price Seaport listings.
///
/// A seller signs an ordinary Seaport 1.6 listing: one ERC721 offered, one WETH
/// consideration to the seller declining from start to floor, FULL_RESTRICTED,
/// zone = this contract. Seaport skips the zone check only when the caller is the
/// zone, and this contract implements no zone interface, so every fill of such a
/// listing goes through `buy` or `matchOffer`.
///
/// Invariants:
/// - The seller always receives at least the listing's current Seaport amount;
///   Seaport enforces it, not this contract.
/// - On a match, every WETH unit the offer releases beyond its own mandatory
///   consideration and the seller's amount lands here and is paid out in the same
///   call: fees to the executor and protocol, the rest to the seller.
/// - Users grant this contract no approvals. Its own calls leave no WETH, ETH or
///   NFT behind. WETH sent here directly is paid to the next matched seller as
///   surplus (fees apply); nothing else can withdraw it. Its max WETH approval to
///   Seaport is only usable while this contract is the Seaport caller, because it
///   signs no orders.
/// - No owner, no upgrade, no pause. Fees are constants of this deployment and are
///   bound into every listing through the signed zone address.
contract Market {
    ConsiderationInterface public constant SEAPORT =
        ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint256 public constant EXECUTOR_FEE_BPS = 30;
    uint256 public constant PROTOCOL_FEE_BPS = 20;
    uint256 internal constant BPS = 10_000;

    address public immutable PROTOCOL_FEE_RECIPIENT;

    bool transient locked;

    event Sale(
        address indexed seller,
        address indexed buyer,
        address indexed nft,
        uint256 tokenId,
        uint256 sellerProceeds,
        uint256 executorFee,
        uint256 protocolFee
    );

    error Locked();
    error NotListing();
    error NotWethOffer();
    error InsufficientPayment();
    error NftNotDelivered();

    modifier lock() {
        if (locked) revert Locked();
        locked = true;
        _;
        locked = false;
    }

    constructor(address protocolFeeRecipient) {
        PROTOCOL_FEE_RECIPIENT = protocolFeeRecipient;
        WETH.approve(address(SEAPORT), type(uint256).max);
    }

    /// @notice Buy a listing with ETH at its current price plus the protocol fee.
    /// Send at least `currentPrice * (1 + PROTOCOL_FEE_BPS / BPS)`. The price only
    /// falls, so a quote from an earlier block overpays slightly; the excess is
    /// returned as WETH, which never calls into the buyer's address.
    function buy(AdvancedOrder calldata listing) external payable lock {
        (address nft, uint256 tokenId, uint256 price) = _listing(listing.parameters);
        uint256 protocolFee = price * PROTOCOL_FEE_BPS / BPS;
        uint256 total = price + protocolFee;
        if (msg.value < total) revert InsufficientPayment();

        WETH.deposit{value: msg.value}();
        // This contract is the fulfiller: Seaport pulls `price` WETH from here to
        // the seller and sends the NFT to the buyer.
        SEAPORT.fulfillAdvancedOrder(listing, new CriteriaResolver[](0), bytes32(0), msg.sender);
        WETH.transfer(PROTOCOL_FEE_RECIPIENT, protocolFee);
        if (msg.value > total) WETH.transfer(msg.sender, msg.value - total);

        emit Sale(listing.parameters.offerer, msg.sender, nft, tokenId, price, 0, protocolFee);
    }

    /// @notice Sell a listing into a Seaport offer that pays in WETH, such as an
    /// OpenSea item or collection offer. Anyone may call. The caller earns the
    /// executor fee and supplies the offer's zone extraData, criteria resolvers and
    /// fulfillments for orders [listing, offer]. Seaport sends unspent offer WETH
    /// here; it is split before returning.
    function matchOffer(
        AdvancedOrder calldata listing,
        AdvancedOrder calldata offer,
        CriteriaResolver[] calldata criteriaResolvers,
        Fulfillment[] calldata fulfillments
    ) external lock {
        (,, uint256 price) = _listing(listing.parameters);
        OfferItem[] calldata offered = offer.parameters.offer;
        if (offered.length != 1 || offered[0].itemType != ItemType.ERC20 || offered[0].token != address(WETH)) {
            revert NotWethOffer();
        }

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = listing;
        orders[1] = offer;
        SEAPORT.matchAdvancedOrders(orders, criteriaResolvers, fulfillments, address(this));

        _settle(listing.parameters, offer.parameters.offerer, price);
    }

    /// @dev Fees are charged on everything the offer released to the seller side:
    /// the seller's Seaport amount plus the surplus held here. Rounding favors the seller.
    function _settle(OrderParameters calldata p, address buyer, uint256 price) internal {
        address nft = p.offer[0].token;
        uint256 tokenId = p.offer[0].identifierOrCriteria;
        // Fulfillments that leave the NFT unspent would send it here.
        if (IERC721(nft).ownerOf(tokenId) == address(this)) revert NftNotDelivered();

        uint256 surplus = WETH.balanceOf(address(this));
        uint256 executorFee = (price + surplus) * EXECUTOR_FEE_BPS / BPS;
        uint256 protocolFee = (price + surplus) * PROTOCOL_FEE_BPS / BPS;
        // Reverts when the offer does not cover the seller's amount plus fees.
        uint256 sellerExtra = surplus - executorFee - protocolFee;

        if (sellerExtra != 0) WETH.transfer(p.consideration[0].recipient, sellerExtra);
        if (executorFee != 0) WETH.transfer(msg.sender, executorFee);
        if (protocolFee != 0) WETH.transfer(PROTOCOL_FEE_RECIPIENT, protocolFee);
        emit Sale(p.offerer, buyer, nft, tokenId, price + sellerExtra, executorFee, protocolFee);
    }

    /// @notice The listing's current seller amount, exactly as Seaport computes it.
    function currentPrice(OrderParameters calldata p) external view returns (uint256 price) {
        (,, price) = _listing(p);
    }

    /// @dev Accepts only the listing shape this product signs and returns the
    /// seller's current WETH amount. Reverts outside [startTime, endTime).
    function _listing(OrderParameters calldata p) internal view returns (address nft, uint256 tokenId, uint256 price) {
        if (
            p.zone != address(this) || p.orderType != OrderType.FULL_RESTRICTED || p.offer.length != 1
                || p.offer[0].itemType != ItemType.ERC721 || p.consideration.length != 1
                || p.consideration[0].itemType != ItemType.ERC20 || p.consideration[0].token != address(WETH)
                || p.consideration[0].recipient == address(this)
        ) revert NotListing();
        if (block.timestamp < p.startTime || block.timestamp >= p.endTime) revert NotListing();

        ConsiderationItem calldata c = p.consideration[0];
        price = c.endAmount;
        if (c.startAmount != c.endAmount) {
            // Seaport's AmountDeriver, rounding up as it does for consideration.
            uint256 duration = p.endTime - p.startTime;
            uint256 elapsed = block.timestamp - p.startTime;
            uint256 total = c.startAmount * (duration - elapsed) + c.endAmount * elapsed;
            price = total == 0 ? 0 : (total - 1) / duration + 1;
        }
        return (p.offer[0].token, p.offer[0].identifierOrCriteria, price);
    }
}
