// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {Order} from "../src/Order.sol";
import {FeeConfig} from "../handlers/FeeConfig.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {ReservedPaint} from "../examples/ReservedPaint.sol";
import {Artwork} from "../examples/Artwork.sol";
import {RoyaltyNFT} from "../test/utils/Mocks.sol";

/// @notice Local simulation only. Runs primary and secondary sales, exercise, cancellation,
/// expiry and recovery for a covered NFT; then resells and exercises a reserved artwork right.
/// Run `forge script script/RightsLifecycle.s.sol:RightsLifecycle --sig "run()"` without RPC or broadcast.
contract RightsLifecycle is Script {
    address constant ISSUER = address(0xA11CE);
    address constant BUYER = address(0xB0B);
    address constant HOLDER = address(0xCAFE);
    address constant ROYALTY = address(0xD00D);
    address constant FEE_TO = address(0xFEE);

    Market market;
    Rights rights;
    NFTSale sale;
    CoveredNFTPurchase purchase;
    ReservedPaint paint;
    RoyaltyNFT nft;

    function run() external {
        require(block.chainid == 31337, "local simulation only");
        vm.warp(1_000_000);
        vm.deal(ISSUER, 3 ether);
        vm.deal(BUYER, 3 ether);
        vm.deal(HOLDER, 3 ether);
        market = new Market();
        rights = market.rights();
        FeeConfig fees = new FeeConfig(market, ISSUER, FEE_TO);
        sale = new NFTSale(fees);
        purchase = new CoveredNFTPurchase(market);
        paint = new ReservedPaint(market);
        nft = new RoyaltyNFT();
        nft.setRoyalty(ROYALTY, 500);
        nft.mint(ISSUER, 1);
        nft.mint(ISSUER, 2);

        coveredExercise();
        coveredExpiry();
        artworkExercise();
        console.log("Local rights lifecycles passed");
    }

    function coveredExercise() internal {
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 1, 1 ether, ISSUER, 1000));
        vm.prank(ISSUER);
        Right right = market.createRight(purchase, config, vm.getBlockTimestamp() + 7 days, ISSUER, bytes32(uint256(1)));
        require(right.issuer() == ISSUER && right.residual() == ISSUER, "check issuer residual before deposit");
        vm.prank(ISSUER);
        nft.transferFrom(ISSUER, address(right), 1);
        vm.prank(ISSUER);
        right.activate(config);
        uint256 id = right.tokenId();
        require(rights.ownerOf(id) == ISSUER && nft.ownerOf(1) == address(right), "backed activation");

        _sell(id, ISSUER, BUYER, 0.2 ether, vm.getBlockTimestamp() + 2 days, bytes32(uint256(10)));
        _sell(id, BUYER, HOLDER, 0.3 ether, vm.getBlockTimestamp() + 3 days, bytes32(uint256(11)));
        require(nft.ownerOf(1) == address(right) && rights.ownerOf(id) == HOLDER, "resale keeps backing");
        vm.prank(HOLDER);
        right.exercise{value: 1 ether}(config, abi.encode(HOLDER));
        require(nft.ownerOf(1) == HOLDER && right.state() == Right.State.Exercised, "exercise delivery");
        require(right.creditOf(ROYALTY) == 0.05 ether && right.creditOf(ISSUER) == 0.95 ether, "fixed payment split");
        right.releaseCredit(ROYALTY);
        vm.prank(ISSUER);
        right.withdrawCredit(payable(ISSUER));
        require(address(right).balance == 0, "credits withdrawn");
        console.log("Covered right sold, resold and exercised", address(right));
    }

    function coveredExpiry() internal {
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(nft, 2, 1 ether, ISSUER, 1000));
        uint256 deadline = vm.getBlockTimestamp() + 4 days;
        vm.prank(ISSUER);
        Right right = market.createRight(purchase, config, deadline, ISSUER, bytes32(uint256(2)));
        require(right.issuer() == ISSUER && right.residual() == ISSUER, "check issuer residual before deposit");
        vm.prank(ISSUER);
        nft.transferFrom(ISSUER, address(right), 2);
        vm.prank(ISSUER);
        right.activate(config);
        uint256 id = right.tokenId();

        // The listing closes well before the right expires and does not change its terms.
        bytes memory listing = _listing(id, 0.2 ether, vm.getBlockTimestamp() + 1 days, ISSUER);
        vm.prank(ISSUER);
        Order order = market.create(sale, listing, bytes32(uint256(12)));
        vm.prank(ISSUER);
        rights.transferFrom(ISSUER, address(order), id);
        vm.prank(ISSUER);
        order.close();
        vm.prank(ISSUER);
        order.execute(address(rights), 0, abi.encodeCall(IERC721.transferFrom, (address(order), ISSUER, id)));
        require(rights.ownerOf(id) == ISSUER && right.deadline() == deadline, "listing only canceled");

        vm.warp(deadline);
        right.finalizeExpiry();
        vm.prank(ISSUER);
        right.recover(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(right), ISSUER, 2)));
        require(nft.ownerOf(2) == ISSUER && right.state() == Right.State.Expired, "expiry recovery");
        console.log("Covered right listing canceled, then expired and recovered", address(right));
    }

    function artworkExercise() internal {
        Artwork art = new Artwork();
        art.mint(ISSUER, 1);
        bytes memory config = abi.encode(ReservedPaint.Config(art, 1, uint256(1 << 2 | 1 << 3)));
        vm.prank(ISSUER);
        Right right = market.createRight(paint, config, vm.getBlockTimestamp() + 7 days, ISSUER, bytes32(uint256(3)));
        vm.prank(ISSUER);
        art.reserve(1, right, 1 << 2 | 1 << 3);
        vm.prank(ISSUER);
        right.activate(config);
        vm.prank(ISSUER);
        art.transferFrom(ISSUER, BUYER, 1);
        (address reservedRight,) = art.reservation(1);
        require(art.ownerOf(1) == BUYER && reservedRight == address(right), "reservation survives transfer");
        uint256 id = right.tokenId();
        _sell(id, ISSUER, BUYER, 0.1 ether, vm.getBlockTimestamp() + 2 days, bytes32(uint256(13)));
        _sell(id, BUYER, HOLDER, 0.2 ether, vm.getBlockTimestamp() + 3 days, bytes32(uint256(14)));
        vm.prank(HOLDER);
        right.exercise(config, abi.encode(uint8(2)));
        require(art.ownerOf(1) == BUYER && art.colorOf(1) == 2, "one allowed modification, owner retained");
        require(right.state() == Right.State.Exercised, "reservation consumed");
        console.log("Artwork right sold, resold and exercised after artwork transfer", address(right));
    }

    function _sell(uint256 id, address from, address to, uint256 premium, uint256 expiry, bytes32 salt) internal {
        uint256 sellerBefore = from.balance;
        uint256 feeBefore = FEE_TO.balance;
        uint256 buyerBefore = to.balance;
        bytes memory listing = _listing(id, premium, expiry, from);
        vm.prank(from);
        Order order = market.create(sale, listing, salt);
        vm.prank(from);
        rights.transferFrom(from, address(order), id);
        vm.prank(to);
        order.fill{value: premium}(listing, abi.encode(to, premium));
        uint256 fee = premium / 100;
        require(from.balance - sellerBefore == premium - fee, "premium seller proceeds");
        require(FEE_TO.balance - feeBefore == fee, "premium trading fee");
        require(buyerBefore - to.balance == premium, "premium buyer spend");
    }

    function _listing(uint256 id, uint256 premium, uint256 expiry, address proceeds)
        internal
        view
        returns (bytes memory)
    {
        uint256 now_ = vm.getBlockTimestamp();
        NFTTrade.Schedule memory s = NFTTrade.Schedule(premium, premium, now_, now_, expiry);
        return abi.encode(NFTSale.Config(IERC721(address(rights)), id, s, proceeds, 0));
    }
}
