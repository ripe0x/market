// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {ActionBase} from "../actions/ActionBase.sol";

/// Exact-receipt tests for CoveredNFTPurchase: a Holder order escrowing one ordinary ERC721,
/// sold for a fixed ETH price with the ERC2981 royalty snapshotted at activation. Residual
/// recovery, credit survival and resale through ExchangeAction are all asserted with absolute
/// amounts.
contract CoveredTest is Base {
    address proceeds = makeAddr("proceeds");

    // ---- helpers ----

    /// Issue + escrow + activate a covered Holder order over `token` id, held by issuer.
    function _covered(
        IERC721 token,
        uint256 id,
        uint256 price,
        address proceedsTo,
        uint16 maxBps,
        uint64 deadline
    ) internal returns (Order o) {
        bytes memory cfg = abi.encode(CoveredNFTPurchase.Config(token, id, price, proceedsTo, maxBps));
        OrderSpec memory spec = _spec(address(covered), Admission.Holder, deadline, issuer, cfg);
        o = _create(issuer, spec, 0);
        vm.startPrank(issuer);
        token.transferFrom(issuer, address(o), id);
        o.activate();
        vm.stopPrank();
    }

    /// Create (but do not activate) a covered Holder order and escrow `token` id into it.
    function _coveredPending(IERC721 token, uint256 id, uint256 price, uint16 maxBps)
        internal
        returns (Order o)
    {
        bytes memory cfg = abi.encode(CoveredNFTPurchase.Config(token, id, price, issuer, maxBps));
        OrderSpec memory spec = _spec(address(covered), Admission.Holder, 0, issuer, cfg);
        o = _create(issuer, spec, 0);
        vm.prank(issuer);
        token.transferFrom(issuer, address(o), id);
    }

    // ---- 1. resale premium vs execution proceeds vs royalty ----

    function test_resalePremiumExecutionRoyaltyExact() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 500); // 5%
        Order account = _covered(IERC721(address(rnft)), 1, 10 ether, proceeds, 1000, 0);
        assertEq(actions.ownerOf(_id(account)), issuer);

        // Resale of the Actions token through an ExchangeAction fixed sale at 3 ether premium.
        Order listing = _listToken(issuer, address(actions), _id(account), _fixed(3 ether), 0);
        uint256 issuerBefore = issuer.balance;
        vm.prank(buyer);
        listing.execute{value: 3 ether}(abi.encode(buyer, 3 ether, uint64(0)));
        // Premium split: 1% fee to treasury, remainder to the listing seller (issuer).
        assertEq(treasury.balance, 0.03 ether, "premium fee");
        assertEq(issuer.balance, issuerBefore + 2.97 ether, "premium proceeds");
        assertEq(actions.ownerOf(_id(account)), buyer, "token to buyer");

        // Execution at the exact covered price.
        vm.prank(buyer);
        account.execute{value: 10 ether}(abi.encode(buyer));
        assertEq(rnft.ownerOf(1), buyer, "nft delivered");
        assertEq(uint8(account.state()), uint8(OrderState.Completed));

        // Royalty and proceeds credited exactly; covered charges no trading fee.
        assertEq(account.creditOf(creator), 0.5 ether, "royalty credit");
        assertEq(account.creditOf(proceeds), 9.5 ether, "proceeds credit = price - royalty");
        assertEq(account.totalCredits(), 10 ether);

        account.releaseCredit(creator);
        account.releaseCredit(proceeds);
        assertEq(creator.balance, 0.5 ether);
        assertEq(proceeds.balance, 9.5 ether);
        assertEq(address(account).balance, 0, "order drained");
    }

    // ---- 2. zero execution price allowed ----

    function test_zeroPriceAllowed() public {
        nft.mint(issuer, 1);
        Order account = _covered(IERC721(address(nft)), 1, 0, proceeds, 10_000, 0);
        vm.prank(issuer);
        account.execute{value: 0}(abi.encode(buyer));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(uint8(account.state()), uint8(OrderState.Completed));
        assertEq(account.totalCredits(), 0, "no credit at price 0");
    }

    // ---- 3. wrong payment ----

    function test_wrongPaymentReverts() public {
        nft.mint(issuer, 1);
        Order account = _covered(IERC721(address(nft)), 1, 5 ether, proceeds, 10_000, 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CoveredNFTPurchase.WrongPayment.selector, 5 ether, 4 ether));
        account.execute{value: 4 ether}(abi.encode(buyer));
    }

    // ---- 4. zero / self recipient rejected ----

    function test_badRecipientRejected() public {
        nft.mint(issuer, 1);
        Order account = _covered(IERC721(address(nft)), 1, 1 ether, proceeds, 10_000, 0);
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.BadRecipient.selector);
        account.execute{value: 1 ether}(abi.encode(address(0)));
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.BadRecipient.selector);
        account.execute{value: 1 ether}(abi.encode(address(account)));
        // NFT still escrowed.
        assertEq(nft.ownerOf(1), address(account));
    }

    // ---- 5a. canonical Actions token as collateral: rejected at activation, recoverable ----

    function test_actionsCollateralRejectedButRecoverable() public {
        // A1: a normal live covered order; its Actions token is a real, transferable Actions token.
        nft.mint(issuer, 100);
        Order a1 = _covered(IERC721(address(nft)), 100, 1 ether, proceeds, 10_000, 0);
        uint256 t1 = _id(a1);

        // A2 escrows that Actions token as collateral.
        Order a2 = _coveredPending(IERC721(address(actions)), t1, 0, 0);
        assertEq(actions.ownerOf(t1), address(a2), "actions token escrowed");

        // Activation refuses canonical Actions collateral.
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.Unsupported.selector);
        a2.activate();
        assertEq(uint8(a2.state()), uint8(OrderState.Pending));

        // Residual recovers it from Pending while A1 is still live (token transferable).
        vm.prank(issuer);
        a2.release(issuer, "");
        assertEq(actions.ownerOf(t1), issuer, "collateral recovered");
    }

    // ---- 5b. ordinary NFT escrowed, activation rejected by too-high royalty, still recoverable ----

    function test_royaltyTooHighRejectedButRecoverable() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 1000); // 10%
        // maxBps 500 (5%): royalty 1 ether > limit 0.5 ether.
        Order account = _coveredPending(IERC721(address(rnft)), 1, 10 ether, 500);
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.RoyaltyAboveLimit.selector);
        account.activate();
        assertEq(uint8(account.state()), uint8(OrderState.Pending));
        // Residual recovers the ordinary NFT from Pending.
        vm.prank(issuer);
        account.release(issuer, "");
        assertEq(rnft.ownerOf(1), issuer);
    }

    // ---- 6. surrender and expiry charge no royalty; residual recovers NFT ----

    function test_surrenderNoRoyaltyRecover() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 500);
        Order account = _covered(IERC721(address(rnft)), 1, 10 ether, proceeds, 1000, 0);
        vm.prank(issuer); // issuer holds the token
        account.surrender();
        assertEq(uint8(account.state()), uint8(OrderState.Surrendered));
        assertEq(account.totalCredits(), 0, "surrender charges nothing");
        vm.prank(issuer);
        account.release(issuer, "");
        assertEq(rnft.ownerOf(1), issuer);
    }

    function test_expiryNoRoyaltyRecover() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 500);
        uint64 dl = uint64(T0 + 1 days);
        Order account = _covered(IERC721(address(rnft)), 1, 10 ether, proceeds, 1000, dl);
        vm.warp(dl);
        account.finalizeExpiry();
        assertEq(uint8(account.state()), uint8(OrderState.Expired));
        assertEq(account.totalCredits(), 0, "expiry charges nothing");
        vm.prank(issuer);
        account.release(issuer, "");
        assertEq(rnft.ownerOf(1), issuer);
    }

    // ---- 7. non-residual release cannot take collateral ----

    function test_nonResidualReleaseBlocked() public {
        nft.mint(issuer, 1);
        Order account = _covered(IERC721(address(nft)), 1, 1 ether, proceeds, 10_000, 0);
        vm.prank(issuer);
        account.surrender();
        // Stranger choosing itself: rejected by the order.
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        account.release(attacker, "");
        // Stranger routing to the residual: passes the order gate but the action refuses.
        vm.prank(attacker);
        vm.expectRevert(ActionBase.NotAuthorized.selector);
        account.release(issuer, "");
        assertEq(nft.ownerOf(1), address(account), "collateral retained");
    }

    // ---- 8. issuer buys the token back, surrenders and recovers ----

    function test_issuerBuysBackSurrenderRecover() public {
        nft.mint(issuer, 7);
        Order account = _covered(IERC721(address(nft)), 7, 2 ether, proceeds, 10_000, 0);
        // issuer sells the token to holder, then buys it back.
        vm.prank(issuer);
        actions.transferFrom(issuer, holder, _id(account));
        vm.prank(holder);
        actions.transferFrom(holder, issuer, _id(account));
        assertEq(actions.ownerOf(_id(account)), issuer);
        vm.prank(issuer);
        account.surrender();
        vm.prank(issuer);
        account.release(issuer, "");
        assertEq(nft.ownerOf(7), issuer);
    }

    // ---- 9. royalty snapshot unaffected by later royalty change ----

    function test_royaltySnapshotFrozen() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 500); // 5% at activation
        Order account = _covered(IERC721(address(rnft)), 1, 10 ether, proceeds, 1000, 0);
        // Collection raises royalty and changes recipient after activation.
        rnft.setRoyalty(attacker, 1000);
        vm.prank(issuer);
        account.execute{value: 10 ether}(abi.encode(buyer));
        assertEq(account.creditOf(creator), 0.5 ether, "frozen royalty recipient+amount");
        assertEq(account.creditOf(attacker), 0, "new recipient gets nothing");
        assertEq(account.creditOf(proceeds), 9.5 ether);
    }

    // ---- 10. credits survive termination; releaseCredit by stranger; withdrawCredit redirect ----

    function test_creditsSurviveStrangerReleaseAndRedirect() public {
        rnft.mint(issuer, 1);
        rnft.setRoyalty(creator, 500);
        Order account = _covered(IERC721(address(rnft)), 1, 10 ether, proceeds, 1000, 0);
        vm.prank(issuer);
        account.execute{value: 10 ether}(abi.encode(buyer));
        // Terminal (Completed), token burned, credits intact.
        assertEq(uint8(account.state()), uint8(OrderState.Completed));
        // A stranger may pay a beneficiary, destination fixed to the beneficiary.
        vm.prank(attacker);
        account.releaseCredit(creator);
        assertEq(creator.balance, 0.5 ether);
        // The beneficiary redirects its own credit elsewhere.
        address sink = makeAddr("sink");
        vm.prank(proceeds);
        account.withdrawCredit(sink);
        assertEq(sink.balance, 9.5 ether);
        assertEq(account.creditOf(proceeds), 0);
        assertEq(account.totalCredits(), 0);
    }

    // ---- 11. post-burn recovery using only onchain reads ----

    function test_postBurnRecoveryFromReads() public {
        nft.mint(issuer, 5);
        Order account = _covered(IERC721(address(nft)), 5, 1 ether, proceeds, 10_000, 0);
        vm.prank(issuer);
        account.surrender(); // burns the Actions token
        // Reconstruct recovery inputs purely from the order's code.
        CoveredNFTPurchase.Config memory c = abi.decode(account.config(), (CoveredNFTPurchase.Config));
        assertEq(address(c.nft), address(nft));
        assertEq(c.tokenId, 5);
        address r = account.residual();
        assertEq(r, issuer);
        vm.prank(r);
        account.release(r, "");
        assertEq(nft.ownerOf(5), issuer);
    }
}
