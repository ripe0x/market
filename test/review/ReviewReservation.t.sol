// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../../src/Market.sol";
import {Order, OrderSpec, Admission} from "../../src/Order.sol";
import {ReservedAction} from "../../actions/ReservedAction.sol";
import {ReservedActionTarget} from "../../reservations/ReservedActionTarget.sol";
import {IReservedActionTarget} from "../../reservations/IReservedActionTarget.sol";
import {Artwork} from "../../examples/Artwork.sol";

contract ReviewReservation is Test {
    Market market;
    ReservedAction reserved;
    Artwork art;

    address artist = address(0xA27);
    address victim = address(0x5151);
    address attacker = address(0xBAD00);

    function setUp() public {
        market = new Market();
        reserved = new ReservedAction(market);
        art = new Artwork(artist);
    }

    // A third party who can predict a ReservedAction order address AND owns any token on the
    // target can permanently "poison" that address: _reserve reverts ExecutorUsed for it ever
    // after, so the intended issuer can never obtain a matching Reserved record there.
    function test_reservation_executor_poisoning() public {
        // victim intends to run a reserved palette change on token 1 (owned by victim)
        vm.prank(artist);
        art.mint(victim, 1);
        // attacker owns an unrelated token 2
        vm.prank(artist);
        art.mint(attacker, 2);

        uint64 dl = uint64(block.timestamp + 1 days);
        bytes memory op = art.operation(1, art.PALETTE(), uint256(0x2)); // allow choice 1

        ReservedAction.Config memory c = ReservedAction.Config({
            target: IReservedActionTarget(address(art)),
            operation: op,
            price: 0,
            targetValue: 0,
            proceedsTo: victim
        });
        OrderSpec memory spec = OrderSpec({
            action: address(reserved),
            admission: Admission.Public,
            deadline: dl,
            residual: victim,
            config: abi.encode(c)
        });
        // Predictable salt (e.g. a UI convention) => P is knowable before reservation.
        bytes32 salt = bytes32(uint256(1));
        address P = market.orderAddress(victim, spec, salt);

        // ATTACK: attacker reserves P as executor for THEIR OWN token 2's palette scope.
        vm.prank(attacker);
        art.reserve(P, 2, uint8(0), uint256(0x1), dl, 0);

        // Now P has a reservation record (for a different operation). The victim creates the
        // order at P, but activation fails: operation hash mismatch.
        vm.deal(victim, 0);
        vm.prank(victim);
        Order o = market.create(spec, salt);
        assertEq(address(o), P, "predicted address");
        vm.prank(victim);
        vm.expectRevert(ReservedAction.ReservationMismatch.selector);
        o.activate();

        // And the victim (even as token-1 owner) can NEVER place the correct reservation for P:
        vm.prank(victim);
        vm.expectRevert(ReservedActionTarget.ExecutorUsed.selector);
        art.reserve(P, 1, uint8(0), uint256(0x2), dl, 0);

        // The order at P is permanently unactivatable against this target. No funds are lost
        // (price/targetValue were 0 here), but the chosen account address is bricked.
    }

    // Positive control: with an unpredictable salt the victim reserves first and succeeds.
    function test_reservation_happy_path() public {
        vm.prank(artist);
        art.mint(victim, 1);

        uint64 dl = uint64(block.timestamp + 1 days);
        bytes memory op = art.operation(1, art.PALETTE(), uint256(0x2));
        ReservedAction.Config memory c = ReservedAction.Config({
            target: IReservedActionTarget(address(art)),
            operation: op,
            price: 0,
            targetValue: 0,
            proceedsTo: victim
        });
        OrderSpec memory spec = OrderSpec({
            action: address(reserved),
            admission: Admission.Public,
            deadline: dl,
            residual: victim,
            config: abi.encode(c)
        });
        bytes32 salt = keccak256("secret");
        address P = market.orderAddress(victim, spec, salt);

        vm.prank(victim);
        art.reserve(P, 1, uint8(0), uint256(0x2), dl, 0);
        vm.prank(victim);
        Order o = market.create(spec, salt);
        vm.prank(victim);
        o.activate();

        // anyone can execute a Public reserved action; choose palette option 1
        o.execute(abi.encode(uint8(1)));
        assertEq(art.colorOf(1), 1, "palette changed via reserved action");
        (,,, IReservedActionTarget.ReservationState s) = art.reservationOf(P);
        assertEq(uint8(s), uint8(IReservedActionTarget.ReservationState.Consumed));
    }
}
