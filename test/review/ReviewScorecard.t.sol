// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Market} from "../../src/Market.sol";
import {Actions} from "../../src/Actions.sol";
import {Order, OrderSpec, Admission, OrderState} from "../../src/Order.sol";
import {ExchangeAction} from "../../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../../actions/CoveredNFTPurchase.sol";
import {FeeConfig} from "../../actions/FeeConfig.sol";

// --- independent mocks (do not reuse repo's test mocks) ---

contract NFT is ERC721, ERC2981 {
    constructor() ERC721("N", "N") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRoyalty(address to, uint96 bps) external {
        _setDefaultRoyalty(to, bps);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}

// Receives ETH and tries to reenter the order's execute() during settlement.
contract ReentrantReceiver {
    Order public target;
    bytes public input;
    bool public tried;
    bool public reentryReverted;

    function arm(Order t, bytes memory i) external {
        target = t;
        input = i;
    }

    receive() external payable {
        if (address(target) == address(0)) return;
        tried = true;
        try target.execute(input) {
            reentryReverted = false;
        } catch {
            reentryReverted = true;
        }
    }
}

contract ReviewScorecard is Test {
    Market market;
    Actions actions;
    ExchangeAction exchange;
    CoveredNFTPurchase covered;
    FeeConfig fees;

    address feeAdmin = address(0xFEE0);
    address feeTo = address(0xFEE1);
    address issuer = address(0xA11CE);
    address buyer = address(0xB0B);
    address royaltyTo = address(0x2981);

    function setUp() public {
        market = new Market();
        actions = market.actions();
        fees = new FeeConfig(feeAdmin, feeTo);
        exchange = new ExchangeAction(market, fees);
        covered = new CoveredNFTPurchase(market);
        // default fee is MAX_FEE_BPS = 100 (1%)
    }

    function _saleSpec(NFT nft, uint256 id, uint16 maxRoyaltyBps) internal view returns (OrderSpec memory spec) {
        ExchangeAction.Schedule memory sch =
            ExchangeAction.Schedule({startPrice: 1 ether, endPrice: 1 ether, startTime: 0, endTime: 0});
        ExchangeAction.SaleTerms memory t =
            ExchangeAction.SaleTerms({tokenId: id, proceedsTo: issuer, maxRoyaltyBps: maxRoyaltyBps});
        ExchangeAction.Config memory c = ExchangeAction.Config({
            side: ExchangeAction.Side.Sale,
            nft: nft,
            schedule: sch,
            maxFeeBps: 100,
            terms: abi.encode(t)
        });
        spec = OrderSpec({
            action: address(exchange),
            admission: Admission.Public,
            deadline: 0,
            residual: issuer,
            config: abi.encode(c)
        });
    }

    // ---------- ECONOMIC SCORECARD: public sale ----------
    // price 1 ETH, fee 1% = 0.01, royalty 5% = 0.05, proceeds = 0.94
    function test_scorecard_sale() public {
        NFT nft = new NFT();
        nft.setRoyalty(royaltyTo, 500); // 5%
        nft.mint(issuer, 1);

        OrderSpec memory spec = _saleSpec(nft, 1, 1000); // maxRoyaltyBps 10%
        address predicted = market.orderAddress(issuer, spec, bytes32(0));

        vm.prank(issuer);
        nft.transferFrom(issuer, predicted, 1);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();

        assertEq(nft.ownerOf(1), address(o), "escrowed");

        vm.deal(buyer, 1.5 ether);
        uint256 issuerBefore = issuer.balance;
        uint256 feeBefore = feeTo.balance;
        uint256 royBefore = royaltyTo.balance;

        vm.prank(buyer);
        o.execute{value: 1.5 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));

        assertEq(nft.ownerOf(1), buyer, "delivered");
        assertEq(uint8(o.state()), uint8(OrderState.Completed), "completed");
        assertEq(feeTo.balance - feeBefore, 0.01 ether, "fee 1%");
        assertEq(royaltyTo.balance - royBefore, 0.05 ether, "royalty 5%");
        assertEq(issuer.balance - issuerBefore, 0.94 ether, "proceeds");
        assertEq(buyer.balance, 0.5 ether, "refund of overpay");
        assertEq(address(o).balance, 0, "order drained; nothing stranded");
        assertEq(o.totalCredits(), 0, "sale uses immediate settlement, no credits");
    }

    // ---------- ECONOMIC SCORECARD: covered purchase (Holder) ----------
    // price 2 ETH, royalty 5% = 0.1, proceeds 1.9, credited (not pushed)
    function test_scorecard_covered() public {
        NFT nft = new NFT();
        nft.setRoyalty(royaltyTo, 500);
        nft.mint(issuer, 7);

        CoveredNFTPurchase.Config memory c =
            CoveredNFTPurchase.Config({nft: nft, tokenId: 7, price: 2 ether, proceedsTo: issuer, maxRoyaltyBps: 1000});
        OrderSpec memory spec = OrderSpec({
            action: address(covered),
            admission: Admission.Holder,
            deadline: 0,
            residual: issuer,
            config: abi.encode(c)
        });
        address predicted = market.orderAddress(issuer, spec, bytes32(0));
        vm.prank(issuer);
        nft.transferFrom(issuer, predicted, 7);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();

        assertEq(actions.ownerOf(uint256(uint160(address(o)))), issuer, "token to issuer");
        vm.prank(issuer);
        actions.transferFrom(issuer, buyer, uint256(uint160(address(o))));

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        o.execute{value: 2 ether}(abi.encode(buyer));

        assertEq(nft.ownerOf(7), buyer, "delivered to buyer");
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        assertEq(o.creditOf(royaltyTo), 0.1 ether, "royalty credit");
        assertEq(o.creditOf(issuer), 1.9 ether, "proceeds credit");
        assertEq(o.totalCredits(), 2 ether, "credits == price");
        assertEq(address(o).balance, 2 ether, "balance backs credits");
        assertEq(o.freeBalance(), 0, "nothing free");
        assertGe(address(o).balance, o.totalCredits(), "solvency invariant");

        o.releaseCredit(royaltyTo);
        o.releaseCredit(issuer);
        assertEq(royaltyTo.balance, 0.1 ether);
        assertEq(issuer.balance, 1.9 ether);
        assertEq(address(o).balance, 0, "fully settled");
    }

    // ---------- Reentrancy: malicious proceeds receiver cannot re-execute ----------
    function test_reentrant_proceeds_receiver_blocked() public {
        NFT nft = new NFT(); // no royalty
        nft.mint(issuer, 3);

        ReentrantReceiver evil = new ReentrantReceiver();

        ExchangeAction.Schedule memory sch =
            ExchangeAction.Schedule({startPrice: 1 ether, endPrice: 1 ether, startTime: 0, endTime: 0});
        ExchangeAction.SaleTerms memory t =
            ExchangeAction.SaleTerms({tokenId: 3, proceedsTo: address(evil), maxRoyaltyBps: 0});
        ExchangeAction.Config memory c = ExchangeAction.Config({
            side: ExchangeAction.Side.Sale,
            nft: nft,
            schedule: sch,
            maxFeeBps: 100,
            terms: abi.encode(t)
        });
        OrderSpec memory spec = OrderSpec({
            action: address(exchange),
            admission: Admission.Public,
            deadline: 0,
            residual: issuer,
            config: abi.encode(c)
        });
        address predicted = market.orderAddress(issuer, spec, bytes32(0));
        vm.prank(issuer);
        nft.transferFrom(issuer, predicted, 3);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();

        evil.arm(o, abi.encode(buyer, uint256(1 ether), uint64(0)));

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));

        assertTrue(evil.tried(), "receiver got control during settlement");
        assertTrue(evil.reentryReverted(), "reentrant execute() reverted (Busy)");
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        assertEq(nft.ownerOf(3), buyer);
    }

    // ---------- Edge: Actions-token listing cannot close via release after underlying expires ----------
    function test_actions_listing_release_after_underlying_expires() public {
        NFT nft = new NFT();
        nft.mint(issuer, 9);
        CoveredNFTPurchase.Config memory cc =
            CoveredNFTPurchase.Config({nft: nft, tokenId: 9, price: 1 ether, proceedsTo: issuer, maxRoyaltyBps: 0});
        uint64 dl = uint64(block.timestamp + 1 days);
        OrderSpec memory uspec = OrderSpec({
            action: address(covered),
            admission: Admission.Holder,
            deadline: dl,
            residual: issuer,
            config: abi.encode(cc)
        });
        address upred = market.orderAddress(issuer, uspec, bytes32("u"));
        vm.prank(issuer);
        nft.transferFrom(issuer, upred, 9);
        vm.prank(issuer);
        Order u = market.create(uspec, bytes32("u"));
        vm.prank(issuer);
        u.activate();
        uint256 actId = uint256(uint160(address(u)));
        assertEq(actions.ownerOf(actId), issuer);

        ExchangeAction.Schedule memory sch =
            ExchangeAction.Schedule({startPrice: 1 ether, endPrice: 1 ether, startTime: 0, endTime: 0});
        ExchangeAction.SaleTerms memory st =
            ExchangeAction.SaleTerms({tokenId: actId, proceedsTo: issuer, maxRoyaltyBps: 0});
        ExchangeAction.Config memory lc = ExchangeAction.Config({
            side: ExchangeAction.Side.Sale,
            nft: actions,
            schedule: sch,
            maxFeeBps: 100,
            terms: abi.encode(st)
        });
        OrderSpec memory lspec = OrderSpec({
            action: address(exchange),
            admission: Admission.Public,
            deadline: uint64(block.timestamp + 2 days),
            residual: issuer,
            config: abi.encode(lc)
        });
        address lpred = market.orderAddress(issuer, lspec, bytes32("l"));
        vm.prank(issuer);
        actions.transferFrom(issuer, lpred, actId);
        vm.prank(issuer);
        Order l = market.create(lspec, bytes32("l"));
        vm.prank(issuer);
        l.activate();
        assertEq(actions.ownerOf(actId), address(l), "listing holds the actions token");

        vm.warp(dl + 1);
        u.finalizeExpiry();
        assertEq(uint8(u.state()), uint8(OrderState.Expired));
        vm.expectRevert();
        actions.ownerOf(actId);

        vm.prank(issuer);
        l.cancel();
        assertEq(uint8(l.state()), uint8(OrderState.Canceled));

        vm.prank(issuer);
        vm.expectRevert(ExchangeAction.ActionNotLive.selector);
        l.release(issuer, "");
    }
}
