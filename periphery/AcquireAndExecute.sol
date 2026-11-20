// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, Order, OrderState} from "../src/Order.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";

/// @title AcquireAndExecute
/// @notice Buys an Actions token listed through ExchangeAction and, in the same call, executes
/// its CoveredNFTPurchase order to deliver the NFT to `recipient`. This contract receives the
/// token and executes as its owner; the underlying order records this contract as its actor.
/// The premium and execution price come only from this call's ETH; the unused part goes to
/// `refundTo`. Any failed step reverts everything. ETH held here before the call is never spent
/// or returned.
contract AcquireAndExecute {
    struct Params {
        Order listing;
        Order account;
        IERC721 nft;
        uint256 tokenId;
        uint256 executionPrice;
        bytes32 activationTermsHash;
        uint256 maxPremium;
        uint256 maxTotal;
        address recipient;
        address refundTo;
        /// Exclusive.
        uint256 deadline;
    }

    Market public immutable market;
    Actions public immutable actions;
    ExchangeAction public immutable exchange;
    CoveredNFTPurchase public immutable covered;

    bool private transient _entered;

    event AcquiredAndExecuted(
        address indexed payer,
        address indexed recipient,
        address indexed account,
        address listing,
        uint256 premium,
        uint256 executionPrice
    );

    error Reentrant();
    error DeadlinePassed();
    error Mismatch();
    error PriceAboveLimit(uint256 premium, uint256 total);
    error RefundFailed();
    error NotDelivered();

    constructor(Market market_, ExchangeAction exchange_, CoveredNFTPurchase covered_) {
        market = market_;
        actions = market_.actions();
        exchange = exchange_;
        covered = covered_;
    }

    function acquireAndExecute(Params calldata p) external payable {
        if (_entered) revert Reentrant();
        _entered = true;
        if (block.timestamp >= p.deadline) revert DeadlinePassed();
        if (p.recipient == address(0) || p.refundTo == address(0)) revert Mismatch();
        uint256 held = address(this).balance - msg.value;
        _checkAccount(p);
        uint256 premium = _checkListing(p);
        uint256 total = premium + p.executionPrice;
        if (premium > p.maxPremium || total > p.maxTotal || total > msg.value) revert PriceAboveLimit(premium, total);

        p.listing.execute{value: premium}(abi.encode(address(this), premium, uint64(0)));
        p.account.execute{value: p.executionPrice}(abi.encode(p.recipient));

        if (p.account.state() != OrderState.Completed || p.nft.ownerOf(p.tokenId) != p.recipient) {
            revert NotDelivered();
        }
        uint256 refund = msg.value - total;
        if (refund != 0) {
            (bool ok,) = p.refundTo.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
        if (address(this).balance != held) revert Mismatch();
        _entered = false;
        emit AcquiredAndExecuted(msg.sender, p.recipient, address(p.account), address(p.listing), premium, p.executionPrice);
    }

    function _checkAccount(Params calldata p) private view {
        Order a = p.account;
        if (!market.isOrder(address(a)) || a.action() != address(covered) || a.admission() != Admission.Holder) {
            revert Mismatch();
        }
        if (a.actionCodehash() != address(covered).codehash || !a.isLive()) revert Mismatch();
        if (keccak256(a.activationTerms()) != p.activationTermsHash) revert Mismatch();
        CoveredNFTPurchase.Config memory c = abi.decode(a.config(), (CoveredNFTPurchase.Config));
        if (c.nft != p.nft || c.tokenId != p.tokenId || c.price != p.executionPrice) revert Mismatch();
        if (p.nft.ownerOf(p.tokenId) != address(a)) revert Mismatch();
    }

    function _checkListing(Params calldata p) private view returns (uint256) {
        Order l = p.listing;
        if (!market.isOrder(address(l)) || l.action() != address(exchange) || l.actionCodehash() != address(exchange).codehash)
        {
            revert Mismatch();
        }
        if (!l.isLive()) revert Mismatch();
        ExchangeAction.Config memory c = abi.decode(l.config(), (ExchangeAction.Config));
        if (c.side != ExchangeAction.Side.Sale || address(c.nft) != address(actions)) revert Mismatch();
        if (abi.decode(c.terms, (ExchangeAction.SaleTerms)).tokenId != uint256(uint160(address(p.account)))) {
            revert Mismatch();
        }
        if (actions.ownerOf(uint256(uint160(address(p.account)))) != address(l)) revert Mismatch();
        return exchange.quote(l, "").price;
    }
}
