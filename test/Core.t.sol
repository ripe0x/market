// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./utils/Base.sol";
import {Rejecter} from "./utils/Mocks.sol";
import {Market} from "../src/Market.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, IAction, Order, OrderSpec, OrderState, Phase} from "../src/Order.sol";
import {ActionBase} from "../actions/ActionBase.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// ---------------------------------------------------------------------------
// Scripted test action ("ProbeAction")
//
// A real IAction implementation (extends the shipped ActionBase so every callback runs the
// genuine authentication path). It does nothing on its own; each `execute`/`release` carries an
// encoded list of steps the probe performs AS the order, so the tests can drive core semantics
// (credit, call, reentry) without leaning on the shipped trading actions.
// ---------------------------------------------------------------------------

uint8 constant OP_CREDIT = 1; // o.credit(addr, amount)
uint8 constant OP_PAY = 2; // o.call(addr, amount, "")
uint8 constant OP_CALLRAW = 3; // o.call(addr, amount, data)
uint8 constant OP_RE_EXECUTE = 4; // o.execute("")
uint8 constant OP_RE_CANCEL = 5; // o.cancel()
uint8 constant OP_RE_SURRENDER = 6; // o.surrender()
uint8 constant OP_RE_RELEASE = 7; // o.release(addr, "")
uint8 constant OP_RE_WSURPLUS = 8; // o.withdrawSurplus(addr, amount)
uint8 constant OP_RE_RCREDIT = 9; // o.releaseCredit(addr)
uint8 constant OP_RE_WCREDIT = 10; // o.withdrawCredit(addr)

struct Step {
    uint8 op;
    address addr;
    uint256 amount;
    bytes data;
}

/// @dev Encode the full input the probe reads: an ordered step list, the completion flag and a
/// revert-at-end switch (for atomicity tests).
function encodeRun(Step[] memory steps, bool complete, bool doRevert) pure returns (bytes memory) {
    return abi.encode(steps, complete, doRevert);
}

function noSteps() pure returns (Step[] memory s) {
    s = new Step[](0);
}

function oneStep(uint8 op, address addr, uint256 amount, bytes memory data) pure returns (Step[] memory s) {
    s = new Step[](1);
    s[0] = Step(op, addr, amount, data);
}

function twoSteps(Step memory a, Step memory b) pure returns (Step[] memory s) {
    s = new Step[](2);
    s[0] = a;
    s[1] = b;
}

/// @dev Plain "finish now" / "stay live" input with no side effects.
function runComplete(bool complete) pure returns (bytes memory) {
    return encodeRun(noSteps(), complete, false);
}

contract ProbeAction is ActionBase {
    bytes internal constant TERMS = hex"5052"; // constant activation terms ("PR")

    error ProbeRevert();

    constructor(Market market_) ActionBase(market_) {}

    function validate(address order, bytes calldata) external view returns (bytes memory) {
        _validating(order);
        return TERMS;
    }

    function onExecute(address actor, uint256 value, bytes calldata config, bytes calldata terms, bytes calldata input)
        external
        returns (bool, bytes memory)
    {
        Order o = _executing(actor, value, config, terms);
        (Step[] memory steps, bool complete, bool doRevert) = _decode(input);
        _run(o, steps);
        if (doRevert) revert ProbeRevert();
        return (complete, "");
    }

    function onRelease(
        address actor,
        address recipient,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bytes memory) {
        Order o = _releasing(actor, recipient, config, terms);
        (Step[] memory steps,, bool doRevert) = _decode(input);
        _run(o, steps);
        if (doRevert) revert ProbeRevert();
        return "";
    }

    function _decode(bytes calldata input)
        private
        pure
        returns (Step[] memory steps, bool complete, bool doRevert)
    {
        if (input.length == 0) return (noSteps(), false, false);
        (steps, complete, doRevert) = abi.decode(input, (Step[], bool, bool));
    }

    function _run(Order o, Step[] memory steps) private {
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            if (s.op == OP_CREDIT) o.credit(s.addr, s.amount);
            else if (s.op == OP_PAY) o.call(s.addr, s.amount, "");
            else if (s.op == OP_CALLRAW) o.call(s.addr, s.amount, s.data);
            else if (s.op == OP_RE_EXECUTE) o.execute("");
            else if (s.op == OP_RE_CANCEL) o.cancel();
            else if (s.op == OP_RE_SURRENDER) o.surrender();
            else if (s.op == OP_RE_RELEASE) o.release(s.addr, "");
            else if (s.op == OP_RE_WSURPLUS) o.withdrawSurplus(s.addr, s.amount);
            else if (s.op == OP_RE_RCREDIT) o.releaseCredit(s.addr);
            else if (s.op == OP_RE_WCREDIT) o.withdrawCredit(s.addr);
            else revert("probe: bad op");
        }
    }
}

/// @dev A contract issuer whose ERC721 receive hook always reverts. Proves `mint` never calls it.
contract RevertingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("no receive");
    }
}

/// @dev Issuer+residual that reenters the order from a callback the action makes mid-execute.
contract Reenterer {
    Order public order;

    function setOrder(Order o) external {
        order = o;
    }

    function reCancel() external {
        order.cancel();
    }

    function reWithdraw(address to) external {
        order.withdrawSurplus(to, 1);
    }

    receive() external payable {}
}

/// @dev Executes two independent orders inside one transaction.
contract Composer {
    function execBoth(Order a, Order b, bytes calldata ia, bytes calldata ib) external {
        a.execute(ia);
        b.execute(ib);
    }
}

/// @notice Shared setup for every probe-driven suite.
abstract contract ProbeBase is Base {
    ProbeAction probe;

    function setUp() public virtual override {
        super.setUp();
        probe = new ProbeAction(market);
    }

    function _probeSpec(Admission a, uint64 dl, address resid) internal view returns (OrderSpec memory) {
        return _spec(address(probe), a, dl, resid, bytes("probe-config"));
    }
}

contract CoreTest is ProbeBase {
    bytes32 constant SALT = bytes32(uint256(0x9a17));
    uint64 constant DL = T0 + 1 days; // 1_086_400

    // ===================== factory: address commitment =====================

    function test_createMatchesPrediction() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        address predicted = market.orderAddress(issuer, spec, SALT);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        assertEq(address(o), predicted, "created address != prediction");
        assertTrue(market.isOrder(address(o)), "isOrder not set");
        assertFalse(market.isOrder(address(0xdead)), "isOrder true for stranger");
    }

    function test_predictionWorksAfterDeadline() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        address predicted = market.orderAddress(issuer, spec, SALT);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        assertEq(address(o), predicted);
        vm.warp(DL + 10); // deadline passed
        assertEq(market.orderAddress(issuer, spec, SALT), address(o), "prediction drifted after deadline");
    }

    function test_everyCommittedFieldChangesAddress() public {
        OrderSpec memory base = _probeSpec(Admission.Public, 0, issuer);
        address a0 = market.orderAddress(issuer, base, SALT);

        // issuer
        assertTrue(market.orderAddress(buyer, base, SALT) != a0, "issuer not committed");

        // action (fresh impl at a different address, also different codehash)
        ProbeAction probe2 = new ProbeAction(market);
        OrderSpec memory s = base;
        s.action = address(probe2);
        assertTrue(market.orderAddress(issuer, s, SALT) != a0, "action not committed");

        // admission
        s = base;
        s.admission = Admission.Holder;
        assertTrue(market.orderAddress(issuer, s, SALT) != a0, "admission not committed");

        // deadline
        s = base;
        s.deadline = DL;
        assertTrue(market.orderAddress(issuer, s, SALT) != a0, "deadline not committed");

        // residual
        s = base;
        s.residual = buyer;
        assertTrue(market.orderAddress(issuer, s, SALT) != a0, "residual not committed");

        // config (single byte difference)
        s = base;
        s.config = bytes("probe-configX");
        assertTrue(market.orderAddress(issuer, s, SALT) != a0, "config not committed");

        // salt
        assertTrue(market.orderAddress(issuer, base, bytes32(uint256(SALT) + 1)) != a0, "salt not committed");
    }

    function test_createdEventCarriesFullSpec() public {
        OrderSpec memory spec = _probeSpec(Admission.Holder, DL, issuer);
        address predicted = market.orderAddress(issuer, spec, SALT);
        vm.expectEmit(true, true, true, true);
        emit Market.Created(Order(payable(predicted)), issuer, spec.action, SALT, spec);
        vm.prank(issuer);
        market.create(spec, SALT);
    }

    // ===================== factory: rejections =====================

    function test_rejectZeroResidual() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, address(0));
        vm.prank(issuer);
        vm.expectRevert(Market.ZeroResidual.selector);
        market.create(spec, SALT);
    }

    /// A deadline at or before now is accepted so pre-sent backing stays recoverable; the order
    /// is born expired and can never go live.
    function test_createPastDeadline_neverLive() public {
        uint64[2] memory deadlines = [uint64(block.timestamp), uint64(block.timestamp - 1)];
        for (uint256 i; i < 2; ++i) {
            OrderSpec memory spec = _probeSpec(Admission.Public, deadlines[i], issuer);
            vm.prank(issuer);
            vm.expectRevert(Order.DeadlinePassed.selector);
            market.createAndActivate(spec, bytes32(i));
            vm.prank(issuer);
            Order o = market.create(spec, bytes32(i));
            assertEq(uint8(o.state()), uint8(OrderState.Pending));
            assertTrue(o.isExpired());
            assertFalse(o.isLive());
            vm.prank(issuer);
            vm.expectRevert(Order.DeadlinePassed.selector);
            o.activate();
        }
    }

    function test_rejectCodelessAction() public {
        OrderSpec memory spec = _spec(makeAddr("nocode"), Admission.Public, 0, issuer, bytes("x"));
        vm.prank(issuer);
        vm.expectRevert(Market.NoActionCode.selector);
        market.create(spec, SALT);
    }

    function test_reject7702DelegatedAction() public {
        // An EIP-7702 delegation designator is exactly 0xef0100 ++ 20-byte address (23 bytes).
        address eoa = makeAddr("eoa7702");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", bytes20(uint160(0xBEEF))));
        assertEq(eoa.code.length, 23);
        OrderSpec memory spec = _spec(eoa, Admission.Public, 0, issuer, bytes("x"));
        vm.prank(issuer);
        vm.expectRevert(Market.DelegatedAction.selector);
        market.create(spec, SALT);
    }

    function test_rejectOversizedConfig() public {
        // Clones refuses immutable args longer than 0x5fd3 bytes.
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        spec.config = new bytes(0x6000);
        vm.prank(issuer);
        vm.expectRevert(Clones.CloneArgumentsTooLong.selector);
        market.create(spec, SALT);
    }

    function test_duplicateCreateReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        market.create(spec, SALT);
        vm.prank(issuer);
        vm.expectRevert(Errors.FailedDeployment.selector);
        market.create(spec, SALT);
    }

    function test_configReadableAfterTerminationAndBurn() public {
        // Holder order: complete -> Completed + token burned; config still readable from code.
        OrderSpec memory spec = _probeSpec(Admission.Holder, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        assertEq(actions.ownerOf(_id(o)), issuer);
        vm.prank(issuer);
        o.execute(runComplete(true));
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id(o)));
        actions.ownerOf(_id(o));
        assertEq(o.config(), bytes("probe-config"), "config lost after burn");
    }

    // ===================== action code identity =====================

    function test_codeChangeBlocksActivate() public {
        ProbeAction tmp = new ProbeAction(market);
        OrderSpec memory spec = _spec(address(tmp), Admission.Public, 0, issuer, bytes("c"));
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.etch(address(tmp), hex"600160005260206000f3"); // different runtime code
        vm.prank(issuer);
        vm.expectRevert(Order.ActionCodeChanged.selector);
        o.activate();
    }

    function test_codeChangeBlocksExecute() public {
        ProbeAction tmp = new ProbeAction(market);
        OrderSpec memory spec = _spec(address(tmp), Admission.Public, 0, issuer, bytes("c"));
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.etch(address(tmp), hex"600160005260206000f3");
        vm.prank(buyer);
        vm.expectRevert(Order.ActionCodeChanged.selector);
        o.execute(runComplete(true));
    }

    function test_codeChangeBlocksRelease() public {
        ProbeAction tmp = new ProbeAction(market);
        OrderSpec memory spec = _spec(address(tmp), Admission.Public, 0, issuer, bytes("c"));
        vm.prank(issuer);
        Order o = market.create(spec, SALT); // Pending: release is permitted by state
        vm.etch(address(tmp), hex"600160005260206000f3");
        vm.prank(issuer);
        vm.expectRevert(Order.ActionCodeChanged.selector);
        o.release(issuer, "");
    }

    // ===================== activation authenticity =====================

    function test_onlyIssuerOrMarketActivate() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        OrderSpec memory spec2 = spec;
        spec2.residual = creator; // residual != issuer so we can prank residual distinctly
        vm.prank(issuer);
        Order o = market.create(spec2, SALT);

        vm.prank(attacker); // random account
        vm.expectRevert(Order.Unauthorized.selector);
        o.activate();

        vm.prank(creator); // residual beneficiary
        vm.expectRevert(Order.Unauthorized.selector);
        o.activate();

        Reenterer hostile = new Reenterer(); // hostile contract
        vm.prank(address(hostile));
        vm.expectRevert(Order.Unauthorized.selector);
        o.activate();

        vm.prank(issuer); // issuer succeeds
        o.activate();
        assertEq(uint8(o.state()), uint8(OrderState.Live));
    }

    function test_createAndActivateActivatesForCaller() public {
        OrderSpec memory spec = _probeSpec(Admission.Holder, 0, issuer);
        address predicted = market.orderAddress(issuer, spec, SALT);
        vm.prank(issuer);
        Order o = market.createAndActivate(spec, SALT);
        assertEq(address(o), predicted);
        assertEq(o.issuer(), issuer, "issuer is the createAndActivate caller");
        assertEq(uint8(o.state()), uint8(OrderState.Live));
        assertEq(actions.ownerOf(_id(o)), issuer, "token minted to issuer");
    }

    function test_activateOnceOnly() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.prank(issuer);
        vm.expectRevert(Order.WrongState.selector);
        o.activate();
    }

    function test_activateAfterDeadlineReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.warp(DL);
        vm.prank(issuer);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.activate();
    }

    function test_mintToRevertingReceiverSucceeds() public {
        RevertingReceiver rr = new RevertingReceiver();
        OrderSpec memory spec = _probeSpec(Admission.Holder, 0, address(rr));
        vm.prank(address(rr));
        Order o = market.createAndActivate(spec, SALT);
        // _mint (not _safeMint) means the reverting hook is never called.
        assertEq(actions.ownerOf(_id(o)), address(rr), "token not minted to reverting receiver");
    }

    function test_previewActivationMatchesStoredTerms() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        bytes memory preview = o.previewActivation();
        vm.prank(issuer);
        o.activate();
        assertEq(o.activationTerms(), preview, "stored terms != preview");
    }

    // ===================== public repeat + cancel =====================

    function test_publicRepeatUntilComplete() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();

        vm.prank(buyer);
        o.execute(runComplete(false)); // stays Live
        assertEq(uint8(o.state()), uint8(OrderState.Live));

        vm.prank(bidder);
        o.execute(runComplete(true)); // now completes
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
    }

    function test_cancelPendingPublic() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
    }

    function test_cancelPendingHolder() public {
        OrderSpec memory spec = _probeSpec(Admission.Holder, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
    }

    function test_cancelLivePublic() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.prank(issuer);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
    }

    function test_cancelByNonIssuerReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.cancel();
    }

    function test_cancelAfterDeadlineReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.warp(DL);
        vm.prank(issuer);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.cancel();
    }

    // ===================== deadline boundary =====================

    function test_executeAtDeadlineMinusOneWorks() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.warp(DL - 1);
        vm.prank(buyer);
        o.execute(runComplete(true));
        assertEq(uint8(o.state()), uint8(OrderState.Completed));
    }

    function test_executeAtDeadlineReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.warp(DL);
        vm.prank(buyer);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.execute(runComplete(true));
    }

    // ===================== finalizeExpiry =====================

    function test_finalizeExpiryPendingByAnyone() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.warp(DL);
        vm.prank(attacker);
        o.finalizeExpiry();
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
    }

    function test_finalizeExpiryLiveByAnyone() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.warp(DL + 1);
        vm.prank(attacker);
        o.finalizeExpiry();
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
    }

    function test_finalizeExpiryBeforeDeadlineReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, DL, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(attacker);
        vm.expectRevert(Order.NotExpired.selector);
        o.finalizeExpiry();
    }

    function test_finalizeExpiryPerpetualReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer); // deadline 0
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.warp(T0 + 3650 days);
        vm.prank(attacker);
        vm.expectRevert(Order.NotExpired.selector);
        o.finalizeExpiry();
    }

    // ===================== release rules =====================

    function test_releaseLiveReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer);
        o.activate();
        vm.prank(issuer);
        vm.expectRevert(Order.WrongState.selector);
        o.release(issuer, "");
    }

    function test_releaseZeroRecipientReverts() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT); // Pending
        vm.prank(issuer);
        vm.expectRevert(Order.ZeroAddress.selector);
        o.release(address(0), "");
    }

    function test_releaseStrangerMustTargetResidual() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT); // Pending, residual == issuer

        // stranger -> stranger: rejected
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(attacker, "");

        // stranger -> residual: allowed (anyone may trigger cleanup to the residual)
        vm.prank(attacker);
        o.release(issuer, "");
    }

    function test_releaseResidualChoosesRecipient() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        vm.prank(issuer);
        Order o = market.create(spec, SALT);
        vm.prank(issuer); // residual chooses any recipient
        o.release(attacker, "");
    }

    function test_releaseCallCannotCarryValue() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        Order o = _create(issuer, spec, 1 ether); // fund so balance exists
        // During release, a call carrying ETH is rejected.
        bytes memory input = encodeRun(oneStep(OP_CALLRAW, attacker, 1, ""), false, false);
        vm.prank(issuer);
        vm.expectRevert(Order.Unauthorized.selector);
        o.release(issuer, input);
    }

    function test_releaseZeroValueCallWorks() public {
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        Order o = _create(issuer, spec, 1 ether);
        bytes memory input = encodeRun(oneStep(OP_CALLRAW, attacker, 0, ""), false, false);
        vm.prank(issuer);
        o.release(issuer, input); // succeeds
    }

    // ===================== phase guard (reentrancy) =====================

    function _liveProbe(Admission a) internal returns (Order o) {
        OrderSpec memory spec = _probeSpec(a, 0, issuer);
        o = _create(issuer, spec, 1 ether);
        vm.prank(issuer);
        o.activate();
    }

    function test_reentryExecuteReverts() public {
        Order o = _liveProbe(Admission.Public);
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_RE_EXECUTE, address(0), 0, ""), false, false));
    }

    function test_reentrySurrenderReverts() public {
        Order o = _liveProbe(Admission.Public);
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_RE_SURRENDER, address(0), 0, ""), false, false));
    }

    function test_reentryReleaseReverts() public {
        Order o = _liveProbe(Admission.Public);
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_RE_RELEASE, issuer, 0, ""), false, false));
    }

    function test_reentryReleaseCreditReverts() public {
        Order o = _liveProbe(Admission.Public);
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_RE_RCREDIT, issuer, 0, ""), false, false));
    }

    function test_reentryWithdrawCreditReverts() public {
        Order o = _liveProbe(Admission.Public);
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_RE_WCREDIT, issuer, 0, ""), false, false));
    }

    function test_reentryCancelReverts() public {
        // cancel checks issuer first, so the reentrant caller must be the issuer.
        Reenterer re = new Reenterer();
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, address(re));
        vm.prank(address(re));
        Order o = market.create(spec, SALT);
        re.setOrder(o);
        vm.prank(address(re));
        o.activate();
        bytes memory cb = abi.encodeCall(Reenterer.reCancel, ());
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_CALLRAW, address(re), 0, cb), false, false));
    }

    function test_reentryWithdrawSurplusReverts() public {
        // withdrawSurplus checks residual first, so the reentrant caller must be the residual.
        Reenterer re = new Reenterer();
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, address(re));
        vm.prank(address(re));
        Order o = market.create(spec, SALT);
        re.setOrder(o);
        vm.prank(address(re));
        o.activate();
        bytes memory cb = abi.encodeCall(Reenterer.reWithdraw, (attacker));
        vm.prank(buyer);
        vm.expectRevert(Order.Busy.selector);
        o.execute(encodeRun(oneStep(OP_CALLRAW, address(re), 0, cb), false, false));
    }

    function test_composabilityTwoOrdersOneTx() public {
        Order a = _liveProbe(Admission.Public);
        OrderSpec memory spec = _probeSpec(Admission.Public, 0, issuer);
        Order b = _create(issuer, spec, 0);
        vm.prank(issuer);
        b.activate();

        Composer composer = new Composer();
        composer.execBoth(a, b, runComplete(true), runComplete(true));
        assertEq(uint8(a.state()), uint8(OrderState.Completed));
        assertEq(uint8(b.state()), uint8(OrderState.Completed));
    }
}

contract InvalidAdmissionTest is Base {
    function test_invalidAdmissionRejected() public {
        OrderSpec memory spec = _spec(address(exchange), Admission.Public, 0, seller, hex"01");
        bytes memory data = abi.encodeCall(Market.create, (spec, bytes32(uint256(1))));
        // OrderSpec is dynamic: word 0 selector-offset, struct head at 4+64; admission is its 2nd word.
        uint256 slot = 4 + 64 + 32;
        assembly {
            mstore(add(add(data, 0x20), slot), 2)
        }
        vm.prank(seller);
        (bool ok,) = address(market).call(data);
        assertFalse(ok);
        spec.admission = Admission.Holder;
        vm.prank(seller);
        (ok,) = address(market).call(abi.encodeCall(Market.create, (spec, bytes32(uint256(1)))));
        assertTrue(ok);
    }
}
