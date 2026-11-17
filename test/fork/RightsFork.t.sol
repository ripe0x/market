// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../../src/Market.sol";
import {Right} from "../../src/Right.sol";
import {Rights} from "../../src/Rights.sol";
import {CoveredNFTPurchase} from "../../handlers/CoveredNFTPurchase.sol";

/// Read-only fork of real NFT collections. Only external actor wallets are funded or pranked;
/// the collections and their ERC2981 answers are the deployed contracts at this block.
contract RightsForkTest is Test {
    uint256 constant BLOCK = 26_357_000;
    IERC721 constant BAYC = IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D);
    IERC721 constant OPEPEN = IERC721(0x6339e5E072086621540D0362C4e3Cea0d643E114);

    Market market;
    Rights rights;
    CoveredNFTPurchase purchase;
    address buyer = makeAddr("rights fork buyer");

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), BLOCK);
        market = new Market();
        rights = market.rights();
        purchase = new CoveredNFTPurchase(market);
        vm.deal(buyer, 10 ether);
    }

    function test_BAYCNoRoyalty() public {
        (Right account, address issuer) = _issue(BAYC, 1, 0);
        _exercise(account, BAYC, issuer, address(0), 0);
    }

    function test_OpepenRoyaltyCommittedAndCredited() public {
        (Right account, address issuer) = _issue(OPEPEN, 1, 1000);
        (address royaltyTo, uint256 royalty) = abi.decode(account.activationTerms(), (address, uint256));
        assertEq(royalty, 0.025 ether, "2.5% of the fixed 1 ETH exercise price");
        _exercise(account, OPEPEN, issuer, royaltyTo, royalty);
    }

    function _issue(IERC721 nft, uint256 id, uint16 maxRoyaltyBps) internal returns (Right account, address issuer) {
        issuer = nft.ownerOf(id);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, id, 1 ether, issuer, maxRoyaltyBps));
        vm.prank(issuer);
        account = market.createRight(
            purchase, config, block.timestamp + 7 days, issuer, bytes32(uint256(uint160(address(nft))))
        );
        vm.prank(issuer);
        nft.transferFrom(issuer, address(account), id);
        vm.prank(issuer);
        account.activate(config);
        assertEq(nft.ownerOf(id), address(account));
    }

    function _exercise(Right account, IERC721 nft, address issuer, address royaltyTo, uint256 royalty) internal {
        uint256 id = account.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 1, 1 ether, issuer, royalty == 0 ? 0 : 1000));
        vm.prank(buyer);
        account.exercise{value: 1 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(account.creditOf(issuer), 1 ether - royalty);
        if (royalty != 0) assertEq(account.creditOf(royaltyTo), royalty);
        assertEq(account.totalCredits(), 1 ether);
        assertEq(address(account).balance, 1 ether);
        assertEq(uint256(account.state()), uint256(Right.State.Exercised));
    }
}
