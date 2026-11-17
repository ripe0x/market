// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {Artwork} from "../examples/Artwork.sol";
import {ReservedPaint} from "../examples/ReservedPaint.sol";
import {RoyaltyNFT, Rejecter} from "./utils/Mocks.sol";

contract RightExamplesTest is Test {
    Market market;
    Rights rights;
    CoveredNFTPurchase purchase;
    ReservedPaint paint;
    address issuer = makeAddr("issuer");
    address buyer = makeAddr("buyer");
    address reseller = makeAddr("reseller");
    uint256 constant DEADLINE = 1_100_000;

    function setUp() public {
        vm.warp(1_000_000);
        market = new Market();
        rights = market.rights();
        purchase = new CoveredNFTPurchase(market);
        paint = new ReservedPaint(market);
        vm.deal(buyer, 10 ether);
    }

    function test_coveredNFTCommitsRoyaltyAndCreditsWithoutRecipientCallback() public {
        RoyaltyNFT nft = new RoyaltyNFT();
        Rejecter royaltyTo = new Rejecter();
        nft.mint(issuer, 7);
        nft.setRoyalty(address(royaltyTo), 500);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 7, 1 ether, issuer, 500));
        vm.prank(issuer);
        Right right = market.createRight(purchase, config, DEADLINE, issuer, bytes32(uint256(1)));
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), 7);
        vm.prank(issuer);
        right.activate(config);
        assertEq(right.activationTerms(), abi.encode(address(royaltyTo), 0.05 ether));

        uint256 id = right.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, reseller, id);
        vm.prank(reseller);
        rights.transferFrom(reseller, buyer, id);
        nft.setRoyalty(makeAddr("changed royalty"), 10_000);

        vm.prank(buyer);
        right.exercise{value: 1 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(7), buyer);
        assertEq(uint256(right.state()), uint256(Right.State.Exercised));
        assertEq(right.creditOf(address(royaltyTo)), 0.05 ether);
        assertEq(right.creditOf(issuer), 0.95 ether);
        assertEq(right.totalCredits(), 1 ether);
        assertEq(address(right).balance, 1 ether);
        vm.prank(issuer);
        right.withdrawCredit(payable(issuer));
        assertEq(issuer.balance, 0.95 ether);
        assertEq(right.totalCredits(), 0.05 ether);
        assertEq(address(right).balance, 0.05 ether);
        assertEq(address(royaltyTo).balance, 0, "receiver has no callable withdrawal path");
        vm.prank(issuer);
        vm.expectRevert(Right.EncumberedBalance.selector);
        right.recover(issuer, 1, "");
    }

    function test_coveredPurchaseRejectsNonIssuerResidualAtActivation() public {
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.mint(issuer, 9);
        nft.setRoyalty(makeAddr("royalty"), 500);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 9, 1 ether, issuer, 500));
        vm.prank(issuer);
        Right right = market.createRight(purchase, config, DEADLINE, buyer, bytes32(uint256(9)));
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), 9);
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.ResidualNotIssuer.selector);
        right.activate(config);
        assertEq(uint256(right.state()), uint256(Right.State.Pending));
        uint256 id = right.tokenId();
        vm.expectRevert();
        rights.ownerOf(id);
        vm.warp(DEADLINE);
        vm.prank(reseller);
        right.finalizeExpiry();
        vm.prank(buyer);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), buyer, 9)));
        assertEq(nft.ownerOf(9), buyer, "pending residual remains committed despite failed activation");
        assertEq(right.totalCredits(), 0);
    }

    function _covered(uint256 tokenId) internal returns (RoyaltyNFT nft, Right right, bytes memory config) {
        nft = new RoyaltyNFT();
        nft.mint(issuer, tokenId);
        nft.setRoyalty(makeAddr("royalty"), 500);
        config = abi.encode(CoveredNFTPurchase.Config(nft, tokenId, 1 ether, issuer, 500));
        vm.prank(issuer);
        right = market.createRight(purchase, config, DEADLINE, issuer, bytes32(tokenId));
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), tokenId);
        vm.prank(issuer);
        right.activate(config);
    }

    function test_buyerSurrenderReleasesCollateralOnlyToIssuer() public {
        (RoyaltyNFT nft, Right right,) = _covered(10);
        uint256 id = right.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.prank(buyer);
        right.surrender();
        vm.prank(buyer);
        vm.expectRevert(Right.Unauthorized.selector);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), buyer, 10)));
        vm.prank(issuer);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), issuer, 10)));
        assertEq(nft.ownerOf(10), issuer);
        assertEq(right.totalCredits(), 0, "surrender is not an exercise royalty event");
        assertEq(buyer.balance, 10 ether);
    }

    function test_buyerExpiryReleasesCollateralOnlyToIssuer() public {
        (RoyaltyNFT nft, Right right, bytes memory config) = _covered(11);
        uint256 id = right.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.warp(DEADLINE);
        vm.prank(buyer);
        vm.expectRevert(Right.DeadlinePassed.selector);
        right.exercise{value: 1 ether}(config, abi.encode(buyer));
        vm.prank(reseller);
        right.finalizeExpiry();
        vm.prank(buyer);
        vm.expectRevert(Right.Unauthorized.selector);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), buyer, 11)));
        vm.prank(issuer);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), issuer, 11)));
        assertEq(nft.ownerOf(11), issuer);
        assertEq(right.totalCredits(), 0, "expiry is not an exercise royalty event");
        assertEq(buyer.balance, 10 ether);
    }

    function test_issuerSurrendersUnsoldRightAndRecoversCollateral() public {
        (RoyaltyNFT nft, Right right,) = _covered(12);
        vm.prank(issuer);
        right.surrender();
        vm.prank(issuer);
        right.recover(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(right), issuer, 12)));
        assertEq(nft.ownerOf(12), issuer);
        assertEq(right.totalCredits(), 0);
    }

    function test_coveredNFTRequiresActualCollateralAndExactPayment() public {
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.mint(issuer, 8);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 8, 1 ether, issuer, 0));
        vm.prank(issuer);
        Right right = market.createRight(purchase, config, DEADLINE, issuer, bytes32(uint256(2)));
        vm.prank(issuer);
        vm.expectRevert(CoveredNFTPurchase.NotCovered.selector);
        right.activate(config);
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), 8);
        vm.prank(issuer);
        right.activate(config);
        vm.deal(issuer, 1 ether);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CoveredNFTPurchase.WrongPayment.selector, 1 ether, 0.9 ether));
        right.exercise{value: 0.9 ether}(config, abi.encode(issuer));
        assertEq(nft.ownerOf(8), address(right));
        assertEq(uint256(right.state()), uint256(Right.State.Active));
        assertEq(right.totalCredits(), 0);
    }

    function test_handlersRejectDirectCalls() public {
        vm.expectRevert(CoveredNFTPurchase.NotRight.selector);
        purchase.onExercise(issuer, 1 ether, "", "", "");
        vm.expectRevert(ReservedPaint.NotRight.selector);
        paint.validate(address(this), "");
    }

    function test_reservedArtworkSurvivesArtTransferAndCannotBeReplaced() public {
        vm.startPrank(issuer);
        Artwork art = new Artwork();
        art.mint(issuer, 3);
        bytes memory config = abi.encode(ReservedPaint.Config(art, 3, (1 << 2) | (1 << 9)));
        Right right = market.createRight(paint, config, DEADLINE, issuer, bytes32(uint256(3)));
        art.reserve(3, right, (1 << 2) | (1 << 9));
        right.activate(config);
        rights.transferFrom(issuer, buyer, right.tokenId());
        art.transferFrom(issuer, reseller, 3);
        vm.stopPrank();

        vm.prank(reseller);
        vm.expectRevert(Artwork.ReservationLive.selector);
        art.reserve(3, right, 1 << 4);
        vm.prank(reseller);
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.paintReserved(3, 2);

        vm.prank(buyer);
        right.exercise(config, abi.encode(uint8(9)));
        assertEq(art.colorOf(3), 9);
        assertEq(art.ownerOf(3), reseller);
        assertEq(uint256(right.state()), uint256(Right.State.Exercised));
        (address reservationAccount,) = art.reservation(3);
        assertEq(reservationAccount, address(0));
        vm.prank(reseller);
        art.paint(3, 2); // The promise is one authorized change, not permanent visual control.
        assertEq(art.colorOf(3), 2);
    }

    function testFuzz_reservedArtworkOnlyAllowsCommittedColors(uint8 color) public {
        vm.startPrank(issuer);
        Artwork art = new Artwork();
        art.mint(issuer, 4);
        uint256 allowed = (1 << 2) | (1 << 9);
        bytes memory config = abi.encode(ReservedPaint.Config(art, 4, allowed));
        Right right = market.createRight(paint, config, DEADLINE, issuer, bytes32(uint256(4)));
        art.reserve(4, right, allowed);
        right.activate(config);
        rights.transferFrom(issuer, buyer, right.tokenId());
        vm.stopPrank();

        bool valid = (allowed >> color) & 1 == 1;
        vm.prank(buyer);
        if (!valid) vm.expectRevert(abi.encodeWithSelector(ReservedPaint.ColorNotAllowed.selector, color));
        right.exercise(config, abi.encode(color));
        assertEq(art.colorOf(4), valid ? color : 0);
        assertEq(uint256(right.state()), uint256(valid ? Right.State.Exercised : Right.State.Active));
        assertEq(rights.isLive(right.tokenId()), !valid);
    }

    function test_surrenderDisablesReservedArtworkEvenForResidualBeneficiary() public {
        vm.startPrank(issuer);
        Artwork art = new Artwork();
        art.mint(issuer, 5);
        bytes memory config = abi.encode(ReservedPaint.Config(art, 5, 1 << 2));
        Right right = market.createRight(paint, config, DEADLINE, issuer, bytes32(uint256(5)));
        art.reserve(5, right, 1 << 2);
        right.activate(config);
        rights.transferFrom(issuer, buyer, right.tokenId());
        vm.stopPrank();
        vm.prank(buyer);
        right.surrender();
        vm.prank(issuer);
        vm.expectRevert(Artwork.NotAllowed.selector);
        right.recover(address(art), 0, abi.encodeCall(Artwork.paintReserved, (5, 2)));
        assertEq(art.colorOf(5), 0);
        vm.prank(issuer);
        Right next = market.createRight(
            paint, abi.encode(ReservedPaint.Config(art, 5, 1 << 3)), DEADLINE, issuer, bytes32(uint256(6))
        );
        vm.prank(issuer);
        art.reserve(5, next, 1 << 3); // A dead reservation no longer blocks the owner.
    }
}
