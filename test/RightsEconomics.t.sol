// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {Order} from "../src/Order.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

contract RightsEconomicsTest is Base {
    function _trade(uint256 premium, uint256 strike) internal {
        RoyaltyNFT underlying = new RoyaltyNFT();
        underlying.setRoyalty(royalty, 500);
        underlying.mint(seller, 1);
        CoveredNFTPurchase purchase = new CoveredNFTPurchase(market);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(underlying, 1, strike, seller, 500));
        vm.startPrank(seller);
        Right right = market.createRight(purchase, config, block.timestamp + 7 days, seller, 0);
        underlying.transferFrom(seller, address(right), 1);
        right.activate(config);
        Rights rights = market.rights();
        bytes memory listingConfig = abi.encode(NFTSale.Config(rights, right.tokenId(), _fixed(premium), seller, 0));
        Order listing = market.create(sale, listingConfig, 0);
        rights.transferFrom(seller, address(listing), right.tokenId());
        vm.stopPrank();
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        listing.fill{value: premium}(listingConfig, abi.encode(buyer, premium));
        assertEq(underlying.ownerOf(1), address(right), "premium does not deliver collateral");
        assertEq(treasury.balance, premium / 100, "trading fee on premium only");
        assertEq(seller.balance, premium - premium / 100, "premium seller receives net premium");
        assertEq(royalty.balance, 0, "canonical right premium has no underlying royalty");
        assertFalse(rights.supportsInterface(0x2a55205a), "no ERC2981 on canonical Rights");
        vm.prank(buyer);
        right.exercise{value: strike}(config, abi.encode(buyer));
        uint256 royaltyAmount = strike * 500 / 10_000;
        assertEq(right.creditOf(royalty), royaltyAmount, "royalty applies to strike only");
        assertEq(right.creditOf(seller), strike - royaltyAmount);
        assertEq(right.totalCredits(), strike);
        assertEq(address(right).balance, strike);
        assertEq(buyerBefore - buyer.balance, premium + strike);
        assertEq(treasury.balance, premium / 100, "exercise adds no trading fee");
        right.releaseCredit(seller);
        right.releaseCredit(royalty);
        assertEq(royalty.balance, royaltyAmount);
        assertEq(seller.balance, premium - premium / 100 + strike - royaltyAmount);
        assertEq(underlying.ownerOf(1), buyer);
        assertEq(address(right).balance, 0);
        assertEq(right.totalCredits(), 0);
    }

    function test_fullPremiumZeroStrikeHasNoUnderlyingRoyalty() public {
        _trade(1 ether, 0);
    }

    function test_oneWeiStrikeRoundsUnderlyingRoyaltyToZero() public {
        _trade(1 ether, 1);
    }

    function test_zeroPremiumFullStrikeHasNoTradingFee() public {
        _trade(0, 1 ether);
    }
}
