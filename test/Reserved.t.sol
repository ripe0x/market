// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {ReservedAction} from "../actions/ReservedAction.sol";
import {ActionBase} from "../actions/ActionBase.sol";
import {Artwork} from "../examples/Artwork.sol";
import {ReservedActionTarget} from "../reservations/ReservedActionTarget.sol";
import {IReservedActionTarget} from "../reservations/IReservedActionTarget.sol";

/// Tests for ReservedAction against the real Artwork target. The target records a reservation
/// for the order's predicted address before activation and enforces executor, operation,
/// deadline, value and single use itself; the order checks the match and credits the surplus.
contract ReservedTest is Base {
    uint8 constant PALETTE = 0;
    uint8 constant RENDERER = 1;
    uint256 constant ALL = type(uint256).max;

    IReservedActionTarget target;

    function setUp() public override {
        super.setUp();
        target = IReservedActionTarget(address(art));
    }

    // ---- helpers ----

    function _mintArt(uint256 id, address owner) internal {
        vm.prank(artist);
        art.mint(owner, id);
    }

    function _cfg(bytes memory op, uint256 price, uint256 targetValue, address proceedsTo)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(ReservedAction.Config(target, op, price, targetValue, proceedsTo));
    }

    /// Reserve for the predicted address, then create and activate. resDeadline/resValue are what
    /// the target records; they must match the order to activate.
    function _reserveAndActivate(
        Admission adm,
        uint64 orderDeadline,
        uint256 tokenId,
        uint8 kind,
        uint256 allowed,
        uint256 price,
        uint256 targetValue,
        address proceedsTo,
        uint64 resDeadline,
        uint256 resValue,
        bytes32 s
    ) internal returns (Order o, address predicted) {
        bytes memory op = art.operation(tokenId, kind, allowed);
        OrderSpec memory spec = _spec(address(reserved), adm, orderDeadline, issuer, _cfg(op, price, targetValue, proceedsTo));
        predicted = market.orderAddress(issuer, spec, s);
        vm.prank(holder);
        art.reserve(predicted, tokenId, kind, allowed, resDeadline, resValue);
        vm.prank(issuer);
        o = market.create(spec, s);
        assertEq(address(o), predicted, "reservation targeted the predicted address");
        vm.prank(issuer);
        o.activate();
    }

    function _state(address executor) internal view returns (IReservedActionTarget.ReservationState s) {
        (,,, s) = target.reservationOf(executor);
    }

    // ---- 1 + 13: predicted-address reservation, Public execution by a stranger, palette ----

    function test_publicPaletteByStranger() public {
        _mintArt(1, holder);
        (Order o,) = _reserveAndActivate(
            Admission.Public, 0, 1, PALETTE, ALL, 1 ether, 0, seller, 0, 0, bytes32(uint256(1))
        );
        // A stranger (not the artwork owner, not the issuer) executes.
        vm.prank(attacker);
        o.execute{value: 1 ether}(abi.encode(uint8(42)));
        assertEq(art.colorOf(1), 42, "palette set");
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        assertEq(o.creditOf(seller), 1 ether, "proceeds = price - targetValue");
        assertEq(uint8(_state(address(o))), uint8(IReservedActionTarget.ReservationState.Consumed));
    }

    // ---- 14 + renderer: Holder variant executed by the token holder, renderer op ----

    function test_holderRendererByTokenHolder() public {
        _mintArt(1, holder);
        (Order o,) = _reserveAndActivate(
            Admission.Holder, 0, 1, RENDERER, ALL, 2 ether, 0, seller, 0, 0, bytes32(uint256(1))
        );
        assertEq(actions.ownerOf(_id(o)), issuer, "holder token minted to issuer");
        vm.prank(issuer);
        o.execute{value: 2 ether}(abi.encode(uint8(9)));
        assertEq(art.rendererOf(1), 9, "renderer set");
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        assertEq(o.creditOf(seller), 2 ether);
    }

    // ---- 12: exact target value and proceeds credit ----

    function test_targetValueForwardedProceedsCredited() public {
        _mintArt(1, holder);
        (Order o,) = _reserveAndActivate(
            Admission.Public, 0, 1, PALETTE, ALL, 1 ether, 0.3 ether, seller, 0, 0.3 ether, bytes32(uint256(1))
        );
        vm.prank(attacker);
        o.execute{value: 1 ether}(abi.encode(uint8(5)));
        assertEq(address(art).balance, 0.3 ether, "targetValue forwarded to target");
        assertEq(o.creditOf(seller), 0.7 ether, "credit = price - targetValue");
        vm.prank(artist);
        art.withdraw();
        assertEq(artist.balance, 0.3 ether, "artist collected target value");
    }

    // ---- 12: target enforces exact value on a direct call ----

    function test_targetRejectsWrongValue() public {
        _mintArt(1, holder);
        bytes memory op = art.operation(1, PALETTE, ALL);
        vm.prank(holder);
        art.reserve(attacker, 1, PALETTE, ALL, 0, 0.3 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ReservedActionTarget.WrongValue.selector, 0.3 ether, 0.2 ether));
        art.performAction{value: 0.2 ether}(op, abi.encode(uint8(5)));
    }

    // ---- 2 + 3: owner cannot overwrite a live grant; ScopeReserved for a second grant ----

    function test_scopeReservedBlocksSecondGrant() public {
        _mintArt(1, holder);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, 0, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, 0, 0);
        // A second grant in the same scope is refused; the owner has no revoke or overwrite path.
        vm.prank(holder);
        vm.expectRevert(ReservedActionTarget.ScopeReserved.selector);
        art.reserve(attacker, 1, PALETTE, ALL, 0, 0);
        assertTrue(art.isScopeReserved(art.scopeOf(1, PALETTE)), "original grant intact");
    }

    // ---- 4: reservation survives artwork transfer ----

    function test_reservationSurvivesTransfer() public {
        _mintArt(1, holder);
        (Order o,) = _reserveAndActivate(
            Admission.Public, 0, 1, PALETTE, ALL, 1 ether, 0, seller, 0, 0, bytes32(uint256(1))
        );
        vm.prank(holder);
        art.transferFrom(holder, attacker, 1); // new owner
        assertTrue(art.isReservationLive(address(o)), "reservation still live after transfer");
        vm.prank(buyer);
        o.execute{value: 1 ether}(abi.encode(uint8(7)));
        assertEq(art.colorOf(1), 7);
    }

    // ---- 5: burn blocked while a reservation is live ----

    function test_burnBlockedWhileReserved() public {
        _mintArt(1, holder);
        _reserveAndActivate(Admission.Public, 0, 1, PALETTE, ALL, 1 ether, 0, seller, 0, 0, bytes32(uint256(1)));
        vm.prank(holder);
        vm.expectRevert(ReservedActionTarget.ScopeReserved.selector);
        art.burn(1);
    }

    // ---- 6: target-enforced expiry; the order also refuses past its deadline ----

    function test_expiryBlocksTargetAndOrder() public {
        _mintArt(1, holder);
        uint64 dl = uint64(T0 + 1000);
        (Order o,) = _reserveAndActivate(
            Admission.Public, dl, 1, PALETTE, ALL, 1 ether, 0, seller, dl, 0, bytes32(uint256(1))
        );
        vm.warp(dl);
        bytes memory op = art.operation(1, PALETTE, ALL);
        // Target refuses even the executor itself once its clock has passed the deadline.
        vm.prank(address(o));
        vm.expectRevert(ReservedActionTarget.NotReserved.selector);
        art.performAction(op, abi.encode(uint8(1)));
        // The order refuses too.
        vm.prank(attacker);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.execute{value: 1 ether}(abi.encode(uint8(1)));
    }

    // ---- 7: a consumed grant cannot be reused ----

    function test_consumedGrantNotReusable() public {
        _mintArt(1, holder);
        (Order o,) = _reserveAndActivate(
            Admission.Public, 0, 1, PALETTE, ALL, 1 ether, 0, seller, 0, 0, bytes32(uint256(1))
        );
        vm.prank(attacker);
        o.execute{value: 1 ether}(abi.encode(uint8(3)));
        // Order is Completed; a second execution is refused by the order.
        vm.prank(attacker);
        vm.expectRevert(Order.WrongState.selector);
        o.execute{value: 1 ether}(abi.encode(uint8(4)));
        // The target refuses a direct replay too.
        bytes memory op = art.operation(1, PALETTE, ALL);
        vm.prank(address(o));
        vm.expectRevert(ReservedActionTarget.NotReserved.selector);
        art.performAction(op, abi.encode(uint8(4)));
    }

    // ---- 8: executor address reuse rejected ----

    function test_executorReuseRejected() public {
        _mintArt(1, holder);
        _mintArt(2, holder);
        vm.prank(holder);
        art.reserve(attacker, 1, PALETTE, ALL, 0, 0);
        // Same executor, a different scope: refused because each address reserves once ever.
        vm.prank(holder);
        vm.expectRevert(ReservedActionTarget.ExecutorUsed.selector);
        art.reserve(attacker, 2, RENDERER, ALL, 0, 0);
    }

    // ---- 9: malformed operation rejected at reserve ----

    function test_malformedOperationRejectedAtReserve() public {
        _mintArt(1, holder);
        vm.prank(holder);
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.reserve(attacker, 1, 2, ALL, 0, 0); // kind > RENDERER
        vm.prank(holder);
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.reserve(attacker, 1, PALETTE, 0, 0, 0); // empty allowed set
    }

    // ---- 10: empty operation config rejected at activation ----

    function test_emptyOperationRejectedAtActivation() public {
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, 0, issuer, _cfg("", 1 ether, 0, seller));
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));
        vm.prank(issuer);
        vm.expectRevert(ReservedAction.InvalidConfig.selector);
        o.activate();
    }

    // ---- 11: deadline / value / operation mismatch rejected at activation ----

    function test_deadlineMismatchRejected() public {
        _mintArt(1, holder);
        uint64 orderDl = uint64(T0 + 2000);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, orderDl, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, uint64(T0 + 1000), 0); // reservation deadline != order deadline
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));
        vm.prank(issuer);
        vm.expectRevert(ReservedAction.ReservationMismatch.selector);
        o.activate();
    }

    function test_valueMismatchRejected() public {
        _mintArt(1, holder);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, 0, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, 0, 0.5 ether); // reserved value != config targetValue (0)
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));
        vm.prank(issuer);
        vm.expectRevert(ReservedAction.ReservationMismatch.selector);
        o.activate();
    }

    function test_operationMismatchRejected() public {
        _mintArt(1, holder);
        bytes memory configOp = art.operation(1, PALETTE, 0xFF); // config commits to this
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, 0, issuer, _cfg(configOp, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, 0x0F, 0, 0); // reserved a different allowed mask
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));
        vm.prank(issuer);
        vm.expectRevert(ReservedAction.ReservationMismatch.selector);
        o.activate();
    }

    // ---- 15 + 16: choice outside the allowed set reverts; reservation rolls back to Reserved ----

    function test_choiceOutsideAllowedRollsBack() public {
        _mintArt(1, holder);
        uint256 allowed = uint256(1) << 5; // only choice 5
        (Order o,) = _reserveAndActivate(
            Admission.Public, 0, 1, PALETTE, allowed, 1 ether, 0, seller, 0, 0, bytes32(uint256(1))
        );
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Artwork.ChoiceNotAllowed.selector, uint8(3)));
        o.execute{value: 1 ether}(abi.encode(uint8(3)));
        // Everything rolled back: order still Live, reservation still Reserved.
        assertEq(uint8(o.state()), uint8(OrderState.Live));
        assertEq(uint8(_state(address(o))), uint8(IReservedActionTarget.ReservationState.Reserved));
        assertTrue(art.isScopeReserved(art.scopeOf(1, PALETTE)));
        // A subsequent allowed execution still succeeds.
        vm.prank(attacker);
        o.execute{value: 1 ether}(abi.encode(uint8(5)));
        assertEq(art.colorOf(1), 5);
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
    }

    // ---- 18: expired scope re-reserved under a new executor; old cleanup must not clear it ----

    function test_oldCleanupDoesNotClearNewerGrant() public {
        _mintArt(1, holder);
        uint64 dl1 = uint64(T0 + 1000);
        bytes memory op = art.operation(1, PALETTE, ALL);

        // order1: reserved, Pending, with a deadline.
        OrderSpec memory spec1 = _spec(address(reserved), Admission.Public, dl1, issuer, _cfg(op, 1 ether, 0, seller));
        address p1 = market.orderAddress(issuer, spec1, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(p1, 1, PALETTE, ALL, dl1, 0);
        vm.prank(issuer);
        Order order1 = market.create(spec1, bytes32(uint256(1)));

        // Deadline passes; scope frees.
        vm.warp(T0 + 2000);
        assertFalse(art.isScopeReserved(art.scopeOf(1, PALETTE)));

        // order2: a fresh grant in the same scope under a new executor.
        uint64 dl2 = uint64(T0 + 3000);
        OrderSpec memory spec2 = _spec(address(reserved), Admission.Public, dl2, issuer, _cfg(op, 1 ether, 0, seller));
        address p2 = market.orderAddress(issuer, spec2, bytes32(uint256(2)));
        vm.prank(holder);
        art.reserve(p2, 1, PALETTE, ALL, dl2, 0);
        vm.prank(issuer);
        Order order2 = market.create(spec2, bytes32(uint256(2)));
        assertTrue(art.isReservationLive(p2));

        // Cleaning up the OLD order must not clear the newer grant.
        vm.prank(issuer);
        order1.release(issuer, "");
        assertEq(uint8(_state(p1)), uint8(IReservedActionTarget.ReservationState.Released));
        assertTrue(art.isReservationLive(p2), "newer grant untouched");
        assertEq(art.scopeExecutor(art.scopeOf(1, PALETTE)), p2, "scope still owned by order2");
        order2; // silence unused
    }

    // ---- 19: Pending release only by the residual (stranger griefing blocked) ----

    function test_pendingReleaseStrangerBlocked() public {
        _mintArt(1, holder);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, 0, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, 0, 0);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));

        // Stranger choosing itself: order gate rejects.
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(attacker, "");
        // Stranger routing to the residual: action rejects a Pending cleanup it did not own.
        vm.prank(attacker);
        vm.expectRevert(ActionBase.NotAuthorized.selector);
        o.release(issuer, "");
        assertTrue(art.isReservationLive(predicted), "grant survives griefing");
    }

    // ---- 20 + 21: terminal release by anyone; release idempotent ----

    function test_terminalReleaseByAnyoneIdempotent() public {
        _mintArt(1, holder);
        uint64 dl = uint64(T0 + 1000);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, dl, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, dl, 0);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));

        vm.warp(dl);
        o.finalizeExpiry();
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
        // Anyone may clean up a terminal order (routing to the residual).
        vm.prank(attacker);
        o.release(issuer, "");
        assertEq(uint8(_state(predicted)), uint8(IReservedActionTarget.ReservationState.Released));
        // Idempotent: a second release does nothing and does not revert.
        vm.prank(buyer);
        o.release(issuer, "");
        assertEq(uint8(_state(predicted)), uint8(IReservedActionTarget.ReservationState.Released));
    }

    // ---- 22: release works after the artwork is burned (post reservation expiry) ----

    function test_releaseAfterArtworkBurned() public {
        _mintArt(1, holder);
        uint64 dl = uint64(T0 + 1000);
        bytes memory op = art.operation(1, PALETTE, ALL);
        OrderSpec memory spec = _spec(address(reserved), Admission.Public, dl, issuer, _cfg(op, 1 ether, 0, seller));
        address predicted = market.orderAddress(issuer, spec, bytes32(uint256(1)));
        vm.prank(holder);
        art.reserve(predicted, 1, PALETTE, ALL, dl, 0);
        vm.prank(issuer);
        Order o = market.create(spec, bytes32(uint256(1)));

        vm.warp(dl); // reservation no longer live
        vm.prank(holder);
        art.burn(1); // allowed now that the scope is free
        // Residual cleanup still works although the artwork is gone.
        vm.prank(issuer);
        o.release(issuer, "");
        assertEq(uint8(_state(predicted)), uint8(IReservedActionTarget.ReservationState.Released));
    }
}
