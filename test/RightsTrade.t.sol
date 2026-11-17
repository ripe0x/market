// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {Order} from "../src/Order.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Base} from "./utils/Base.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

/// A holder can buy the entitlement and exercise in one transaction. Any later failure
/// reverts the preceding sale as well.
contract AtomicRightBuyer {
    function buyAndExercise(
        Order listing,
        bytes calldata listingConfig,
        Right right,
        bytes calldata rightConfig,
        address recipient,
        uint256 premium,
        uint256 exercisePrice
    ) external payable {
        require(msg.value == premium + exercisePrice, "funding");
        listing.fill{value: premium}(listingConfig, abi.encode(address(this), premium));
        right.exercise{value: exercisePrice}(rightConfig, abi.encode(recipient));
    }

    receive() external payable {}
}

/// A hostile collection that moves the NFT but lies about the destination afterwards.
/// Market accepts arbitrary collections by design; the supported handler must reject this.
contract PostTransferLiar is ERC721 {
    bool public armed;
    bool public lied;
    address public previous;

    constructor() ERC721("Post-transfer liar", "LIAR") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm() external {
        armed = true;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        super.transferFrom(from, to, id);
        if (armed) {
            previous = from;
            lied = true;
        }
    }

    function ownerOf(uint256 id) public view override returns (address) {
        return lied ? previous : super.ownerOf(id);
    }
}

contract CreditRaider {
    Right public right;
    bool public recoverySucceeded;

    function setRight(Right right_) external {
        require(address(right) == address(0));
        right = right_;
    }

    function withdraw() external {
        right.withdrawCredit(payable(address(this)));
    }

    receive() external payable {
        (recoverySucceeded,) = address(right).call(abi.encodeCall(Right.recover, (address(this), 0.95 ether, "")));
    }
}

contract RightsTradeTest is Base {
    CoveredNFTPurchase purchase;
    RoyaltyNFT art;
    Rights rights;
    address reseller = makeAddr("reseller");
    address recipient = makeAddr("recipient");
    uint256 constant PRICE = 1 ether;
    uint256 constant PREMIUM = 0.2 ether;
    uint256 rightDeadline;
    bytes rightConfig;
    Right right;

    function setUp() public override {
        super.setUp();
        purchase = new CoveredNFTPurchase(market);
        art = new RoyaltyNFT();
        rights = market.rights();
        rightDeadline = block.timestamp + 10 days;
        art.mint(seller, 1);
        rightConfig = abi.encode(CoveredNFTPurchase.Config(art, 1, PRICE, seller, 0));
        vm.prank(seller);
        right = market.createRight(purchase, rightConfig, rightDeadline, seller, bytes32(uint256(1)));
        vm.prank(seller);
        art.transferFrom(seller, address(right), 1);
        vm.prank(seller);
        right.activate(rightConfig);
        vm.deal(reseller, 10 ether);
    }

    function _listing(address owner, uint256 price) internal returns (Order listing, bytes memory config) {
        uint256 id = right.tokenId();
        NFTTrade.Schedule memory schedule =
            NFTTrade.Schedule(price, price, block.timestamp, block.timestamp, rightDeadline - 1 days);
        config = abi.encode(NFTSale.Config(rights, id, schedule, owner, 0));
        vm.prank(owner);
        listing = market.create(sale, config, bytes32(uint256(uint160(owner))));
        vm.prank(owner);
        rights.transferFrom(owner, address(listing), id);
    }

    function test_saleResaleExercisePreserveBackingAndSeparatePremiums() public {
        bytes32 committedConfig = right.configHash();
        bytes memory committedTerms = right.activationTerms();
        (Order first, bytes memory firstConfig) = _listing(seller, PREMIUM);
        assertEq(rights.ownerOf(right.tokenId()), address(first));
        assertEq(art.ownerOf(1), address(right));
        vm.prank(seller);
        vm.expectRevert(Right.Unauthorized.selector);
        right.exercise(rightConfig, abi.encode(seller));
        vm.prank(buyer);
        first.fill{value: PREMIUM}(firstConfig, abi.encode(buyer, PREMIUM));
        assertEq(seller.balance, 0.198 ether, "primary premium less 1% fee");
        assertEq(treasury.balance, 0.002 ether, "trading fee only");
        assertEq(rights.ownerOf(right.tokenId()), buyer);
        assertEq(art.ownerOf(1), address(right), "backing stays at original right");

        (Order second, bytes memory secondConfig) = _listing(buyer, 0.3 ether);
        vm.prank(reseller);
        second.fill{value: 0.3 ether}(secondConfig, abi.encode(reseller, 0.3 ether));
        assertEq(buyer.balance, 100 ether - PREMIUM + 0.297 ether, "reseller receives secondary premium");
        assertEq(treasury.balance, 0.005 ether);
        assertEq(right.configHash(), committedConfig);
        assertEq(right.activationTerms(), committedTerms);
        assertEq(right.deadline(), rightDeadline);
        assertEq(art.ownerOf(1), address(right));

        vm.prank(reseller);
        right.exercise{value: PRICE}(rightConfig, abi.encode(recipient));
        assertEq(art.ownerOf(1), recipient);
        assertEq(right.creditOf(seller), PRICE, "exercise payment belongs to original payee");
        assertEq(treasury.balance, 0.005 ether, "no exercise trading fee");
        uint256 id = right.tokenId();
        vm.expectRevert();
        rights.ownerOf(id);
    }

    function test_cancelListingReturnsRightWithoutChangingIt() public {
        (Order listing,) = _listing(seller, PREMIUM);
        uint256 id = right.tokenId();
        vm.prank(seller);
        listing.close();
        vm.prank(seller);
        listing.execute(address(rights), 0, abi.encodeCall(IERC721.transferFrom, (address(listing), seller, id)));
        assertEq(rights.ownerOf(id), seller);
        assertTrue(right.isLive());
        assertEq(right.deadline(), rightDeadline);
        assertEq(art.ownerOf(1), address(right));
    }

    function test_issuerBuysBackRightAndSurrendersWithoutExercise() public {
        uint256 id = right.tokenId();
        vm.prank(seller);
        rights.transferFrom(seller, buyer, id);
        (Order listing, bytes memory saleConfig) = _listing(buyer, PREMIUM);
        vm.deal(seller, PREMIUM);
        vm.prank(seller);
        listing.fill{value: PREMIUM}(saleConfig, abi.encode(seller, PREMIUM));
        assertEq(rights.ownerOf(id), seller);
        assertEq(buyer.balance, 100.198 ether, "buyer receives resale premium less trading fee");
        assertEq(treasury.balance, 0.002 ether);
        vm.prank(seller);
        right.surrender();
        vm.prank(seller);
        right.recover(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(right), seller, 1)));
        assertEq(art.ownerOf(1), seller);
        assertEq(right.totalCredits(), 0, "no exercise payment or royalty on issuer release");
    }

    function test_paidBuyerSurrenderLosesPremiumAndIssuerRecovers() public {
        (Order listing, bytes memory saleConfig) = _listing(seller, PREMIUM);
        vm.prank(buyer);
        listing.fill{value: PREMIUM}(saleConfig, abi.encode(buyer, PREMIUM));
        uint256 id = right.tokenId();
        assertEq(rights.ownerOf(id), buyer);
        vm.prank(buyer);
        right.surrender();
        vm.prank(buyer);
        vm.expectRevert(Right.Unauthorized.selector);
        right.recover(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(right), buyer, 1)));
        vm.prank(seller);
        right.recover(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(right), seller, 1)));
        assertEq(art.ownerOf(1), seller);
        assertEq(buyer.balance, 100 ether - PREMIUM, "premium is sunk after surrender");
        assertEq(seller.balance, 0.198 ether);
        assertEq(treasury.balance, 0.002 ether);
        assertEq(right.totalCredits(), 0, "no exercise payment or royalty");
    }

    function test_expiredEscrowCannotSettleBeforeFinalization() public {
        (Order listing, bytes memory saleConfig) = _listing(seller, PREMIUM);
        vm.warp(rightDeadline);
        vm.expectRevert(NFTTrade.RightNotLive.selector);
        sale.quote(address(listing), abi.decode(saleConfig, (NFTSale.Config)));
        vm.prank(buyer);
        vm.expectRevert(NFTTrade.RightNotLive.selector);
        listing.fill{value: PREMIUM}(saleConfig, abi.encode(buyer, PREMIUM));
        right.finalizeExpiry();
        vm.prank(seller);
        right.recover(address(art), 0, abi.encodeCall(IERC721.transferFrom, (address(right), seller, 1)));
        assertEq(art.ownerOf(1), seller);
        assertEq(treasury.balance, 0);
    }

    function test_specificBidBuysRightButCollectionBidIsRejected() public {
        uint256 id = right.tokenId();
        NFTTrade.Schedule memory schedule =
            NFTTrade.Schedule(PREMIUM, PREMIUM, block.timestamp, block.timestamp, rightDeadline - 1 days);
        bytes memory wide = abi.encode(NFTBid.Config(rights, true, 0, schedule, buyer, 1));
        vm.prank(buyer);
        Order wideBid = market.create{value: PREMIUM}(bids, wide, bytes32(uint256(2)));
        vm.expectRevert(NFTBid.CollectionWideRightsBid.selector);
        bids.quote(address(wideBid), abi.decode(wide, (NFTBid.Config)), id);
        vm.prank(seller);
        rights.approve(address(bids), id);
        vm.prank(seller);
        vm.expectRevert(NFTBid.CollectionWideRightsBid.selector);
        wideBid.fill(wide, abi.encode(id, 0, seller));

        bytes memory specific = abi.encode(NFTBid.Config(rights, false, id, schedule, buyer, 1));
        vm.prank(buyer);
        Order bid = market.create{value: PREMIUM}(bids, specific, bytes32(uint256(3)));
        vm.prank(seller);
        bid.fill(specific, abi.encode(id, 0.198 ether, seller));
        assertEq(rights.ownerOf(id), buyer);
        assertEq(seller.balance, 0.198 ether);
        assertEq(treasury.balance, 0.002 ether);
        assertEq(art.ownerOf(1), address(right));
    }

    function test_atomicBuyAndExerciseRollsBackOnFailure() public {
        (Order listing, bytes memory listingConfig) = _listing(seller, PREMIUM);
        AtomicRightBuyer helper = new AtomicRightBuyer();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredNFTPurchase.WrongPayment.selector, PRICE, 0.9 ether));
        helper.buyAndExercise{value: 1.1 ether}(
            listing, listingConfig, right, rightConfig, recipient, PREMIUM, 0.9 ether
        );
        assertEq(rights.ownerOf(right.tokenId()), address(listing));
        assertFalse(listing.closed());
        assertEq(seller.balance, 0);
        assertEq(treasury.balance, 0);
        assertEq(right.totalCredits(), 0);

        vm.prank(buyer);
        helper.buyAndExercise{value: 1.2 ether}(listing, listingConfig, right, rightConfig, recipient, PREMIUM, PRICE);
        assertEq(art.ownerOf(1), recipient);
        assertEq(right.creditOf(seller), PRICE);
        assertEq(seller.balance, 0.198 ether);
        assertEq(treasury.balance, 0.002 ether);
    }

    function test_postTransferDeliveryFailureRollsBackTargetAndPayment() public {
        PostTransferLiar liar = new PostTransferLiar();
        liar.mint(seller, 2);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(liar, 2, PRICE, seller, 0));
        vm.prank(seller);
        Right account = market.createRight(purchase, config, rightDeadline, seller, bytes32(uint256(4)));
        vm.prank(seller);
        liar.transferFrom(seller, address(account), 2);
        vm.prank(seller);
        account.activate(config);
        uint256 id = account.tokenId();
        vm.prank(seller);
        rights.transferFrom(seller, buyer, id);
        liar.arm();
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert(CoveredNFTPurchase.NotDelivered.selector);
        account.exercise{value: PRICE}(config, abi.encode(recipient));
        assertEq(liar.ownerOf(2), address(account), "NFT transfer rolled back");
        assertFalse(liar.lied(), "target state rolled back");
        assertEq(rights.ownerOf(id), buyer, "entitlement remains live");
        assertEq(uint256(account.state()), uint256(Right.State.Active));
        assertEq(account.totalCredits(), 0);
        assertEq(buyer.balance, buyerBefore, "payment rolled back");
    }

    function test_fullExerciseRoyaltyLeavesNoIssuerProceeds() public {
        RoyaltyNFT full = new RoyaltyNFT();
        full.mint(seller, 3);
        full.setRoyalty(royalty, 10_000);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(full, 3, PRICE, seller, 10_000));
        vm.prank(seller);
        Right account = market.createRight(purchase, config, rightDeadline, seller, bytes32(uint256(5)));
        vm.prank(seller);
        full.transferFrom(seller, address(account), 3);
        vm.prank(seller);
        account.activate(config);
        uint256 id = account.tokenId();
        vm.prank(seller);
        rights.transferFrom(seller, buyer, id);
        vm.prank(buyer);
        account.exercise{value: PRICE}(config, abi.encode(buyer));
        assertEq(full.ownerOf(3), buyer);
        assertEq(account.creditOf(royalty), PRICE);
        assertEq(account.creditOf(seller), 0);
        assertEq(account.totalCredits(), PRICE);
        vm.prank(seller);
        vm.expectRevert(Right.EncumberedBalance.selector);
        account.recover(seller, PRICE, "");
        account.releaseCredit(royalty);
        assertEq(royalty.balance, PRICE);
        assertEq(account.totalCredits(), 0);
    }

    function test_royaltyRecipientCannotReenterToStealOtherCredit() public {
        CreditRaider raider = new CreditRaider();
        RoyaltyNFT token = new RoyaltyNFT();
        token.mint(seller, 4);
        token.setRoyalty(address(raider), 500);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(token, 4, PRICE, seller, 500));
        vm.prank(seller);
        Right account = market.createRight(purchase, config, rightDeadline, seller, bytes32(uint256(6)));
        raider.setRight(account);
        vm.prank(seller);
        token.transferFrom(seller, address(account), 4);
        vm.prank(seller);
        account.activate(config);
        uint256 id = account.tokenId();
        vm.prank(seller);
        rights.transferFrom(seller, buyer, id);
        vm.prank(buyer);
        account.exercise{value: PRICE}(config, abi.encode(buyer));
        raider.withdraw();
        assertFalse(raider.recoverySucceeded());
        assertEq(address(raider).balance, 0.05 ether);
        assertEq(account.creditOf(seller), 0.95 ether);
        assertEq(account.totalCredits(), 0.95 ether);
        assertEq(address(account).balance, 0.95 ether);
    }
}
