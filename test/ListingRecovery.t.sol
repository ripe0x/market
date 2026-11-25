// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./utils/Base.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";

/// The client lists in three transactions: create, deposit the NFT, activate. These tests stop the
/// flow at every point and check the seller's NFT always comes back, including the two-transaction
/// alternative (deposit to the predicted address, then createAndActivate) when it lands late.
contract ListingRecoveryTest is Base {
    uint256 constant ID = 7;
    uint64 constant DEADLINE = 2_000_000_000;

    function _spec(uint64 deadline, uint16 maxFeeBps) internal view returns (OrderSpec memory) {
        bytes memory cfg = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale,
                nft,
                _fixed(1 ether),
                maxFeeBps,
                abi.encode(ExchangeAction.SaleTerms(ID, seller, 10_000))
            )
        );
        return _spec(address(exchange), Admission.Public, deadline, seller, cfg);
    }

    /// Steps 1 and 2 of the client flow: create, then deposit. Not activated.
    function _createAndDeposit(uint64 deadline, uint16 maxFeeBps) internal returns (Order o) {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        o = _create(seller, _spec(deadline, maxFeeBps), 0);
        vm.prank(seller);
        nft.transferFrom(seller, address(o), ID);
        assertEq(nft.ownerOf(ID), address(o));
        assertEq(uint8(o.state()), uint8(OrderState.Pending));
    }

    function _recover(Order o) internal {
        vm.prank(seller);
        o.release(seller, "");
        assertEq(nft.ownerOf(ID), seller, "NFT back with seller");
    }

    // ---- stop after create: nothing deposited, nothing at risk ----

    function test_stopAfterCreate_nothingHeld() public {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        Order o = _create(seller, _spec(DEADLINE, 10_000), 0);
        assertEq(nft.ownerOf(ID), seller);
        assertEq(address(o).balance, 0);
    }

    // ---- stop after deposit, never activated ----

    function test_pending_releaseWithoutCancel() public {
        _recover(_createAndDeposit(DEADLINE, 10_000));
    }

    function test_pending_cancelThenRelease() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        vm.prank(seller);
        o.cancel();
        _recover(o);
    }

    function test_pending_pastDeadline_releaseWithoutFinalize() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        vm.warp(DEADLINE + 1);
        vm.prank(seller);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.activate();
        _recover(o);
    }

    function test_pending_pastDeadline_finalizeThenRelease() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        vm.warp(DEADLINE + 1);
        vm.prank(attacker);
        o.finalizeExpiry();
        _recover(o);
    }

    /// Activation can fail for good (live fee above the seller's cap); the NFT still comes back.
    function test_pending_activationRejected_release() public {
        Order o = _createAndDeposit(DEADLINE, 50);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ExchangeAction.FeeAboveMax.selector, 100, 50));
        o.activate();
        _recover(o);
    }

    /// Nobody else can pull the NFT out of a pending order, or force it elsewhere.
    function test_pending_strangerCannotRelease() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(attacker, "");
        vm.prank(attacker);
        vm.expectRevert();
        o.release(seller, "");
        assertEq(nft.ownerOf(ID), address(o));
    }

    /// A deposit into an order that was already canceled is still recoverable.
    function test_depositAfterCancel_release() public {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        Order o = _create(seller, _spec(DEADLINE, 10_000), 0);
        vm.prank(seller);
        o.cancel();
        vm.prank(seller);
        nft.transferFrom(seller, address(o), ID);
        _recover(o);
    }

    // ---- activated (live) listings ----

    function test_live_cancelThenRelease() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        _activate(o);
        vm.prank(seller);
        o.cancel();
        _recover(o);
    }

    /// After the deadline a live listing cannot be canceled or released until someone records the
    /// expiry. Anyone can do that, then the seller releases.
    function test_live_pastDeadline_needsFinalizeThenRelease() public {
        Order o = _createAndDeposit(DEADLINE, 10_000);
        _activate(o);
        vm.warp(DEADLINE + 1);
        vm.prank(seller);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.cancel();
        vm.prank(seller);
        vm.expectRevert(Order.WrongState.selector);
        o.release(seller, "");
        vm.prank(seller);
        o.finalizeExpiry();
        _recover(o);
    }

    // ---- the two-transaction alternative ----

    /// Deposit first to the predicted address, then createAndActivate. If the deadline passes
    /// before the second transaction lands, activation fails, but `create` still deploys the
    /// order at the predicted address and the seller releases the NFT.
    function test_depositFirst_pastDeadline_recoverable() public {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        OrderSpec memory spec = _spec(DEADLINE, 10_000);
        bytes32 s = bytes32(uint256(999));
        address predicted = market.orderAddress(seller, spec, s);
        vm.prank(seller);
        nft.transferFrom(seller, predicted, ID);

        vm.warp(DEADLINE);
        vm.prank(seller);
        vm.expectRevert(Order.DeadlinePassed.selector);
        market.createAndActivate(spec, s);

        vm.prank(seller);
        Order o = market.create(spec, s);
        assertEq(address(o), predicted);
        assertFalse(o.isLive());
        _recover(o);
    }

    /// Anyone else creating that late order cannot take the NFT: the issuer is part of the address,
    /// so a stranger's create lands elsewhere.
    function test_depositFirst_strangerCreateMisses() public {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        OrderSpec memory spec = _spec(DEADLINE, 10_000);
        bytes32 s = bytes32(uint256(999));
        address predicted = market.orderAddress(seller, spec, s);
        vm.prank(seller);
        nft.transferFrom(seller, predicted, ID);
        vm.warp(DEADLINE + 1);
        vm.prank(attacker);
        Order o = market.create(spec, s);
        assertTrue(address(o) != predicted);
        assertEq(nft.ownerOf(ID), predicted);
    }

    /// Same deposit with the spec in hand and the deadline still ahead: recoverable by creating
    /// the order. Losing any byte of the spec or salt leaves it stranded.
    function test_depositFirst_beforeDeadline_recoverable() public {
        vm.warp(1_900_000_000);
        nft.mint(seller, ID);
        OrderSpec memory spec = _spec(DEADLINE, 10_000);
        bytes32 s = bytes32(uint256(999));
        address predicted = market.orderAddress(seller, spec, s);
        vm.prank(seller);
        nft.transferFrom(seller, predicted, ID);

        OrderSpec memory other = _spec(DEADLINE + 1, 10_000);
        vm.prank(seller);
        Order wrong = market.create(other, s);
        assertTrue(address(wrong) != predicted, "a different spec misses the NFT");

        vm.prank(seller);
        Order o = market.createAndActivate(spec, s);
        assertEq(address(o), predicted);
        vm.prank(seller);
        o.cancel();
        _recover(o);
    }
}
