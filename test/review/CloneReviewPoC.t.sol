// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Market} from "../../src/Market.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {FillVerifier} from "../../periphery/FillVerifier.sol";
import {Base} from "../utils/Base.sol";
import {ProbeHandler, TestToken} from "../utils/Mocks.sol";

/// During its own order's fill, tries to reach into a DIFFERENT order and drain its ETH.
contract CrossReachHandler is IOrderHandler {
    function onFill(address, uint256, bytes calldata, bytes calldata input) external returns (bytes memory) {
        (address victim, address to, uint256 amount) = abi.decode(input, (address, address, uint256));
        return Order(payable(victim)).execute(to, amount, "");
    }
}

/// Executes a scripted list of calls inside a single external call, so transient storage set by
/// one step is visible to the next (Foundry clears transient storage between top-level calls).
contract Seq {
    function run(address[] memory targets, bytes[] memory data) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// Independent review proof-of-concepts for commit 03c263f (ERC-1167 clone orders, handler
/// code-hash pin, EIP-7702 handler rejection, FillVerifier). New file; nothing else is modified.
contract CloneReviewPoC is Base {
    ProbeHandler probe;
    FillVerifier verifier;
    Seq seq;

    function setUp() public override {
        super.setUp();
        probe = new ProbeHandler();
        verifier = new FillVerifier();
        seq = new Seq();
    }

    // ---------------------------------------------------------------------
    // FINDING G1 (low): FillVerifier.requireIncrease compared against the ORIGINAL snapshot and
    // never consumed it. Reusing one snapshot to validate two sequential fills in the same
    // transaction let a second fill that delivers nothing pass a "+1" check, because the
    // baseline was still the pre-first-fill value. Repaired: requireIncrease uses up the
    // snapshot, so the reuse reverts NoSnapshot instead of passing.
    // ---------------------------------------------------------------------
    function test_fillVerifierStaleSnapshotGivesFalseAssurance() public {
        TestToken token = new TestToken("T");
        bytes memory bal = abi.encodeCall(IERC20.balanceOf, (address(seq)));

        // One snapshot, one real delivery (+1), then a SECOND require(+1) with no further
        // delivery. Before the repair the second check passed although nothing new arrived.
        address[] memory t = new address[](4);
        bytes[] memory d = new bytes[](4);
        t[0] = address(verifier);
        d[0] = abi.encodeCall(verifier.snapshot, (address(token), bal));
        t[1] = address(token);
        d[1] = abi.encodeCall(TestToken.mint, (address(seq), 1)); // stands in for an honest fill #1
        t[2] = address(verifier);
        d[2] = abi.encodeCall(verifier.requireIncrease, (address(token), bal, 1)); // validates fill #1
        t[3] = address(verifier);
        d[3] = abi.encodeCall(verifier.requireIncrease, (address(token), bal, 1)); // "validates" fill #2: NOTHING delivered
        vm.expectRevert(FillVerifier.NoSnapshot.selector);
        seq.run(t, d); // repaired: the reused snapshot is refused
        assertEq(token.balanceOf(address(seq)), 0, "whole batch reverted");

        // Contrast: the safe pattern re-snapshots before the second check and it correctly
        // reverts, because the post-fill-#1 baseline is now 1 and nothing more arrived.
        address[] memory t2 = new address[](5);
        bytes[] memory d2 = new bytes[](5);
        t2[0] = address(verifier);
        d2[0] = abi.encodeCall(verifier.snapshot, (address(token), bal));
        t2[1] = address(token);
        d2[1] = abi.encodeCall(TestToken.mint, (address(seq), 1));
        t2[2] = address(verifier);
        d2[2] = abi.encodeCall(verifier.requireIncrease, (address(token), bal, 1));
        t2[3] = address(verifier);
        d2[3] = abi.encodeCall(verifier.snapshot, (address(token), bal)); // re-baseline
        t2[4] = address(verifier);
        d2[4] = abi.encodeCall(verifier.requireIncrease, (address(token), bal, 1));
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.TooLittle.selector, 0, 1));
        seq.run(t2, d2);
    }

    // ---------------------------------------------------------------------
    // PROPERTY: a predicted order address commits to the owner (owner is part of the immutable
    // args), so a front-runner calling create with the same handler/config/salt gets a DIFFERENT
    // address and cannot occupy or claim the victim's predicted order.
    // ---------------------------------------------------------------------
    function test_frontRunCannotClaimPredictedAddress() public {
        bytes memory config = "cfg";
        bytes32 salt = bytes32(uint256(0xBEEF));
        address predicted = market.orderAddress(seller, probe, keccak256(config), salt);

        // Attacker front-runs with identical handler/config/salt.
        vm.prank(attacker);
        Order attackerOrder = market.create(probe, config, salt);
        assertTrue(address(attackerOrder) != predicted, "attacker lands on a different address");
        assertEq(attackerOrder.owner(), attacker);

        // The victim can still create their own order at exactly the predicted address.
        vm.prank(seller);
        Order victimOrder = market.create(probe, config, salt);
        assertEq(address(victimOrder), predicted);
        assertEq(victimOrder.owner(), seller);
    }

    // ---------------------------------------------------------------------
    // PROPERTY: during A's fill the shared handler can act as A but never as sibling B.
    // ---------------------------------------------------------------------
    function test_sharedHandlerCannotActOnSibling() public {
        CrossReachHandler cross = new CrossReachHandler();
        Order a = _create(seller, cross, ""); // both bound to the SAME handler
        Order b = _create(buyer, cross, "");
        vm.deal(address(b), 5 ether);

        // During A's fill the handler tries to drain B. B is not filling and the handler is not
        // B's owner, so B.execute rejects it and the whole fill reverts.
        bytes memory drainB = abi.encode(address(b), attacker, uint256(5 ether));
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        a.fill("", drainB);
        assertEq(address(b).balance, 5 ether, "sibling untouched");

        // Acting on the order actually being filled works (control).
        vm.deal(address(a), 1 ether);
        a.fill("", abi.encode(address(a), seller, uint256(1 ether)));
        assertEq(seller.balance, 1 ether);
    }

    // ---------------------------------------------------------------------
    // PROPERTY: the implementation can never act as an order, and ETH force-fed to it (e.g. via
    // vm.deal, standing in for selfdestruct/coinbase) cannot be moved out through it.
    // ---------------------------------------------------------------------
    function test_implementationCannotMoveForcedEth() public {
        address impl = market.implementation();
        vm.deal(impl, 1 ether);
        // No caller can drive execute on the implementation: it is never filling and can never
        // be closed (close reads owner(), which reverts NotAnOrder), so execute refuses everyone.
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        Order(payable(impl)).execute(attacker, 1 ether, "");
        assertEq(impl.balance, 1 ether, "stuck but unreachable, not stealable");
    }

    // ---------------------------------------------------------------------
    // PROPERTY: the size==23 / 0xef0100 heuristic does not over-reject. A genuine 23-byte
    // contract whose code does NOT start with 0xef is accepted as a handler (EIP-3541 forbids
    // real deployed code starting with 0xef, so only 7702 designators are caught).
    // ---------------------------------------------------------------------
    function test_tinyNon7702HandlerIsAccepted() public {
        address tiny = makeAddr("tinyHandler");
        // Exactly 23 bytes whose first byte is not 0xef (here 0x00): a plausible minimal
        // contract, the same length as a 7702 designator but without its prefix.
        vm.etch(tiny, new bytes(23));
        assertEq(tiny.code.length, 23);
        vm.prank(seller);
        Order order = market.create(IOrderHandler(tiny), "", bytes32(uint256(1)));
        assertEq(address(order.handler()), tiny, "tiny non-7702 handler accepted");
    }

    // ---------------------------------------------------------------------
    // INFO: an EOA that delegates (EIP-7702) to the Order implementation is NOT caught by
    // _requireClone (address(this) is the EOA, not the implementation), but it is harmless: all
    // immutable args read as zero, so owner()/handler() are address(0), fill reverts WrongConfig,
    // and execute reverts Unauthorized. The EOA's funds cannot be taken through the order ABI.
    // ---------------------------------------------------------------------
    function test_eoaDelegatedToImplementationIsBrickedNotDrainable() public {
        (address eoa, uint256 key) = makeAddrAndKey("victimEoa");
        vm.deal(eoa, 3 ether);
        vm.signAndAttachDelegation(market.implementation(), key);
        assertEq(eoa.code, abi.encodePacked(hex"ef0100", market.implementation()));

        // Reads return zeroed terms rather than reverting NotAnOrder (clone check passes).
        assertEq(Order(payable(eoa)).owner(), address(0));
        assertEq(address(Order(payable(eoa)).handler()), address(0));

        // No one can start a fill: configHash() reads as 0, and no config hashes to 0.
        vm.prank(attacker);
        vm.expectRevert(Order.WrongConfig.selector);
        Order(payable(eoa)).fill("", "");

        // No one can execute as the "order": owner()/handler() are address(0).
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        Order(payable(eoa)).execute(attacker, 3 ether, "");
        assertEq(eoa.balance, 3 ether, "EOA funds safe");
    }
}
