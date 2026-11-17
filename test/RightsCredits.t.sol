// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {RoyaltyNFT, Rejecter, Reenterer} from "./utils/Mocks.sol";

contract PassivePayee {
    receive() external payable {}
}

contract RedirectingPayee {
    function collect(Right right, address payable recipient) external {
        right.withdrawCredit(recipient);
    }
}

contract ReenteringPayee {
    Right public right;
    bool public recoverySucceeded;
    uint256 public receipts;

    function setRight(Right account) external {
        require(address(right) == address(0));
        right = account;
    }

    receive() external payable {
        receipts++;
        // Both paths see zero for our already-debited credit; neither may pay it twice.
        (bool released,) = address(right).call(abi.encodeWithSignature("releaseCredit(address)", address(this)));
        require(released);
        right.withdrawCredit(payable(address(this)));
        (recoverySucceeded,) = address(right).call(abi.encodeCall(Right.recover, (address(this), 0.95 ether, "")));
    }
}

contract RightsCreditsTest is Test {
    Market market;
    CoveredNFTPurchase purchase;
    RoyaltyNFT nft;
    address issuer = makeAddr("issuer");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    function setUp() public {
        market = new Market();
        purchase = new CoveredNFTPurchase(market);
        nft = new RoyaltyNFT();
        vm.deal(holder, 10 ether);
    }

    function _exercise(address payee) internal returns (Right right) {
        nft.mint(issuer, 1);
        nft.setRoyalty(payee, 500);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 1, 1 ether, issuer, 500));
        vm.prank(issuer);
        right = market.createRight(purchase, config, block.timestamp + 1 days, issuer, bytes32(uint256(1)));
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), 1);
        vm.prank(issuer);
        right.activate(config);
        uint256 id = right.tokenId();
        Rights rights = market.rights();
        vm.prank(issuer);
        rights.transferFrom(issuer, holder, id);
        vm.prank(holder);
        right.exercise{value: 1 ether}(config, abi.encode(holder));
        assertEq(nft.ownerOf(1), holder);
        assertEq(right.creditOf(payee), 0.05 ether);
        assertEq(right.creditOf(issuer), 0.95 ether);
    }

    function test_anyoneReleasesToPassiveBeneficiaryAfterResidualRecovery() public {
        PassivePayee payee = new PassivePayee();
        Right right = _exercise(address(payee));
        vm.deal(stranger, 0.1 ether);
        vm.prank(stranger);
        (bool funded,) = address(right).call{value: 0.1 ether}("");
        assertTrue(funded);
        vm.prank(issuer);
        right.recover(issuer, 0.1 ether, "");
        vm.prank(stranger);
        (bool ok,) = address(right).call(abi.encodeWithSignature("releaseCredit(address)", address(payee)));
        assertTrue(ok, "third party must release payment to accepting beneficiary");
        assertEq(address(payee).balance, 0.05 ether);
        assertEq(right.creditOf(address(payee)), 0);
        assertEq(right.totalCredits(), 0.95 ether);
        assertEq(address(right).balance, 0.95 ether);
    }

    function test_strangerCannotRedirectAnotherBeneficiaryCredit() public {
        PassivePayee payee = new PassivePayee();
        Right right = _exercise(address(payee));
        vm.prank(stranger);
        right.withdrawCredit(payable(stranger));
        assertEq(stranger.balance, 0);
        assertEq(right.creditOf(address(payee)), 0.05 ether);
        vm.prank(issuer);
        right.withdrawCredit(payable(stranger));
        assertEq(stranger.balance, 0.95 ether, "only issuer can redirect issuer credit");
        assertEq(right.creditOf(address(payee)), 0.05 ether);
    }

    function test_revertingReleaseRestoresLiabilityAndCompletedExercise() public {
        Rejecter payee = new Rejecter();
        Right right = _exercise(address(payee));
        (bool ok,) = address(right).call(abi.encodeWithSignature("releaseCredit(address)", address(payee)));
        assertFalse(ok);
        assertEq(right.creditOf(address(payee)), 0.05 ether);
        assertEq(right.totalCredits(), 1 ether);
        assertEq(address(right).balance, 1 ether);
        assertEq(uint256(right.state()), uint256(Right.State.Exercised));
        assertEq(nft.ownerOf(1), holder);
        vm.prank(issuer);
        right.withdrawCredit(payable(issuer));
        assertEq(issuer.balance, 0.95 ether, "refusing payee cannot block another beneficiary");
    }

    function test_releaseCallbackCannotDoublePayOrStealRemainingCredits() public {
        ReenteringPayee payee = new ReenteringPayee();
        Right right = _exercise(address(payee));
        payee.setRight(right);
        (bool ok,) = address(right).call(abi.encodeWithSignature("releaseCredit(address)", address(payee)));
        assertTrue(ok);
        assertEq(payee.receipts(), 1);
        assertEq(address(payee).balance, 0.05 ether);
        assertFalse(payee.recoverySucceeded());
        assertEq(right.creditOf(issuer), 0.95 ether);
        assertEq(right.totalCredits(), 0.95 ether);
        assertEq(address(right).balance, 0.95 ether);
    }

    function test_refusingBeneficiaryCanStillChooseAcceptingDestination() public {
        RedirectingPayee payee = new RedirectingPayee();
        Right right = _exercise(address(payee));
        vm.expectRevert("credit transfer failed");
        right.releaseCredit(address(payee));
        payee.collect(right, payable(holder));
        assertEq(holder.balance, 9.05 ether);
        assertEq(right.creditOf(address(payee)), 0);
        assertEq(right.totalCredits(), 0.95 ether);
    }

    function test_residualCallbackCannotDrainAnotherBeneficiaryReserve() public {
        Reenterer owner = new Reenterer();
        PassivePayee royalty = new PassivePayee();
        nft.mint(address(owner), 2);
        nft.setRoyalty(address(royalty), 500);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 2, 1 ether, address(owner), 500));
        Right right = Right(
            payable(abi.decode(
                    owner.call(
                        address(market),
                        0,
                        abi.encodeCall(
                            Market.createRight,
                            (purchase, config, block.timestamp + 1 days, address(owner), bytes32(uint256(2)))
                        )
                    ),
                    (address)
                ))
        );
        owner.call(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(owner), address(right), 2)));
        owner.call(address(right), 0, abi.encodeCall(Right.activate, (config)));
        owner.call(
            address(market.rights()), 0, abi.encodeCall(IERC721.transferFrom, (address(owner), holder, right.tokenId()))
        );
        vm.prank(holder);
        right.exercise{value: 1 ether}(config, abi.encode(holder));
        owner.arm(address(right), abi.encodeCall(Right.recover, (address(owner), 0.05 ether, "")));
        right.releaseCredit(address(owner));
        assertTrue(owner.attempted());
        assertFalse(owner.succeeded());
        assertEq(address(owner).balance, 0.95 ether);
        assertEq(right.creditOf(address(royalty)), 0.05 ether);
        assertEq(right.totalCredits(), 0.05 ether);
        right.releaseCredit(address(royalty));
        assertEq(address(royalty).balance, 0.05 ether);
    }
}
