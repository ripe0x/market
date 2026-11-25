// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProbeBase, ProbeAction, runComplete, encodeRun, oneStep, OP_CALLRAW} from "./Core.t.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Contract holder that, from a callback the action makes mid-execute, tries to move its own
/// Actions token. Proves a transfer during execution is blocked even for the genuine owner.
contract HolderContract {
    Actions immutable actions;
    Order public order;

    constructor(Actions a) {
        actions = a;
    }

    function setOrder(Order o) external {
        order = o;
    }

    function exec(bytes calldata input) external {
        order.execute(input);
    }

    function doTransfer(address to) external {
        actions.transferFrom(address(this), to, order.tokenId());
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract ActionsTokenTest is ProbeBase {
    bytes32 constant SALT = bytes32(uint256(0x70ce7));
    uint64 constant DL = T0 + 1 days;
    address operator = makeAddr("operator");

    function _liveHolder(address who) internal returns (Order o) {
        OrderSpec memory spec = _spec(address(probe), Admission.Holder, 0, issuer, bytes("holder-cfg"));
        vm.prank(who);
        o = market.create(spec, SALT);
        vm.prank(who);
        o.activate();
    }

    // ===================== happy path =====================

    function test_ownerExecutesAndBurns() public {
        Order o = _liveHolder(issuer);
        assertEq(actions.ownerOf(_id(o)), issuer);
        vm.prank(issuer);
        o.execute(runComplete(true));
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id(o)));
        actions.ownerOf(_id(o));
    }

    function test_ownerSurrendersAndBurns() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        o.surrender();
        assertEq(uint8(o.state()), uint8(OrderState.Surrendered));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id(o)));
        actions.ownerOf(_id(o));
    }

    // ===================== admission: who may act =====================

    function test_wrongHolderCannotExecute() public {
        Order o = _liveHolder(issuer);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.execute(runComplete(true));
    }

    function test_wrongHolderCannotSurrender() public {
        Order o = _liveHolder(issuer);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.surrender();
    }

    function test_approvedOperatorCannotExecuteOrSurrender() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        actions.approve(operator, _id(o));
        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.execute(runComplete(true));
        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.surrender();
    }

    function test_approvalForAllOperatorCannotExecute() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        actions.setApprovalForAll(operator, true);
        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.execute(runComplete(true));
    }

    /// @notice Documents inherent ERC721 behavior: an operator cannot execute, but can move the
    /// token to itself (order is live) and then act as the owner.
    function test_operatorTransfersToSelfThenExecutes() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        actions.approve(operator, _id(o));
        // Operator cannot execute while issuer owns it.
        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.execute(runComplete(true));
        // But may transfer to itself (order is live) ...
        vm.prank(operator);
        actions.transferFrom(issuer, operator, _id(o));
        assertEq(actions.ownerOf(_id(o)), operator);
        // ... and then execute as the new owner.
        vm.prank(operator);
        o.execute(runComplete(true));
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
    }

    function test_incompleteHolderExecutionReverts() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        vm.expectRevert(Order.Incomplete.selector);
        o.execute(runComplete(false));
    }

    function test_issuerCannotCancelLiveHolder() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        vm.expectRevert(Order.WrongState.selector);
        o.cancel();
    }

    // ===================== transfer guards =====================

    function test_transferDuringExecutionReverts() public {
        HolderContract hc = new HolderContract(actions);
        OrderSpec memory spec = _spec(address(probe), Admission.Holder, 0, issuer, bytes("hc-cfg"));
        vm.prank(address(hc));
        Order o = market.create(spec, SALT);
        hc.setOrder(o);
        vm.prank(address(hc));
        o.activate();
        assertEq(actions.ownerOf(_id(o)), address(hc));

        // Action, mid-execute, calls back into the holder which tries to move the token.
        bytes memory cb = abi.encodeCall(HolderContract.doTransfer, (buyer));
        bytes memory input = encodeRun(oneStep(OP_CALLRAW, address(hc), 0, cb), true, false);
        vm.expectRevert(Actions.InvalidTransfer.selector);
        hc.exec(input);
    }

    function test_transferToOrderItselfReverts() public {
        Order o = _liveHolder(issuer);
        vm.prank(issuer);
        vm.expectRevert(Actions.InvalidTransfer.selector);
        actions.transferFrom(issuer, address(o), _id(o));
    }

    function test_transferAfterDeadlineRevertsWithNoKeeperTx() public {
        OrderSpec memory spec = _spec(address(probe), Admission.Holder, DL, issuer, bytes("dl-cfg"));
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.warp(DL); // expired, but finalizeExpiry NOT called
        vm.prank(issuer);
        vm.expectRevert(Actions.InvalidTransfer.selector);
        actions.transferFrom(issuer, buyer, _id(o));
    }

    // ===================== mint / burn authority =====================

    function test_mintByNonOrderReverts() public {
        Order o = _liveHolder(issuer); // token already minted
        vm.prank(attacker);
        vm.expectRevert(Actions.NotOrder.selector);
        actions.mint(attacker, _id(o));
    }

    function test_burnByNonOrderReverts() public {
        Order o = _liveHolder(issuer);
        vm.prank(attacker);
        vm.expectRevert(Actions.NotOrder.selector);
        actions.burn(_id(o));
    }

    function test_mintForNonOrderIdReverts() public {
        uint256 bogus = uint256(uint160(address(0xA11CE)));
        vm.prank(attacker);
        vm.expectRevert(Actions.NotOrder.selector);
        actions.mint(attacker, bogus);
    }

    // ===================== expiry burns token =====================

    function test_expiryBurnsHolderToken() public {
        OrderSpec memory spec = _spec(address(probe), Admission.Holder, DL, issuer, bytes("exp-cfg"));
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        assertEq(actions.ownerOf(_id(o)), issuer);
        vm.warp(DL + 1);
        vm.prank(attacker);
        o.finalizeExpiry();
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id(o)));
        actions.ownerOf(_id(o));
    }
}
