// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Base} from "./utils/Base.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {ActionBase} from "../actions/ActionBase.sol";
import {FeeConfig} from "../actions/FeeConfig.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {TestNFT, RoyaltyNFT, BrokenRoyaltyNFT, Rejecter} from "./utils/Mocks.sol";

/// Buys from a sale and sells into a bid inside one transaction (arbitrage).
contract Arb {
    ExchangeAction immutable exchange;

    constructor(ExchangeAction e) {
        exchange = e;
    }

    function run(Order sale, uint256 salePrice, Order bid, IERC721 nft, uint256 id) external payable {
        sale.execute{value: salePrice}(abi.encode(address(this), salePrice, uint64(0)));
        nft.approve(address(exchange), id);
        bid.execute(abi.encode(id, uint256(0), address(this)));
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract ExchangeTest is Base {
    // ---- local builders (not in Base: custom nft / fee / royalty caps) ----

    function _saleCfg(IERC721 token, uint256 id, ExchangeAction.Schedule memory s, address proceedsTo, uint16 maxRoyaltyBps, uint16 maxFeeBps)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale, token, s, maxFeeBps, abi.encode(ExchangeAction.SaleTerms(id, proceedsTo, maxRoyaltyBps))
            )
        );
    }

    function _bidCfg(
        IERC721 token,
        bool anyToken,
        uint256 id,
        ExchangeAction.Schedule memory s,
        address recipient,
        uint64 maxExecutions,
        uint64 minActionTimeLeft,
        uint16 maxFeeBps
    ) internal pure returns (bytes memory) {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Bid,
                token,
                s,
                maxFeeBps,
                abi.encode(ExchangeAction.BidTerms(anyToken, id, recipient, maxExecutions, minActionTimeLeft))
            )
        );
    }

    /// Creates and escrows a sale (owner holds `id` of `token` already), not yet activated.
    function _saleOrder(
        address owner,
        IERC721 token,
        uint256 id,
        ExchangeAction.Schedule memory s,
        uint64 deadline,
        address proceedsTo,
        uint16 maxRoyaltyBps,
        uint16 maxFeeBps
    ) internal returns (Order o) {
        o = _create(owner, _spec(address(exchange), Admission.Public, deadline, owner, _saleCfg(token, id, s, proceedsTo, maxRoyaltyBps, maxFeeBps)), 0);
        vm.prank(owner);
        token.transferFrom(owner, address(o), id);
    }

    function _bidOrder(
        address owner,
        IERC721 token,
        bool anyToken,
        uint256 id,
        ExchangeAction.Schedule memory s,
        address recipient,
        uint64 maxExecutions,
        uint64 minActionTimeLeft,
        uint64 deadline,
        uint256 funding
    ) internal returns (Order o) {
        o = _create(
            owner,
            _spec(address(exchange), Admission.Public, deadline, owner, _bidCfg(token, anyToken, id, s, recipient, maxExecutions, minActionTimeLeft, 100)),
            funding
        );
    }

    function _sched(uint256 sp, uint256 ep, uint64 st, uint64 et) internal pure returns (ExchangeAction.Schedule memory) {
        return ExchangeAction.Schedule(sp, ep, st, et);
    }

    // =====================================================================
    // priceAt
    // =====================================================================

    function test_priceAt_fixed() public view {
        ExchangeAction.Schedule memory s = _sched(5 ether, 5 ether, 100, 100);
        assertEq(exchange.priceAt(s, 50), 5 ether);
        assertEq(exchange.priceAt(s, 100), 5 ether);
        assertEq(exchange.priceAt(s, 999), 5 ether);
    }

    function test_priceAt_declining_endpoints_and_rounding() public view {
        ExchangeAction.Schedule memory s = _sched(10 ether, 2 ether, 100, 200);
        assertEq(exchange.priceAt(s, 100), 10 ether, "at start");
        assertEq(exchange.priceAt(s, 99), 10 ether, "before start holds start");
        assertEq(exchange.priceAt(s, 200), 2 ether, "at end");
        assertEq(exchange.priceAt(s, 500), 2 ether, "after end holds end");
        assertEq(exchange.priceAt(s, 150), 6 ether, "mid exact");

        // rounding toward start price (higher for a declining line): 100 -> 0 over [0,3], t=1.
        // linear = 66.67; rounds toward start => 67.
        ExchangeAction.Schedule memory r = _sched(100, 0, 0, 3);
        assertEq(exchange.priceAt(r, 1), 67);
    }

    function test_priceAt_increasing_rounding() public view {
        ExchangeAction.Schedule memory s = _sched(2 ether, 10 ether, 100, 200);
        assertEq(exchange.priceAt(s, 100), 2 ether);
        assertEq(exchange.priceAt(s, 200), 10 ether);
        assertEq(exchange.priceAt(s, 125), 4 ether);

        // rounding toward start price (lower for a rising line): 0 -> 100 over [0,3], t=1.
        // linear = 33.33; rounds toward start => 33.
        ExchangeAction.Schedule memory r = _sched(0, 100, 0, 3);
        assertEq(exchange.priceAt(r, 1), 33);
    }

    function test_priceAt_startEqualsEnd() public view {
        ExchangeAction.Schedule memory s = _sched(10 ether, 2 ether, 100, 100);
        assertEq(exchange.priceAt(s, 99), 10 ether, "before: start price");
        assertEq(exchange.priceAt(s, 100), 2 ether, "at/after: end price");
        assertEq(exchange.priceAt(s, 101), 2 ether);
    }

    /// Huge prices never overflow and the result stays within the endpoints.
    function testFuzz_priceAt_noOverflow(uint256 sp, uint256 ep, uint64 st, uint256 dur, uint64 t) public view {
        dur = bound(dur, 0, type(uint64).max - st);
        uint64 et = uint64(st + dur);
        uint256 p = exchange.priceAt(_sched(sp, ep, st, et), t);
        uint256 lo = sp < ep ? sp : ep;
        uint256 hi = sp < ep ? ep : sp;
        assertGe(p, lo);
        assertLe(p, hi);
    }

    // =====================================================================
    // Sale: money flows
    // =====================================================================

    function test_sale_fixed_receipts() public {
        Order o = _listSale(seller, 1, 1 ether);
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, s0 + 0.99 ether, "proceeds");
        assertEq(treasury.balance, 0.01 ether, "fee");
        assertEq(buyer.balance, 1_000 ether - 1 ether, "buyer net");
        assertEq(address(o).balance, 0, "order drained");
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
    }

    function test_sale_declining_receipts() public {
        nft.mint(seller, 2);
        Order o = _saleOrder(seller, nft, 2, _sched(10 ether, 2 ether, T0, T0 + 100), 0, seller, 10_000, 100);
        _activate(o);
        vm.warp(T0 + 50); // price 6 ether
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        o.execute{value: 6 ether}(abi.encode(buyer, uint256(6 ether), uint64(0)));
        assertEq(nft.ownerOf(2), buyer);
        assertEq(seller.balance, s0 + 5.94 ether);
        assertEq(treasury.balance, 0.06 ether);
    }

    function test_sale_increasing_receipts() public {
        nft.mint(seller, 3);
        Order o = _saleOrder(seller, nft, 3, _sched(2 ether, 10 ether, T0, T0 + 100), 0, seller, 10_000, 100);
        _activate(o);
        vm.warp(T0 + 25); // price 4 ether
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        o.execute{value: 4 ether}(abi.encode(buyer, uint256(4 ether), uint64(0)));
        assertEq(seller.balance, s0 + 3.96 ether);
        assertEq(treasury.balance, 0.04 ether);
    }

    function test_sale_futureStart_notStartedThenSuccess() public {
        nft.mint(seller, 4);
        Order o = _saleOrder(seller, nft, 4, _sched(1 ether, 1 ether, T0 + 100, T0 + 100), 0, seller, 10_000, 100);
        _activate(o); // activation does not require the start to have arrived
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.NotStarted.selector, T0 + 100));
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));

        vm.warp(T0 + 100);
        vm.prank(buyer);
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        assertEq(nft.ownerOf(4), buyer);
    }

    function test_sale_deadlineLEStartTime_rejectedAtActivation() public {
        nft.mint(seller, 5);
        // deadline passes Market.create (> now) but is <= startTime -> InvalidConfig at activation.
        Order o = _saleOrder(seller, nft, 5, _sched(1 ether, 1 ether, T0 + 200, T0 + 200), T0 + 100, seller, 10_000, 100);
        vm.prank(seller);
        vm.expectRevert(ExchangeAction.InvalidConfig.selector);
        o.activate();
    }

    function test_sale_maxPriceGuard() public {
        Order o = _listSale(seller, 6, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.AboveMaxPrice.selector, 1 ether, 0.5 ether));
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(0.5 ether), uint64(0)));
    }

    function test_sale_underpay() public {
        Order o = _listSale(seller, 7, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.Underpaid.selector, 1 ether, 0.5 ether));
        o.execute{value: 0.5 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
    }

    function test_sale_overpayRefundToActor() public {
        Order o = _listSale(seller, 8, 1 ether);
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        o.execute{value: 1.5 ether}(abi.encode(buyer, uint256(1.5 ether), uint64(0)));
        assertEq(buyer.balance, 1_000 ether - 1 ether, "paid price only, refunded the rest");
        assertEq(seller.balance, s0 + 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(address(o).balance, 0);
    }

    function test_sale_recipientZeroOrOrderRejected() public {
        Order o = _listSale(seller, 9, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(ExchangeAction.ZeroAddress.selector);
        o.execute{value: 1 ether}(abi.encode(address(0), uint256(1 ether), uint64(0)));

        vm.prank(buyer);
        vm.expectRevert(ExchangeAction.ZeroAddress.selector);
        o.execute{value: 1 ether}(abi.encode(address(o), uint256(1 ether), uint64(0)));
    }

    function test_sale_royaltyAboveLimit() public {
        rnft.mint(seller, 1);
        rnft.setRoyalty(creator, 2000); // 20%
        Order o = _saleOrder(seller, rnft, 1, _fixed(1 ether), 0, seller, 1000 /*max 10%*/, 100);
        _activate(o);
        vm.prank(buyer);
        // royalty 0.2 ether > limit 0.1 ether
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.RoyaltyAboveLimit.selector, 0.2 ether, 0.1 ether));
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
    }

    /// Per approved O5/D308: a 100% royalty is capped at price-fee; the trade settles.
    function test_sale_royaltyCappedAtPriceMinusFee() public {
        rnft.mint(seller, 2);
        rnft.setRoyalty(creator, 10_000); // 100%
        Order o = _saleOrder(seller, rnft, 2, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(o);
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        assertEq(rnft.ownerOf(2), buyer, "delivered");
        assertEq(creator.balance, 0.99 ether, "royalty receiver gets price - fee");
        assertEq(treasury.balance, 0.01 ether, "fee still paid");
        assertEq(seller.balance, s0, "proceeds zero");
        assertEq(address(o).balance, 0);
    }

    function test_sale_brokenRoyaltyReverts() public {
        BrokenRoyaltyNFT bnft = new BrokenRoyaltyNFT();
        bnft.mint(seller, 1);
        Order o = _saleOrder(seller, bnft, 1, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(o);
        vm.prank(buyer);
        vm.expectRevert(bytes("royalty broken"));
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
    }

    function test_sale_feeRecipientRejecterRevertsAtomically() public {
        Order o = _listSale(seller, 10, 1 ether);
        Rejecter rej = new Rejecter();
        vm.prank(feeAdmin);
        fees.setRecipient(address(rej)); // recipient read at execution
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        vm.expectRevert(); // Order.call bubbles the empty revert from the ETH send
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        // atomic: nothing moved
        assertEq(nft.ownerOf(10), address(o));
        assertEq(seller.balance, s0);
        assertEq(uint8(o.state()), uint8(OrderState.Live));
    }

    function test_sale_minLeftNonActionsRejected() public {
        Order o = _listSale(seller, 11, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(ExchangeAction.InvalidLifetime.selector);
        o.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(5)));
    }

    // =====================================================================
    // Fee admin
    // =====================================================================

    function test_fee_adminTwoStep() public {
        vm.prank(feeAdmin);
        fees.setAdmin(creator);
        assertEq(fees.pendingAdmin(), creator);
        assertEq(fees.admin(), feeAdmin, "not yet");
        vm.prank(creator);
        fees.acceptAdmin();
        assertEq(fees.admin(), creator);
        assertEq(fees.pendingAdmin(), address(0));
        // old admin can no longer set
        vm.prank(feeAdmin);
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        fees.setFee(10);
    }

    function test_fee_setFeeOnlyAffectsLaterActivations() public {
        nft.mint(seller, 20);
        nft.mint(seller, 21);
        Order a = _saleOrder(seller, nft, 20, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(a); // snapshots 100 bps
        vm.prank(feeAdmin);
        fees.setFee(50);
        Order b = _saleOrder(seller, nft, 21, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(b); // snapshots 50 bps

        vm.prank(buyer);
        a.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        vm.prank(buyer);
        b.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));
        // A paid 1%, B paid 0.5%, snapshot persisted through the rate change.
        assertEq(treasury.balance, 0.01 ether + 0.005 ether);
    }

    function test_fee_aboveIssuerMaxRejectsActivation() public {
        nft.mint(seller, 22);
        Order o = _saleOrder(seller, nft, 22, _fixed(1 ether), 0, seller, 10_000, 50 /*maxFeeBps < live 100*/);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.FeeAboveMax.selector, 100, 50));
        o.activate();
    }

    // =====================================================================
    // Obsolete listing: cancel / release
    // =====================================================================

    function test_release_cancelAndResidualRelease() public {
        Order o = _listSale(seller, 30, 1 ether); // residual = seller
        vm.prank(seller);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
        // residual releases the escrowed NFT to a recipient of its choice
        vm.prank(seller);
        o.release(creator, "");
        assertEq(nft.ownerOf(30), creator);
    }

    function test_release_nonResidualCannotPull() public {
        Order o = _listSale(seller, 31, 1 ether);
        vm.prank(seller);
        o.cancel();
        // attacker names itself: Order rejects (sender and recipient both != residual)
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(attacker, "");
        // attacker names the residual: Order allows, but the action rejects a non-residual actor
        vm.prank(attacker);
        vm.expectRevert(ActionBase.NotAuthorized.selector);
        o.release(seller, "");
        assertEq(nft.ownerOf(31), address(o), "still escrowed");
    }

    // =====================================================================
    // Bid: money flows
    // =====================================================================

    function test_bid_partialFundingThenReplenish() public {
        nft.mint(seller, 40);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(2 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.prank(seller);
        nft.approve(address(exchange), 40);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.InsufficientFunds.selector, 2 ether, 1 ether));
        o.execute(abi.encode(uint256(40), uint256(0), seller));

        // replenish by a plain ETH transfer, then it succeeds
        vm.prank(bidder);
        (bool ok,) = address(o).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 s0 = seller.balance;
        vm.prank(seller);
        o.execute(abi.encode(uint256(40), uint256(0), seller));
        assertEq(nft.ownerOf(40), bidder, "delivered to fixed recipient");
        assertEq(seller.balance, s0 + 1.98 ether, "proceeds");
        assertEq(treasury.balance, 0.02 ether);
        assertEq(address(o).balance, 0);
    }

    function test_bid_maxExecutionsThree() public {
        nft.mint(seller, 50);
        nft.mint(seller, 51);
        nft.mint(seller, 52);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(2 ether), bidder, 3, 0, 0, 6 ether);
        _activate(o);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(exchange), true);
        o.execute(abi.encode(uint256(50), uint256(0), creator));
        assertEq(exchange.executions(address(o)), 1);
        o.execute(abi.encode(uint256(51), uint256(0), creator));
        assertEq(exchange.executions(address(o)), 2);
        o.execute(abi.encode(uint256(52), uint256(0), creator));
        assertEq(exchange.executions(address(o)), 3);
        vm.stopPrank();
        assertEq(uint8(o.state()), uint8(OrderState.Completed), "completes on third");
        assertEq(nft.ownerOf(50), bidder);
        assertEq(nft.ownerOf(52), bidder);
        assertEq(creator.balance, 3 * 1.98 ether);
        assertEq(treasury.balance, 3 * 0.02 ether);
        assertEq(address(o).balance, 0);

        // a fourth execution is rejected: the order is no longer Live
        nft.mint(seller, 53);
        vm.startPrank(seller);
        vm.expectRevert(Order.WrongState.selector);
        o.execute(abi.encode(uint256(53), uint256(0), creator));
        vm.stopPrank();
    }

    function test_bid_maxExecutionsZeroRejected() public {
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 0, 0, 0, 1 ether);
        vm.prank(bidder);
        vm.expectRevert(ExchangeAction.InvalidConfig.selector);
        o.activate();
    }

    function test_bid_anyTokenWithTokenIdRejected() public {
        Order o = _bidOrder(bidder, nft, true, 7 /*nonzero with anyToken*/, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        vm.prank(bidder);
        vm.expectRevert(ExchangeAction.InvalidConfig.selector);
        o.activate();
    }

    function test_bid_specificTokenWrongToken() public {
        nft.mint(seller, 60);
        Order o = _bidOrder(bidder, nft, false, 60, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.WrongToken.selector, 61));
        o.execute(abi.encode(uint256(61), uint256(0), seller));
    }

    function test_bid_minProceedsGuard() public {
        nft.mint(seller, 62);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.startPrank(seller);
        nft.approve(address(exchange), 62);
        // proceeds = 0.99 ether, minProceeds 1 ether -> revert
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.BelowMinProceeds.selector, 0.99 ether, 1 ether));
        o.execute(abi.encode(uint256(62), uint256(1 ether), seller));
        vm.stopPrank();
    }

    function test_bid_attachedEthRejected() public {
        nft.mint(seller, 63);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.startPrank(seller);
        nft.approve(address(exchange), 63);
        vm.expectRevert(ExchangeAction.UnexpectedValue.selector);
        o.execute{value: 1 wei}(abi.encode(uint256(63), uint256(0), seller));
        vm.stopPrank();
    }

    function test_bid_proceedsToZeroRejected() public {
        nft.mint(seller, 64);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.startPrank(seller);
        nft.approve(address(exchange), 64);
        vm.expectRevert(ExchangeAction.ZeroAddress.selector);
        o.execute(abi.encode(uint256(64), uint256(0), address(0)));
        vm.stopPrank();
    }

    function test_bid_sellerNotOwnerNotHeld() public {
        nft.mint(seller, 65); // owned by seller, not attacker
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.prank(attacker);
        vm.expectRevert(ExchangeAction.NotHeld.selector);
        o.execute(abi.encode(uint256(65), uint256(0), attacker));
    }

    function test_bid_cancelThenWithdrawSurplus() public {
        nft.mint(seller, 66);
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(2 ether), bidder, 2, 0, 0, 5 ether);
        _activate(o);
        vm.startPrank(seller);
        nft.approve(address(exchange), 66);
        o.execute(abi.encode(uint256(66), uint256(0), seller)); // spends 2 ether
        vm.stopPrank();
        assertEq(o.freeBalance(), 3 ether);

        vm.prank(bidder);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
        assertEq(o.totalCredits(), 0, "credits untouched");

        uint256 b0 = bidder.balance;
        vm.prank(bidder);
        o.withdrawSurplus(bidder, 3 ether);
        assertEq(bidder.balance, b0 + 3 ether, "recovers exactly the remainder");
        assertEq(address(o).balance, 0);

        vm.prank(bidder);
        vm.expectRevert(Order.EncumberedBalance.selector);
        o.withdrawSurplus(bidder, 1);
    }

    /// A 100% royalty drives bid proceeds to zero (capped at price-fee); minProceeds protects the seller.
    function test_bid_royaltyCapAndMinProceeds() public {
        rnft.mint(seller, 3);
        rnft.setRoyalty(creator, 10_000); // 100%
        Order o = _bidOrder(bidder, rnft, true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        _activate(o);
        vm.startPrank(seller);
        rnft.approve(address(exchange), 3);
        // proceeds would be 0; a nonzero minProceeds protects the seller
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.BelowMinProceeds.selector, 0, 1));
        o.execute(abi.encode(uint256(3), uint256(1), seller));
        // with minProceeds 0 it settles: royalty receiver gets price - fee, seller gets 0
        uint256 s0 = seller.balance;
        o.execute(abi.encode(uint256(3), uint256(0), seller));
        vm.stopPrank();
        assertEq(rnft.ownerOf(3), bidder);
        assertEq(creator.balance, 0.99 ether);
        assertEq(treasury.balance, 0.01 ether);
        assertEq(seller.balance, s0, "seller proceeds zero");
    }

    // =====================================================================
    // Actions token trading
    // =====================================================================

    /// Lists an Actions token (from a covered Holder order) through an ExchangeAction sale.
    /// The resale premium is separate from the price the covered order charges.
    function _listActions(address owner, uint256 actionsId, uint256 premium, address proceedsTo, uint64 deadline)
        internal
        returns (Order o)
    {
        o = _create(
            owner,
            _spec(address(exchange), Admission.Public, deadline, owner, _saleCfg(IERC721(address(actions)), actionsId, _fixed(premium), proceedsTo, 10_000, 100)),
            0
        );
        vm.startPrank(owner);
        actions.transferFrom(owner, address(o), actionsId);
        o.activate();
        vm.stopPrank();
    }

    function test_actions_resalePremiumSeparateFromExecution() public {
        nft.mint(issuer, 100);
        Order cov = _issueCovered(address(nft), 100, 3 ether, uint64(T0 + 10 days));
        uint256 aid = _id(cov);
        assertEq(actions.ownerOf(aid), issuer);

        // issuer lists the Actions token for a 5 ether premium, paid to `seller` (a distinct payee)
        Order listing = _listActions(issuer, aid, 5 ether, seller, 0);
        uint256 sellerStart = seller.balance;

        vm.prank(buyer);
        listing.execute{value: 5 ether}(abi.encode(buyer, uint256(5 ether), uint64(0)));
        assertEq(actions.ownerOf(aid), buyer, "buyer receives the execution right");
        assertEq(seller.balance, sellerStart + 4.95 ether, "premium less fee to the Actions-token seller");
        assertEq(treasury.balance, 0.05 ether, "fee on the premium");

        // buyer now executes the underlying covered order
        uint256 issuerStart = issuer.balance;
        vm.prank(buyer);
        cov.execute{value: 3 ether}(abi.encode(buyer));
        assertEq(nft.ownerOf(100), buyer, "underlying NFT delivered");
        assertEq(uint8(cov.state()), uint8(OrderState.Completed));
        // execution price credited to the covered proceedsTo, no trading fee, no royalty on the premium
        assertEq(cov.creditOf(issuer), 3 ether, "full execution price credited, separate from premium");
        assertEq(treasury.balance, 0.05 ether, "no extra fee from the execution");
        cov.releaseCredit(issuer);
        assertEq(issuer.balance, issuerStart + 3 ether);
    }

    function test_actions_minActionTimeLeftBoundary() public {
        nft.mint(issuer, 101);
        uint64 dl = uint64(T0 + 10 days);
        Order cov = _issueCovered(address(nft), 101, 1 ether, dl);
        uint256 aid = _id(cov);
        Order listing = _listActions(issuer, aid, 1 ether, issuer, 0);

        uint256 remaining = dl - block.timestamp; // 10 days
        // requiring one second more than remains reverts at the boundary
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.ActionTimeLeft.selector, remaining, remaining + 1));
        listing.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(remaining + 1)));
        // requiring exactly what remains passes
        vm.prank(buyer);
        listing.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(remaining)));
        assertEq(actions.ownerOf(aid), buyer);
    }

    function test_actions_expiredUnderlyingUnexecutable() public {
        nft.mint(issuer, 102);
        uint64 dl = uint64(T0 + 1 days);
        Order cov = _issueCovered(address(nft), 102, 1 ether, dl);
        uint256 aid = _id(cov);
        Order listing = _listActions(issuer, aid, 1 ether, issuer, 0); // listing never expires

        vm.warp(dl); // underlying deadline reached -> not live
        vm.prank(buyer);
        vm.expectRevert(ExchangeAction.ActionNotLive.selector);
        listing.execute{value: 1 ether}(abi.encode(buyer, uint256(1 ether), uint64(0)));

        // cancel still works; release reverts because the token cannot move
        vm.prank(issuer);
        listing.cancel();
        assertEq(uint8(listing.state()), uint8(OrderState.Canceled));
        vm.prank(issuer);
        vm.expectRevert(ExchangeAction.ActionNotLive.selector);
        listing.release(issuer, "");
    }

    function test_actions_tokenSpecificBid() public {
        nft.mint(issuer, 103);
        Order cov = _issueCovered(address(nft), 103, 1 ether, uint64(T0 + 10 days));
        uint256 aid = _id(cov);

        // token-specific bid for that one Actions token
        Order o = _bidOrder(bidder, IERC721(address(actions)), false, aid, _fixed(2 ether), bidder, 1, 0, 0, 2 ether);
        _activate(o);
        uint256 i0 = issuer.balance;
        vm.startPrank(issuer);
        actions.approve(address(exchange), aid);
        o.execute(abi.encode(aid, uint256(0), issuer));
        vm.stopPrank();
        assertEq(actions.ownerOf(aid), bidder, "Actions token delivered to the bid recipient");
        assertEq(issuer.balance, i0 + 1.98 ether, "proceeds to seller");
        assertEq(treasury.balance, 0.02 ether);
    }

    function test_actions_collectionWideBidRejected() public {
        Order o = _bidOrder(bidder, IERC721(address(actions)), true, 0, _fixed(1 ether), bidder, 1, 0, 0, 1 ether);
        vm.prank(bidder);
        vm.expectRevert(ExchangeAction.InvalidConfig.selector);
        o.activate();
    }

    function test_actions_ordinaryNftBidWithMinLeftRejected() public {
        Order o = _bidOrder(bidder, nft, true, 0, _fixed(1 ether), bidder, 1, 5 /*minActionTimeLeft nonzero*/, 0, 1 ether);
        vm.prank(bidder);
        vm.expectRevert(ExchangeAction.InvalidConfig.selector);
        o.activate();
    }

    // =====================================================================
    // Multi-order atomic composition
    // =====================================================================

    function test_arbitrage_exactProfit() public {
        nft.mint(seller, 200);
        Order sale = _saleOrder(seller, nft, 200, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(sale);
        Order bid = _bidOrder(bidder, nft, true, 0, _fixed(2 ether), bidder, 1, 0, 0, 2 ether);
        _activate(bid);

        Arb arb = new Arb(exchange);
        uint256 s0 = seller.balance;
        arb.run{value: 1 ether}(sale, 1 ether, bid, nft, 200);

        assertEq(nft.ownerOf(200), bidder, "ends with the bidder");
        assertEq(address(arb).balance, 1.98 ether, "bought at 1, sold at 1.98 net: 0.98 profit on 1 in");
        assertEq(seller.balance, s0 + 0.99 ether, "sale proceeds");
        assertEq(treasury.balance, 0.01 ether + 0.02 ether, "fees on both legs");
    }

    function test_arbitrage_lastLegFailsRollsBack() public {
        nft.mint(seller, 201);
        Order sale = _saleOrder(seller, nft, 201, _fixed(1 ether), 0, seller, 10_000, 100);
        _activate(sale);
        // bid underfunded: its leg reverts InsufficientFunds, unwinding the whole transaction
        Order bid = _bidOrder(bidder, nft, true, 0, _fixed(2 ether), bidder, 1, 0, 0, 1 ether);
        _activate(bid);

        Arb arb = new Arb(exchange);
        uint256 s0 = seller.balance;
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.InsufficientFunds.selector, 2 ether, 1 ether));
        arb.run{value: 1 ether}(sale, 1 ether, bid, nft, 201);

        // every leg rolled back
        assertEq(nft.ownerOf(201), address(sale), "NFT still escrowed");
        assertEq(uint8(sale.state()), uint8(OrderState.Live));
        assertEq(seller.balance, s0, "no proceeds paid");
        assertEq(treasury.balance, 0, "no fees taken");
        assertEq(exchange.executions(address(bid)), 0, "bid counter untouched");
        assertEq(address(arb).balance, 0, "the reverted call delivered no ETH to arb");
    }
}
