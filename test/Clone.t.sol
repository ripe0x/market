// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "../src/Market.sol";
import {IPolicy, Order} from "../src/Order.sol";
import {Base} from "./utils/Base.sol";
import {ProbePolicy, TestMulti, TestToken} from "./utils/Mocks.sol";

/// During one order's fill, tries to move ETH out of another order. Both may be bound to it.
contract ReachPolicy is IPolicy {
    function onFill(address, uint256, bytes calldata, bytes calldata input) external returns (bytes memory) {
        (Order target, address to, uint256 amount) = abi.decode(input, (Order, address, uint256));
        return target.execute(to, amount, "");
    }
}

/// Orders are ERC-1167 clones of one fixed implementation. These tests check that each clone
/// is still its own account with its own terms, storage and authority.
contract CloneTest is Base {
    ProbePolicy probe;
    ReachPolicy reach;
    Order implementation;

    function setUp() public override {
        super.setUp();
        probe = new ProbePolicy();
        reach = new ReachPolicy();
        implementation = Order(payable(market.implementation()));
    }

    // ---- deployment and terms ----

    /// The clone's code is the standard proxy followed by its terms. There is no initializer:
    /// the terms exist from the moment the code does, in the same CREATE2 that deploys it.
    function test_cloneCodeIsProxyPlusTerms() public {
        Order order = _create(seller, probe, "cfg");
        bytes memory expected = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            address(implementation),
            hex"5af43d82803e903d91602b57fd5bf3",
            seller,
            probe,
            address(probe).codehash,
            keccak256("cfg")
        );
        assertEq(address(order).code, expected);
        assertEq(order.owner(), seller);
        assertEq(address(order.policy()), address(probe));
        assertEq(order.policyCodehash(), address(probe).codehash);
        assertEq(order.configHash(), keccak256("cfg"));

        (bool ok,) = address(order)
            .call(abi.encodeWithSignature("initialize(address,address,bytes32)", attacker, attacker, bytes32(0)));
        assertFalse(ok);
        assertEq(order.owner(), seller);
    }

    function testFuzz_addressIsDeterministic(address owner, bytes calldata config, bytes32 salt) public {
        address predicted = market.orderAddress(owner, probe, keccak256(config), salt);
        vm.prank(owner);
        Order order = market.create(probe, config, salt);
        assertEq(address(order), predicted);
        assertEq(order.owner(), owner);
        assertEq(order.configHash(), keccak256(config));
    }

    /// The same policy, config and salt under two owners are two unrelated accounts.
    function test_sameTermsDifferentOwnersAreSeparateAccounts() public {
        vm.prank(seller);
        Order a = market.create(probe, "x", 0);
        vm.prank(buyer);
        Order b = market.create(probe, "x", 0);
        assertTrue(address(a) != address(b));
        vm.deal(address(b), 1 ether);

        vm.startPrank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        b.execute(seller, 1 ether, "");
        vm.expectRevert(Order.Unauthorized.selector);
        b.close();
        vm.stopPrank();
        assertEq(address(b).balance, 1 ether);
        assertFalse(b.closed());
    }

    // ---- isolation between clones ----

    function test_storageAndBalancesAreIsolated() public {
        Order a = _create(seller, probe, "");
        Order b = _create(seller, probe, "");
        vm.deal(address(a), 1 ether);
        vm.prank(seller);
        a.close();
        assertTrue(a.closed());
        assertFalse(b.closed());
        assertEq(address(b).balance, 0);

        // `filling` is per clone too: ProbePolicy records the calling order's flag.
        vm.prank(buyer);
        b.fill("", "");
        assertTrue(probe.sawFilling());
        assertFalse(a.filling());
    }

    /// Two orders bound to the same policy: during A's fill the policy can act as A, never as B.
    function test_sharedPolicyCannotCrossOrders() public {
        Order a = _create(seller, reach, "");
        Order b = _create(buyer, reach, "");
        vm.deal(address(a), 1 ether);
        vm.deal(address(b), 2 ether);

        vm.expectRevert(Order.Unauthorized.selector);
        a.fill("", abi.encode(b, attacker, 2 ether));
        assertEq(address(b).balance, 2 ether);

        // Acting as the order being filled works.
        a.fill("", abi.encode(a, seller, 1 ether));
        assertEq(seller.balance, 1 ether);
    }

    /// An approval to one clone cannot be spent through a sibling clone with the same policy.
    function test_approvalToSiblingIsUnusable() public {
        TestToken token = new TestToken("T");
        token.mint(seller, 100);
        Order a = _create(seller, probe, "");
        Order b = _create(seller, probe, "");
        vm.prank(seller);
        token.approve(address(b), 100);
        bytes memory pull = abi.encodeCall(token.transferFrom, (seller, attacker, 100));
        vm.expectRevert();
        a.fill("", abi.encode(address(token), 0, pull));
        assertEq(token.balanceOf(seller), 100);
    }

    // ---- the implementation ----

    /// The implementation has no terms and cannot act, be filled, closed or receive assets.
    function test_implementationIsNotAnOrder() public {
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.owner();
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.policy();
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.configHash();
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.fill("", "");
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.execute(attacker, 0, "");
        vm.expectRevert(Order.NotAnOrder.selector);
        implementation.close();

        (bool ok,) = address(implementation).call{value: 1}("");
        assertFalse(ok);
        nft.mint(seller, 1);
        vm.prank(seller);
        vm.expectRevert();
        nft.safeTransferFrom(seller, address(implementation), 1);
        TestMulti multi = new TestMulti();
        multi.mint(seller, 1, 1);
        vm.prank(seller);
        vm.expectRevert();
        multi.safeTransferFrom(seller, address(implementation), 1, 1, "");
    }

    /// Nothing can change the code every order runs: Market's pointer is immutable, and the
    /// implementation contains no DELEGATECALL (which could run other code in its place) and no
    /// SELFDESTRUCT. Walks the runtime code, skipping PUSH data and the trailing metadata.
    function test_implementationCannotBeReplaced() public view {
        bytes memory code = address(implementation).code;
        uint256 end = code.length - 2 - (uint256(uint8(code[code.length - 2])) << 8 | uint8(code[code.length - 1]));
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4 && op != 0xff, "DELEGATECALL or SELFDESTRUCT in Order");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(market.implementation(), address(implementation));
    }

    // ---- the policy code commitment ----

    /// If the policy's code is replaced (possible only for code destroyed in its creation
    /// transaction and redeployed), fills stop and the owner keeps recovery.
    function test_fillRefusesReplacedPolicyCode() public {
        Order order = _create(seller, probe, "");
        vm.deal(address(order), 1 ether);
        vm.etch(address(probe), address(reach).code);
        vm.expectRevert(Order.PolicyCodeChanged.selector);
        order.fill("", "");

        vm.startPrank(seller);
        order.execute(seller, 1 ether, "");
        order.close();
        vm.stopPrank();
        assertEq(seller.balance, 1 ether);
    }

    /// An EIP-7702 account's code is a pointer its key holder can change, so it cannot be a policy.
    function test_createRejectsDelegatedAccount() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(probe)));
        vm.expectRevert(Market.DelegatedPolicy.selector);
        market.create(IPolicy(delegated), "", 0);
    }
}
