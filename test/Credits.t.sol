// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ProbeBase,
    ProbeAction,
    encodeRun,
    runComplete,
    oneStep,
    twoSteps,
    Step,
    OP_CREDIT,
    OP_PAY
} from "./Core.t.sol";
import {Rejecter} from "./utils/Mocks.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";

/// @dev A credit beneficiary that reenters the order while being paid. The reentry lands in the
/// Withdrawing phase and must be rejected, so the whole payout reverts atomically.
contract ReentrantPayee {
    Order public order;

    function arm(Order o) external {
        order = o;
    }

    receive() external payable {
        if (address(order) != address(0)) order.releaseCredit(address(this));
    }
}

contract CreditsTest is ProbeBase {
    address beneficiary = makeAddr("beneficiaryX");
    address dest = makeAddr("creditDest");

    function _funded(uint256 value, uint64 dl) internal returns (Order o) {
        OrderSpec memory spec = _spec(address(probe), Admission.Public, dl, issuer, bytes("credit-cfg"));
        o = _create(issuer, spec, value);
        vm.prank(issuer);
        o.activate();
    }

    /// Execute once, crediting `amount` to `beneficiary`; `complete` decides whether it finishes.
    function _creditVia(Order o, uint256 amount, bool complete) internal {
        vm.prank(buyer);
        o.execute(encodeRun(oneStep(OP_CREDIT, beneficiary, amount, ""), complete, false));
    }

    // ===================== credit authority & timing =====================

    function test_creditByStrangerReverts() public {
        Order o = _funded(3 ether, 0);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.credit(beneficiary, 1 ether);
    }

    function test_creditDuringReleaseReverts() public {
        // Action is the caller, but release runs in the Releasing phase, not Executing.
        OrderSpec memory spec = _spec(address(probe), Admission.Public, 0, issuer, bytes("rel-cfg"));
        Order o = _create(issuer, spec, 1 ether); // Pending
        bytes memory input = encodeRun(oneStep(OP_CREDIT, beneficiary, 1, ""), false, false);
        vm.prank(issuer);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(issuer, input);
    }

    function test_creditOverFreeBalanceReverts() public {
        Order o = _funded(1 ether, 0);
        vm.prank(buyer);
        vm.expectRevert(Order.EncumberedBalance.selector);
        o.execute(encodeRun(oneStep(OP_CREDIT, beneficiary, 2 ether, ""), true, false));
    }

    // ===================== withdrawals =====================

    function test_releaseCreditByStrangerPaysBeneficiary() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 2 ether, true);
        assertEq(o.creditOf(beneficiary), 2 ether);
        assertEq(o.totalCredits(), 2 ether);

        vm.prank(attacker); // a stranger may trigger payment, but only to the beneficiary
        o.releaseCredit(beneficiary);
        assertEq(beneficiary.balance, 2 ether, "beneficiary not paid");
        assertEq(o.creditOf(beneficiary), 0);
        assertEq(o.totalCredits(), 0);
        assertEq(address(o).balance, 1 ether, "surplus wrongly moved");
    }

    function test_withdrawCreditRedirectOnlyByBeneficiary() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 2 ether, true);

        // A stranger "redirecting" only withdraws its own (zero) credit: a no-op.
        vm.prank(attacker);
        o.withdrawCredit(dest);
        assertEq(dest.balance, 0, "stranger redirected someone else's credit");
        assertEq(o.creditOf(beneficiary), 2 ether, "credit changed by stranger");

        // The beneficiary redirects its own credit anywhere.
        vm.prank(beneficiary);
        o.withdrawCredit(dest);
        assertEq(dest.balance, 2 ether, "beneficiary redirect failed");
        assertEq(o.creditOf(beneficiary), 0);
    }

    function test_failedRecipientRestoresLiability() public {
        Rejecter rejecter = new Rejecter(); // no payable fallback -> send fails
        Order o = _funded(3 ether, 0);
        vm.prank(buyer);
        o.execute(encodeRun(oneStep(OP_CREDIT, address(rejecter), 2 ether, ""), true, false));
        assertEq(o.creditOf(address(rejecter)), 2 ether);

        vm.expectRevert(Order.TransferFailed.selector);
        o.releaseCredit(address(rejecter));

        // Liability restored by the revert.
        assertEq(o.creditOf(address(rejecter)), 2 ether, "liability lost");
        assertEq(o.totalCredits(), 2 ether, "totalCredits lost");
        assertEq(address(o).balance, 3 ether, "balance moved on failed send");
    }

    // ===================== credits survive terminal states =====================

    function test_creditsSurviveCompleted() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 2 ether, true);
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        o.releaseCredit(beneficiary);
        assertEq(beneficiary.balance, 2 ether);
    }

    function test_creditsSurviveCanceled() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 2 ether, false); // stays Live
        vm.prank(issuer);
        o.cancel(); // Live Public -> Canceled
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
        assertEq(o.creditOf(beneficiary), 2 ether);
        o.releaseCredit(beneficiary);
        assertEq(beneficiary.balance, 2 ether);
    }

    function test_creditsSurviveExpired() public {
        uint64 dl = T0 + 1 days;
        Order o = _funded(3 ether, dl);
        _creditVia(o, 2 ether, false); // stays Live
        vm.warp(dl + 1);
        o.finalizeExpiry(); // -> Expired
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
        assertEq(o.creditOf(beneficiary), 2 ether);
        o.releaseCredit(beneficiary);
        assertEq(beneficiary.balance, 2 ether);
    }

    // ===================== withdrawSurplus =====================

    function test_withdrawSurplusOnlyResidual() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 1 ether, true); // Completed, non-Live
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.withdrawSurplus(attacker, 1 ether);
    }

    function test_withdrawSurplusRejectedWhileLive() public {
        Order o = _funded(3 ether, 0); // Live
        vm.prank(issuer);
        vm.expectRevert(Order.WrongState.selector);
        o.withdrawSurplus(issuer, 1 ether);
    }

    function test_withdrawSurplusNeverSpendsCredits() public {
        Order o = _funded(3 ether, 0);
        _creditVia(o, 2 ether, true); // Completed; free balance now 1 ether
        // Cannot pull the credited portion.
        vm.prank(issuer);
        vm.expectRevert(Order.EncumberedBalance.selector);
        o.withdrawSurplus(issuer, 2 ether);
        // Can pull exactly the surplus.
        uint256 before = issuer.balance;
        vm.prank(issuer);
        o.withdrawSurplus(issuer, 1 ether);
        assertEq(issuer.balance, before + 1 ether);
        assertEq(address(o).balance, 2 ether, "credits touched");
        // The credits remain claimable.
        o.releaseCredit(beneficiary);
        assertEq(beneficiary.balance, 2 ether);
        assertEq(address(o).balance, 0);
    }

    // ===================== call cannot spend credited funds =====================

    function test_callCannotSpendCreditedFunds() public {
        Order o = _funded(3 ether, 0);
        // Credit 2 ether, then try to pay out 2 ether via o.call: only 1 ether is free.
        Step[] memory steps = twoSteps(
            Step(OP_CREDIT, beneficiary, 2 ether, ""),
            Step(OP_PAY, dest, 2 ether, "")
        );
        vm.prank(buyer);
        vm.expectRevert(Order.EncumberedBalance.selector);
        o.execute(encodeRun(steps, true, false));
    }

    function test_reentrantPayoutRevertsAndPreservesCredit() public {
        ReentrantPayee payee = new ReentrantPayee();
        Order o = _funded(3 ether, 0);
        vm.prank(buyer);
        o.execute(encodeRun(oneStep(OP_CREDIT, address(payee), 2 ether, ""), true, false));
        payee.arm(o);
        // Payout triggers the payee's receive, which reenters during the Withdrawing phase
        // (Busy); the failed receive makes the send fail, so the payout reverts atomically.
        vm.expectRevert(Order.TransferFailed.selector);
        o.releaseCredit(address(payee));
        assertEq(o.creditOf(address(payee)), 2 ether, "credit lost on reverted payout");
        assertEq(o.totalCredits(), 2 ether);
        assertEq(address(o).balance, 3 ether);
    }

    // ===================== atomicity =====================

    function test_atomicityPublicRevertRollsBack() public {
        Order o = _funded(3 ether, 0);
        Step[] memory steps = twoSteps(
            Step(OP_PAY, dest, 1 ether, ""),
            Step(OP_CREDIT, beneficiary, 1 ether, "")
        );
        vm.prank(buyer);
        vm.expectRevert(ProbeAction.ProbeRevert.selector);
        o.execute(encodeRun(steps, false, true)); // doRevert

        assertEq(address(o).balance, 3 ether, "payment not rolled back");
        assertEq(dest.balance, 0, "recipient kept payment");
        assertEq(o.creditOf(beneficiary), 0, "credit not rolled back");
        assertEq(o.totalCredits(), 0, "counter not rolled back");
        assertEq(uint8(o.state()), uint8(OrderState.Live), "state changed despite revert");
    }

    function test_atomicityHolderRevertKeepsTokenAndState() public {
        OrderSpec memory spec = _spec(address(probe), Admission.Holder, 0, issuer, bytes("holder-atomic"));
        Order o = _create(issuer, spec, 3 ether);
        vm.prank(issuer);
        o.activate();
        assertEq(actions.ownerOf(_id(o)), issuer);

        // Would complete (and burn) but reverts first: nothing commits.
        bytes memory input = encodeRun(oneStep(OP_CREDIT, beneficiary, 1 ether, ""), true, true);
        vm.prank(issuer);
        vm.expectRevert(ProbeAction.ProbeRevert.selector);
        o.execute(input);

        assertEq(uint8(o.state()), uint8(OrderState.Live), "state changed");
        assertEq(actions.ownerOf(_id(o)), issuer, "token burned despite revert");
        assertEq(o.creditOf(beneficiary), 0, "credit survived a reverted execute");
    }
}
