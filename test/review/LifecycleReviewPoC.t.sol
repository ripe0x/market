// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../../src/Order.sol";
import {CapitalPool} from "../../examples/CapitalPool.sol";
import {Base} from "../utils/Base.sol";
import {Reenterer, ScriptHandler} from "../utils/Mocks.sol";

/// Third independent review: adversarial checks of the lifecycle authority model introduced in
/// dd71a9e.
/// Confirms the owner's stated requirements hold and probes the implementation / EIP-7702 /
/// external-grant edges.
contract LifecycleReviewPoC is Base {
    ScriptHandler script;

    function setUp() public override {
        super.setUp();
        script = new ScriptHandler();
    }

    // --- Property: active order grants execute to nobody but the handler, only during a fill ---

    function testFuzz_activeOrderExecuteOnlyHandlerDuringFill(address who) public {
        Order order = _create(seller, script, "");
        vm.deal(address(order), 1 ether);
        // No sender can execute an active, idle order.
        vm.prank(who);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(who, 1 ether, "");
        assertEq(address(order).balance, 1 ether);
    }

    // --- Property: owner cannot close or execute reentrantly during a fill ---

    function test_ownerReentryDuringFillIsPowerless() public {
        Reenterer owner = new Reenterer();
        vm.prank(address(owner));
        Order order = market.create(script, "", 0);
        vm.deal(address(order), 2 ether);

        // Owner's receive hook will try to close the order while it is filling.
        vm.prank(address(owner));
        owner.arm(address(order), abi.encodeCall(Order.close, ()));
        // Handler just pays the owner 1 ETH (triggers the hook).
        order.fill("", script.script(true, address(owner), 1 ether, ""));
        assertTrue(owner.attempted());
        assertFalse(owner.succeeded(), "owner closed during fill");
        assertFalse(order.closed(), "order closed by owner mid-fill");

        // Same, but the hook tries execute instead of close. Reenterer fires its hook only once,
        // so use a fresh owner and order.
        Reenterer owner2 = new Reenterer();
        vm.prank(address(owner2));
        Order order2 = market.create(script, "", bytes32(uint256(1)));
        vm.deal(address(order2), 2 ether);
        vm.prank(address(owner2));
        owner2.arm(address(order2), abi.encodeCall(Order.execute, (address(owner2), 1 ether, "")));
        order2.fill("", script.script(true, address(owner2), 1 ether, ""));
        assertTrue(owner2.attempted());
        assertFalse(owner2.succeeded(), "owner executed during fill");
    }

    // --- Property: handler keeps execute after closing mid-fill; owner gains it only after ---

    function test_handlerKeepsExecuteThroughClosingFill() public {
        Order order = _create(seller, script, "");
        vm.deal(address(order), 2 ether);

        // One fill: close the order, then (still inside the fill) execute as the order's handler.
        ScriptHandler.Step[] memory steps = new ScriptHandler.Step[](2);
        steps[0] = ScriptHandler.Step(true, address(order), 0, abi.encodeCall(Order.close, ()));
        steps[1] = ScriptHandler.Step(true, buyer, 1 ether, ""); // execute after close, same fill
        order.fill("", abi.encode(steps));
        assertTrue(order.closed());
        assertEq(buyer.balance, 101 ether, "handler could not execute after mid-fill close");

        // After the fill the handler is powerless; the owner recovers the remainder.
        vm.prank(address(script));
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(buyer, 1 ether, "");
        vm.prank(seller);
        order.execute(seller, 1 ether, "");
        assertEq(seller.balance, 1 ether);
    }

    // --- Property: shared handler cannot reach a sibling that is not itself filling ---

    function test_sharedHandlerCannotReachNonFillingSibling() public {
        Order mine = _create(attacker, script, "a");
        Order sibling = _create(seller, script, "b");
        vm.deal(address(sibling), 1 ether);

        // During mine's fill, try to execute through the sibling (which is not filling).
        bytes memory steal =
            script.script(false, address(sibling), 0, abi.encodeCall(Order.execute, (attacker, 1 ether, "")));
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        mine.fill("a", steal);
        assertEq(address(sibling).balance, 1 ether);
    }

    // --- Probe: an EIP-7702 EOA delegated to the Order implementation cannot act as an order ---

    function test_eoaDelegatedToImplementationIsInert() public {
        address impl = market.implementation();
        (address eoa, uint256 key) = makeAddrAndKey("eoa7702");
        vm.deal(eoa, 1 ether);
        this._use7702(impl, eoa, key);
    }

    /// Runs inside one transaction so the attached delegation is live for the calls to `eoa`.
    function _use7702(address impl, address eoa, uint256 key) external {
        vm.signAndAttachDelegation(impl, key);

        // Reading terms off a 23-byte delegation designator yields zeros, not a revert:
        // address(this) is the EOA, not the implementation, so _requireClone passes.
        assertEq(Order(payable(eoa)).owner(), address(0));
        assertEq(address(Order(payable(eoa)).handler()), address(0));
        assertEq(Order(payable(eoa)).configHash(), bytes32(0));

        // fill can never set `filling`: keccak256(config) can never equal the zero configHash.
        vm.expectRevert(Order.WrongConfig.selector);
        Order(payable(eoa)).fill("", "");

        // So execute is never authorized: filling is false and the EOA is not "closed+owner".
        vm.expectRevert(Order.Unauthorized.selector);
        Order(payable(eoa)).execute(address(this), 1 ether, "");
    }

    // --- Probe: after closure the owner cannot draw an external grant gated on filling() ---

    function test_closedOrderCannotDrawCapitalPool() public {
        // A bid whose capital source is a pool.
        CapitalPool pool = new CapitalPool{value: 10 ether}(address(this));
        bytes memory config = _bidConfig(seller, 5 ether, rising, _risingParams(1 ether, 0, 5000), address(pool));
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        Order bid = market.create{value: 1 ether}(acquisition, config, 0);
        pool.setGrant(address(bid), 1 ether, 5 ether);
        skip(10); // 5 ETH accrued and drawable by a filling order

        // While active, the owner cannot even reach execute.
        vm.prank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        bid.execute(address(pool), 0, abi.encodeCall(CapitalPool.draw, (1 ether)));

        // Close, then the owner has execute but the pool refuses a draw outside a fill.
        vm.startPrank(seller);
        bid.close();
        vm.expectRevert(CapitalPool.NotFilling.selector);
        bid.execute(address(pool), 0, abi.encodeCall(CapitalPool.draw, (1 ether)));

        // The owner still recovers the order's OWN ETH; the pool's funds stay in the pool.
        bid.execute(seller, 1 ether, "");
        vm.stopPrank();
        assertEq(seller.balance, 1 ether);
        assertEq(address(pool).balance, 10 ether);
    }
}
