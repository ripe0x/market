// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Market} from "../src/Market.sol";
import {Admission, Order} from "../src/Order.sol";
import {ActionBase} from "./ActionBase.sol";

/// @title CoveredNFTPurchase
/// @notice A Holder order that lets its token's owner buy one escrowed ordinary ERC721 for a
/// fixed ETH price. The order holds the NFT before activation. Activation snapshots the ERC2981
/// royalty recipient and amount for that price, within the issuer's cap. Execution takes the
/// exact price, delivers the NFT and credits the royalty and proceeds, which the beneficiaries
/// withdraw from the order. No trading fee applies. A price of zero is allowed.
///
/// Surrender and expiry charge no royalty. The residual beneficiary, which must be the issuer,
/// recovers the NFT through Order.release. An issuer that holds the token can surrender it and
/// recover the NFT. Address checks do not establish beneficial ownership, and how a resale
/// premium relates to the execution price is not a royalty guarantee.
contract CoveredNFTPurchase is ActionBase {
    struct Config {
        IERC721 nft;
        uint256 tokenId;
        uint256 price;
        address proceedsTo;
        uint16 maxRoyaltyBps;
    }

    event Purchased(
        address indexed order, address indexed actor, address indexed recipient, uint256 price, uint256 royalty
    );

    error Unsupported();
    error InvalidConfig();
    error NotCovered();
    error RoyaltyAboveLimit();
    error WrongPayment(uint256 expected, uint256 actual);
    error BadRecipient();
    error NotDelivered();

    constructor(Market market_) ActionBase(market_) {}

    /// @return abi.encode(address royaltyTo, uint256 royalty), fixed for the order's life.
    function validate(address order, bytes calldata config) external view returns (bytes memory) {
        Order o = _validating(order);
        if (o.admission() != Admission.Holder || o.residual() != o.issuer()) revert Unsupported();
        Config memory c = abi.decode(config, (Config));
        if (address(c.nft) == address(market.actions())) revert Unsupported();
        if (c.proceedsTo == address(0) || c.maxRoyaltyBps > 10_000) revert InvalidConfig();
        if (c.nft.ownerOf(c.tokenId) != order) revert NotCovered();
        address royaltyTo;
        uint256 royalty;
        if (ERC165Checker.supportsInterface(address(c.nft), type(IERC2981).interfaceId)) {
            (royaltyTo, royalty) = IERC2981(address(c.nft)).royaltyInfo(c.tokenId, c.price);
        }
        if (royalty > Math.mulDiv(c.price, c.maxRoyaltyBps, 10_000) || (royalty != 0 && royaltyTo == address(0))) {
            revert RoyaltyAboveLimit();
        }
        return abi.encode(royaltyTo, royalty);
    }

    /// @param input abi.encode(address recipient). Exactly `price` ETH must be supplied.
    function onExecute(
        address actor,
        uint256 value,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bool, bytes memory) {
        Order o = _executing(actor, value, config, terms);
        Config memory c = abi.decode(config, (Config));
        (address royaltyTo, uint256 royalty) = abi.decode(terms, (address, uint256));
        address recipient = abi.decode(input, (address));
        if (value != c.price) revert WrongPayment(c.price, value);
        if (recipient == address(0) || recipient == address(o)) revert BadRecipient();
        _deliver(o, c, recipient);
        if (royalty != 0) o.credit(royaltyTo, royalty);
        if (c.price > royalty) o.credit(c.proceedsTo, c.price - royalty);
        emit Purchased(address(o), actor, recipient, c.price, royalty);
        return (true, "");
    }

    /// @notice The residual beneficiary takes the NFT back once the order is Pending or ended.
    /// Activation policy is not rechecked, so a rejected setup stays recoverable.
    function onRelease(address actor, address recipient, bytes calldata config, bytes calldata terms, bytes calldata)
        external
        returns (bytes memory)
    {
        Order o = _releasing(actor, recipient, config, terms);
        if (actor != o.residual()) revert NotAuthorized();
        _deliver(o, abi.decode(config, (Config)), recipient);
        return "";
    }

    function _deliver(Order o, Config memory c, address to) private {
        if (c.nft.ownerOf(c.tokenId) != address(o)) revert NotCovered();
        o.call(address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (address(o), to, c.tokenId)));
        if (c.nft.ownerOf(c.tokenId) != to) revert NotDelivered();
    }
}
