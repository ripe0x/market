// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Market} from "../src/Market.sol";
import {IExerciseHandler, Right} from "../src/Right.sol";

/// @notice One fully covered option to buy a particular NFT for a fixed ETH price. Resale
/// premiums are separate NFT trades; this handler only allocates the exercise payment.
contract CoveredNFTPurchase is IExerciseHandler {
    struct Config {
        IERC721 nft;
        uint256 tokenId;
        uint256 price;
        address proceedsTo;
        uint16 maxRoyaltyBps;
    }

    Market public immutable market;

    event Purchased(address indexed right, address indexed holder, address indexed recipient, uint256 price);

    error NotRight();
    error NotExercising();
    error NotCovered();
    error InvalidTerms();
    error WrongPayment(uint256 expected, uint256 actual);
    error NotDelivered();

    constructor(Market market_) {
        market = market_;
    }

    /// @dev Returned bytes are stored by the right at activation. Royalty lookup is never
    /// repeated at exercise, so later changes to the NFT's royalty settings cannot reprice it.
    function validate(address account, bytes calldata config) external view returns (bytes memory terms) {
        if (
            !market.isRight(account) || msg.sender != account
                || address(Right(payable(account)).handler()) != address(this)
        ) {
            revert NotRight();
        }
        Config memory c = abi.decode(config, (Config));
        if (c.proceedsTo == address(0) || c.maxRoyaltyBps > 10_000) revert InvalidTerms();
        if (c.nft.ownerOf(c.tokenId) != account) revert NotCovered();

        address royaltyTo;
        uint256 royalty;
        if (ERC165Checker.supportsInterface(address(c.nft), type(IERC2981).interfaceId)) {
            (royaltyTo, royalty) = IERC2981(address(c.nft)).royaltyInfo(c.tokenId, c.price);
        }
        if (
            royalty > c.price || royalty > Math.mulDiv(c.price, c.maxRoyaltyBps, 10_000)
                || (royalty != 0 && royaltyTo == address(0))
        ) revert InvalidTerms();
        return abi.encode(royaltyTo, royalty);
    }

    /// @param input ABI encoded recipient of the NFT. The holder supplies exactly `price` ETH.
    function onExercise(
        address holder,
        uint256 value,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bytes memory) {
        Right right = Right(payable(msg.sender));
        if (!market.isRight(msg.sender) || address(right.handler()) != address(this)) revert NotRight();
        if (!right.exercising()) revert NotExercising();
        Config memory c = abi.decode(config, (Config));
        (address royaltyTo, uint256 royalty) = abi.decode(terms, (address, uint256));
        address recipient = abi.decode(input, (address));
        if (value != c.price) revert WrongPayment(c.price, value);
        if (recipient == address(0) || recipient == msg.sender) revert InvalidTerms();
        if (c.nft.ownerOf(c.tokenId) != msg.sender) revert NotCovered();

        right.execute(address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (msg.sender, recipient, c.tokenId)));
        if (c.nft.ownerOf(c.tokenId) != recipient) revert NotDelivered();
        if (royalty != 0) right.credit(royaltyTo, royalty);
        if (c.price > royalty) right.credit(c.proceedsTo, c.price - royalty);
        emit Purchased(msg.sender, holder, recipient, c.price);
        return abi.encode(royaltyTo, royalty);
    }
}
