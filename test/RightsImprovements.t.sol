// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../src/Market.sol";
import {Right, IExerciseHandler} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {Artwork} from "../examples/Artwork.sol";
import {ReservedPaint} from "../examples/ReservedPaint.sol";

contract CounterfeitReservation {
    function market() external view returns (CounterfeitReservation) {
        return this;
    }

    function isRight(address) external pure returns (bool) {
        return true;
    }

    function state() external pure returns (Right.State) {
        return Right.State.Pending;
    }
}

contract RevertingReservationGetters {
    fallback() external {
        revert("untrusted getter reached");
    }
}

contract MintAttackHandler is IExerciseHandler {
    bool public minted;
    bool public burned;

    function validate(address, bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function onExercise(address holder, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        returns (bytes memory)
    {
        Right right = Right(payable(msg.sender));
        Rights rights = right.rights();
        uint256 id = right.tokenId();
        (minted,) = address(right)
            .call(abi.encodeCall(Right.execute, (address(rights), 0, abi.encodeCall(Rights.mint, (holder, id)))));
        (burned,) =
            address(right).call(abi.encodeCall(Right.execute, (address(rights), 0, abi.encodeCall(Rights.burn, (id)))));
        require(rights.ownerOf(id) == holder && rights.balanceOf(holder) == 1, "ownership changed");
        return "";
    }
}

contract RightsImprovementsTest is Test {
    Market market;
    Rights rights;
    MintAttackHandler handler;
    Artwork art;
    ReservedPaint paint;

    function setUp() public {
        vm.warp(1_000_000);
        market = new Market();
        rights = market.rights();
        handler = new MintAttackHandler();
        art = new Artwork(market);
        paint = new ReservedPaint(market);
        art.mint(address(this), 1);
    }

    function _pending(Market factory, uint256 salt) internal returns (Right) {
        return factory.createRight(handler, "", block.timestamp + 1 days, address(this), bytes32(salt));
    }

    function test_counterfeitSelfAuthenticatingAccountRejected() public {
        CounterfeitReservation fake = new CounterfeitReservation();
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.reserve(1, Right(payable(address(fake))), 2);
    }

    function test_unknownAccountRejectedBeforeAnyGetter() public {
        RevertingReservationGetters fake = new RevertingReservationGetters();
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.reserve(1, Right(payable(address(fake))), 2);
    }

    function test_genuineForeignMarketAccountRejected() public {
        Right foreignRight = _pending(new Market(), 1);
        vm.expectRevert(Artwork.NotAllowed.selector);
        art.reserve(1, foreignRight, 2);
    }

    function test_pendingAndTerminatedReservationsCanBeReplaced() public {
        Right first = _pending(market, 1);
        Right second = _pending(market, 2);
        art.reserve(1, first, 2);
        art.reserve(1, second, 4);
        (address current,) = art.reservation(1);
        assertEq(current, address(second));
        second.cancelSetup();
        art.reserve(1, first, 2);
        first.activate("");
        vm.expectRevert(Artwork.ReservationLive.selector);
        art.reserve(1, second, 4);
        first.surrender();
        Right third = _pending(market, 3);
        art.reserve(1, third, 8);
        (current,) = art.reservation(1);
        assertEq(current, address(third));
    }

    function test_expiredActiveReservationCanBeReplacedBeforeFinalization() public {
        Right first = _pending(market, 1);
        art.reserve(1, first, 2);
        first.activate("");
        vm.warp(first.deadline());
        Right second = _pending(market, 2);
        art.reserve(1, second, 4);
        (address current,) = art.reservation(1);
        assertEq(current, address(second));
    }

    function test_duplicateMintAndEarlyBurnThroughExerciseRejected() public {
        Right right = _pending(market, 1);
        right.activate("");
        right.exercise("", "");
        assertFalse(handler.minted());
        assertFalse(handler.burned());
        assertEq(uint256(right.state()), uint256(Right.State.Exercised));
        assertEq(rights.balanceOf(address(this)), 0);
        uint256 id = right.tokenId();
        vm.expectRevert();
        rights.ownerOf(id);
        vm.expectRevert(Rights.NotBackingAccount.selector);
        right.recover(address(rights), 0, abi.encodeCall(Rights.mint, (address(this), id)));
        vm.expectRevert();
        right.recover(address(rights), 0, abi.encodeCall(Rights.burn, (id)));
    }

    function test_canceledSetupCannotMintOrBurnThroughRecovery() public {
        Right right = _pending(market, 1);
        right.cancelSetup();
        uint256 id = right.tokenId();
        vm.expectRevert(Rights.NotBackingAccount.selector);
        right.recover(address(rights), 0, abi.encodeCall(Rights.mint, (address(this), id)));
        vm.expectRevert();
        right.recover(address(rights), 0, abi.encodeCall(Rights.burn, (id)));
        assertEq(rights.balanceOf(address(this)), 0);
    }

    function test_counterfeitCannotMintCanonicalToken() public {
        CounterfeitReservation fake = new CounterfeitReservation();
        vm.prank(address(fake));
        vm.expectRevert(Rights.NotBackingAccount.selector);
        rights.mint(address(this), uint256(uint160(address(fake))));
    }
}
