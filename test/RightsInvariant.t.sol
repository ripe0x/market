// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

contract RightsDriver is Test {
    Market public market = new Market();
    Rights public rights = market.rights();
    CoveredNFTPurchase public purchase = new CoveredNFTPurchase(market);
    RoyaltyNFT public nft = new RoyaltyNFT();
    Right public right;
    bytes public config;
    address public issuer = makeAddr("issuer");
    address public royalty = makeAddr("royalty");
    address public residual = makeAddr("residual");
    address[3] public holders = [makeAddr("holder0"), makeAddr("holder1"), makeAddr("holder2")];
    address public deliveredTo;
    uint256 public deadline;
    uint256 public withdrawn;
    bool public issuerBypassSucceeded;

    constructor() {
        vm.warp(1_000_000);
        deadline = block.timestamp + 7 days;
        nft.mint(issuer, 1);
        nft.setRoyalty(royalty, 500);
        config = abi.encode(CoveredNFTPurchase.Config(nft, 1, 1 ether, issuer, 500));
        vm.prank(issuer);
        right = market.createRight(purchase, config, deadline, residual, bytes32(uint256(1)));
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), 1);
        vm.prank(issuer);
        right.activate(config);
        for (uint256 i; i < holders.length; i++) {
            vm.deal(holders[i], 10 ether);
        }
        vm.deal(issuer, 10 ether);
    }

    function transfer(uint256 seed) external {
        if (!right.isLive()) return;
        uint256 id = right.tokenId();
        address from = rights.ownerOf(id);
        address to = holders[seed % holders.length];
        if (from == to) return;
        vm.prank(from);
        rights.transferFrom(from, to, id);
    }

    function exercise(uint256 seed) external {
        if (!right.isLive()) return;
        address holder = rights.ownerOf(right.tokenId());
        deliveredTo = holders[seed % holders.length];
        vm.prank(holder);
        right.exercise{value: 1 ether}(config, abi.encode(deliveredTo));
    }

    function surrender() external {
        if (!right.isLive()) return;
        address holder = rights.ownerOf(right.tokenId());
        vm.prank(holder);
        right.surrender();
    }

    function expire() external {
        if (right.state() != Right.State.Active) return;
        vm.warp(deadline);
        right.finalizeExpiry();
    }

    function recover() external {
        if (right.state() == Right.State.Active || nft.ownerOf(1) != address(right)) return;
        vm.prank(residual);
        right.recover(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(right), residual, 1)));
    }

    function withdraw(uint256 seed) external {
        address beneficiary = seed % 2 == 0 ? issuer : royalty;
        uint256 amount = right.creditOf(beneficiary);
        if (amount == 0) return;
        vm.prank(beneficiary);
        right.withdrawCredit(payable(beneficiary));
        withdrawn += amount;
    }

    function issuerBypass() external {
        if (right.state() != Right.State.Active) return;
        vm.prank(issuer);
        (bool ok,) = address(right)
            .call(
                abi.encodeCall(
                    Right.execute, (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(right), issuer, 1)))
                )
            );
        if (ok) issuerBypassSucceeded = true;
        vm.prank(issuer);
        (ok,) = address(right)
            .call(
                abi.encodeCall(
                    Right.recover, (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(right), issuer, 1)))
                )
            );
        if (ok) issuerBypassSucceeded = true;
    }
}

contract RightsInvariantTest is StdInvariant, Test {
    RightsDriver driver;

    function setUp() public {
        driver = new RightsDriver();
        targetContract(address(driver));
    }

    function invariant_collateralAndEntitlement() public view {
        Right right = driver.right();
        RoyaltyNFT nft = driver.nft();
        if (right.state() == Right.State.Active) {
            assertEq(nft.ownerOf(1), address(right), "active right remains covered");
            assertTrue(driver.rights().everMinted(right.tokenId()));
            assertEq(right.totalCredits(), 0);
        }
        if (right.state() == Right.State.Exercised) {
            assertEq(nft.ownerOf(1), driver.deliveredTo(), "exercise delivered");
        }
        assertFalse(driver.issuerBypassSucceeded());
    }

    function invariant_paymentLiabilities() public view {
        Right right = driver.right();
        uint256 credits = right.creditOf(driver.issuer()) + right.creditOf(driver.royalty());
        assertEq(credits, right.totalCredits());
        assertLe(credits, address(right).balance);
        if (right.state() == Right.State.Exercised) {
            assertEq(credits + driver.withdrawn(), 1 ether, "exercise payment fully allocated");
        } else {
            assertEq(credits + driver.withdrawn(), 0);
        }
    }
}
