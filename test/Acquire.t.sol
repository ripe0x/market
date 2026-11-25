// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {AcquireAndExecute} from "../periphery/AcquireAndExecute.sol";

/// A collection that refuses to transfer to one blocklisted address, for the delivery-failure
/// rollback test. Real contract, not a mock of a protocol party.
contract BlockingNFT is ERC721 {
    error Blocked();

    address public blocked;

    constructor() ERC721("Block", "BLK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setBlocked(address a) external {
        blocked = a;
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (to == blocked) revert Blocked();
        return super._update(to, id, auth);
    }
}

/// A refund recipient that reenters the helper from its receive hook.
contract ReenteringRefund {
    AcquireAndExecute public immutable acq;
    AcquireAndExecute.Params internal _p;

    constructor(AcquireAndExecute a) {
        acq = a;
    }

    function setParams(AcquireAndExecute.Params calldata p) external {
        _p = p;
    }

    receive() external payable {
        acq.acquireAndExecute(_p);
    }
}

/// Exact-receipt tests for AcquireAndExecute: buy a listed Actions token and execute its covered
/// order in one atomic call, with precise settlement and all-or-nothing rollback.
contract AcquireTest is Base {
    uint256 constant EXEC = 2 ether;
    uint256 constant PREMIUM = 3 ether;
    address recipient = makeAddr("recipient");

    BlockingNFT bnft;
    ReenteringRefund reenter;

    function setUp() public override {
        super.setUp();
        bnft = new BlockingNFT();
        reenter = new ReenteringRefund(acquire);
    }

    // ---- helpers ----

    /// Covered Holder account over `token` id, price EXEC, held and issued by issuer.
    function _account(IERC721 token, uint256 nftId) internal returns (Order o) {
        bytes memory cfg = abi.encode(CoveredNFTPurchase.Config(token, nftId, EXEC, issuer, 10_000));
        OrderSpec memory spec = _spec(address(covered), Admission.Holder, 0, issuer, cfg);
        o = _create(issuer, spec, 0);
        vm.startPrank(issuer);
        token.transferFrom(issuer, address(o), nftId);
        o.activate();
        vm.stopPrank();
    }

    /// List `account`'s Actions token for sale by issuer under `s`.
    function _list(Order account, ExchangeAction.Schedule memory s) internal returns (Order listing) {
        listing = _listToken(issuer, address(actions), _id(account), s, 0);
    }

    /// Standard TestNFT setup: account over nft id 1 + fixed-premium listing.
    function _standard() internal returns (Order account, Order listing) {
        nft.mint(issuer, 1);
        account = _account(IERC721(address(nft)), 1);
        listing = _list(account, _fixed(PREMIUM));
    }

    function _params(Order account, Order listing) internal view returns (AcquireAndExecute.Params memory) {
        return AcquireAndExecute.Params({
            listing: listing,
            account: account,
            nft: IERC721(address(nft)),
            tokenId: 1,
            executionPrice: EXEC,
            activationTermsHash: keccak256(account.activationTerms()),
            maxPremium: PREMIUM,
            maxTotal: PREMIUM + EXEC,
            recipient: recipient,
            refundTo: buyer,
            deadline: T0 + 1 days
        });
    }

    // ---- happy path ----

    function test_happyPathExactReceipts() public {
        (Order account, Order listing) = _standard();
        uint256 issuerBefore = issuer.balance;
        AcquireAndExecute.Params memory p = _params(account, listing);

        vm.prank(buyer);
        acquire.acquireAndExecute{value: 6 ether}(p);

        // Delivery and completion.
        assertEq(nft.ownerOf(1), recipient, "nft to recipient");
        assertEq(uint8(account.state()), uint8(OrderState.Completed), "underlying completed");
        assertEq(uint8(listing.state()), uint8(OrderState.Completed), "listing completed");
        vm.expectRevert();
        actions.ownerOf(_id(account)); // Actions token burned

        // Premium: 1% fee to treasury, remainder to the listing seller (issuer).
        assertEq(treasury.balance, 0.03 ether, "premium fee");
        assertEq(issuer.balance, issuerBefore + 2.97 ether, "premium proceeds");
        // Execution price credited inside the account to its proceedsTo (issuer).
        assertEq(account.creditOf(issuer), EXEC, "execution price credited");
        // Unused msg.value (6 - 5) refunded to refundTo (buyer); buyer net -5.
        assertEq(buyer.balance, 1_000 ether - 5 ether, "refund of unused value");
    }

    // ---- commitment mismatches ----

    function test_mismatchWrongAccount() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.account = listing; // not a covered order
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    function test_mismatchWrongListing() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.listing = account; // not an exchange sale
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    function test_mismatchWrongNft() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.nft = IERC721(address(rnft));
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    function test_mismatchWrongTokenId() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.tokenId = 999;
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    function test_mismatchWrongExecutionPrice() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.executionPrice = 1 ether;
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    function test_mismatchWrongActivationTermsHash() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.activationTermsHash = keccak256("nope");
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.Mismatch.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    // ---- price movement ----

    function test_premiumAboveMax_increasingSchedule() public {
        nft.mint(issuer, 1);
        Order account = _account(IERC721(address(nft)), 1);
        // Premium rises 1 -> 5 ether over [T0, T0+100].
        Order listing = _list(account, ExchangeAction.Schedule(1 ether, 5 ether, T0, T0 + 100));
        vm.warp(T0 + 50); // premium now 3 ether
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.maxPremium = 2 ether;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AcquireAndExecute.PriceAboveLimit.selector, 3 ether, 5 ether));
        acquire.acquireAndExecute{value: 10 ether}(p);
    }

    function test_totalAboveMax_decliningSchedule() public {
        nft.mint(issuer, 1);
        Order account = _account(IERC721(address(nft)), 1);
        // Premium falls 5 -> 1 ether over [T0, T0+100].
        Order listing = _list(account, ExchangeAction.Schedule(5 ether, 1 ether, T0, T0 + 100));
        vm.warp(T0 + 50); // premium now 3 ether
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.maxPremium = 10 ether;
        p.maxTotal = 4 ether; // premium 3 + exec 2 = 5 > 4
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AcquireAndExecute.PriceAboveLimit.selector, 3 ether, 5 ether));
        acquire.acquireAndExecute{value: 10 ether}(p);
    }

    // ---- deadline ----

    function test_deadlineEqualNowReverts() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.deadline = block.timestamp; // exclusive
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.DeadlinePassed.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
    }

    // ---- insufficient value ----

    function test_insufficientMsgValueReverts() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.maxTotal = 10 ether; // not the binding limit
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AcquireAndExecute.PriceAboveLimit.selector, PREMIUM, PREMIUM + EXEC));
        acquire.acquireAndExecute{value: 4 ether}(p); // total 5 > 4
    }

    // ---- refund recipient rejects ETH: whole tx reverts, nothing moves ----

    function test_refundRejecterRevertsAll() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.refundTo = address(bnft); // a contract with no payable receive
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.RefundFailed.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
        // All ownership unchanged.
        assertTrue(account.isLive());
        assertEq(nft.ownerOf(1), address(account), "nft still escrowed");
        assertEq(actions.ownerOf(_id(account)), address(listing), "token still listed");
    }

    // ---- reentry from the refund hook reverts ----

    function test_refundReentryReverts() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.refundTo = address(reenter);
        reenter.setParams(p);
        vm.prank(buyer);
        vm.expectRevert(AcquireAndExecute.RefundFailed.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);
        assertTrue(account.isLive());
        assertEq(actions.ownerOf(_id(account)), address(listing));
    }

    // ---- preexisting ETH neither spent nor refunded ----

    function test_preexistingEthUntouched() public {
        (Order account, Order listing) = _standard();
        vm.deal(address(acquire), 1 ether); // dust sitting in the helper
        AcquireAndExecute.Params memory p = _params(account, listing);
        vm.prank(buyer);
        acquire.acquireAndExecute{value: 6 ether}(p);
        assertEq(address(acquire).balance, 1 ether, "preexisting dust retained, not refunded");
        assertEq(buyer.balance, 1_000 ether - 5 ether, "only unused value refunded");
    }

    // ---- issuer acquires its own listed action, pays normally ----

    function test_issuerAcquiresOwn() public {
        (Order account, Order listing) = _standard();
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.refundTo = issuer;
        vm.prank(issuer);
        acquire.acquireAndExecute{value: 6 ether}(p);
        assertEq(nft.ownerOf(1), recipient);
        assertEq(uint8(account.state()), uint8(OrderState.Completed));
        assertEq(uint8(listing.state()), uint8(OrderState.Completed));
    }

    // ---- delivery failure rolls everything back ----

    function test_deliveryFailureRollsBack() public {
        bnft.mint(issuer, 1);
        bnft.setBlocked(recipient); // the eventual NFT recipient cannot receive
        Order account = _account(IERC721(address(bnft)), 1);
        Order listing = _list(account, _fixed(PREMIUM));
        AcquireAndExecute.Params memory p = _params(account, listing);
        p.nft = IERC721(address(bnft));
        p.activationTermsHash = keccak256(account.activationTerms());

        vm.prank(buyer);
        vm.expectRevert(BlockingNFT.Blocked.selector);
        acquire.acquireAndExecute{value: 6 ether}(p);

        // Nothing moved.
        assertTrue(account.isLive());
        assertEq(bnft.ownerOf(1), address(account), "nft still escrowed");
        assertEq(actions.ownerOf(_id(account)), address(listing), "token still listed");
        assertEq(buyer.balance, 1_000 ether, "payer untouched");
    }
}
