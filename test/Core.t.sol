// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {IPolicy, Order} from "../src/Order.sol";
import {Base} from "./utils/Base.sol";
import {
    DrainPolicy,
    ProbePolicy,
    ReentrantPolicy,
    Reenterer,
    RevertPolicy,
    StashPolicy,
    TestMulti,
    TestToken
} from "./utils/Mocks.sol";

contract CoreTest is Base {
    ProbePolicy probe;

    function setUp() public override {
        super.setUp();
        probe = new ProbePolicy();
    }

    // ---- creation and identity ----

    function test_createDeploysAtCommittedAddress() public {
        bytes memory config = "terms";
        address predicted = market.orderAddress(seller, probe, keccak256(config), bytes32(uint256(7)));

        vm.deal(seller, 1 ether);
        vm.expectEmit(address(market));
        emit Market.Created(Order(payable(predicted)), seller, probe, bytes32(uint256(7)), config);
        vm.prank(seller);
        Order order = market.create{value: 1 ether}(probe, config, bytes32(uint256(7)));

        assertEq(address(order), predicted);
        assertEq(order.owner(), seller);
        assertEq(address(order.policy()), address(probe));
        assertEq(order.configHash(), keccak256(config));
        assertEq(address(order).balance, 1 ether);
        assertFalse(order.closed());
        assertFalse(order.filling());
    }

    function test_addressCommitsToEveryField() public view {
        bytes32 h = keccak256("a");
        address base = market.orderAddress(seller, probe, h, 0);
        assertTrue(base != market.orderAddress(buyer, probe, h, 0));
        assertTrue(base != market.orderAddress(seller, IPolicy(address(dutch)), h, 0));
        assertTrue(base != market.orderAddress(seller, probe, keccak256("b"), 0));
        assertTrue(base != market.orderAddress(seller, probe, h, bytes32(uint256(1))));
    }

    function test_sameCommitmentCannotBeCreatedTwice() public {
        vm.startPrank(seller);
        market.create(probe, "x", 0);
        vm.expectRevert();
        market.create(probe, "x", 0);
        vm.stopPrank();
        // The same terms under another owner are a different order.
        vm.prank(buyer);
        market.create(probe, "x", 0);
    }

    function test_createRejectsPolicyWithoutCode() public {
        vm.expectRevert(Market.NoPolicyCode.selector);
        market.create(IPolicy(makeAddr("eoa")), "", 0);
    }

    /// Assets sent to the predicted address before deployment are controlled only by the order
    /// that is later deployed there.
    function test_counterfactualDeposit() public {
        nft.mint(seller, 1);
        bytes memory config = abi.encode(_dutchConfig(1, seller));
        address predicted = market.orderAddress(seller, dutch, keccak256(config), 0);
        vm.prank(seller);
        nft.transferFrom(seller, predicted, 1);

        vm.prank(seller);
        Order order = market.create(dutch, config, 0);
        vm.prank(buyer);
        order.fill{value: 10 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(1), buyer);
    }

    // ---- fill and config commitment ----

    function test_fillPassesCallerValueConfigAndInput() public {
        Order order = _create(seller, probe, "cfg");
        vm.expectEmit(address(order));
        emit Order.Filled(buyer, 2 ether);
        vm.prank(buyer);
        bytes memory ret = order.fill{value: 2 ether}("cfg", "");
        assertEq(ret, "probe");
        assertEq(probe.caller(), buyer);
        assertEq(probe.value(), 2 ether);
        assertEq(probe.config(), "cfg");
        assertTrue(probe.sawFilling());
        assertFalse(order.filling());
        assertEq(address(order).balance, 2 ether);
    }

    function test_fillRejectsUncommittedConfig() public {
        Order order = _create(seller, probe, "cfg");
        vm.expectRevert(Order.WrongConfig.selector);
        order.fill("cfg2", "");
    }

    function testFuzz_fillRejectsAnyOtherConfig(bytes calldata config) public {
        vm.assume(keccak256(config) != keccak256("cfg"));
        Order order = _create(seller, probe, "cfg");
        vm.expectRevert(Order.WrongConfig.selector);
        order.fill(config, "");
    }

    function test_policyRevertUndoesFill() public {
        Order order = _create(seller, new RevertPolicy(), "");
        vm.prank(buyer);
        vm.expectRevert("broken");
        order.fill{value: 1 ether}("", "");
        assertEq(address(order).balance, 0);
        assertEq(buyer.balance, 100 ether);
    }

    // ---- who can act as the order ----

    function test_ownerExecutesOutsideFill() public {
        Order order = _create(seller, probe, "");
        vm.deal(address(order), 1 ether);
        vm.prank(seller);
        order.execute(seller, 1 ether, "");
        assertEq(seller.balance, 1 ether);
    }

    function testFuzz_onlyOwnerExecutesOutsideFill(address caller) public {
        vm.assume(caller != seller);
        Order order = _create(seller, probe, "");
        vm.prank(caller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(caller, 0, "");
    }

    function test_policyCannotExecuteOutsideFill() public {
        Order order = _create(seller, probe, "");
        vm.prank(address(probe));
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(probe), 0, "");
    }

    function test_policyExecutesDuringFill() public {
        Order order = _create(seller, probe, "");
        vm.prank(buyer);
        order.fill{value: 1 ether}("", abi.encode(buyer, 1 ether, ""));
        assertEq(buyer.balance, 100 ether);
    }

    /// The owner cannot act while a fill is running, so it cannot reach in mid-fill and take
    /// what the policy is about to deliver.
    function test_ownerCannotExecuteDuringFill() public {
        Reenterer owner = new Reenterer();
        vm.prank(address(owner));
        Order order = market.create(probe, "", 0);
        owner.arm(address(order), abi.encodeCall(Order.execute, (address(owner), 0, "")));
        vm.deal(address(order), 1 ether);

        // The policy pays the owner, whose receive hook tries to use owner powers.
        vm.prank(buyer);
        order.fill("", abi.encode(address(owner), 1 ether, ""));
        assertTrue(owner.attempted());
        assertFalse(owner.succeeded());
    }

    function test_filledOrderCanCallOnlyItselfToClose() public {
        Order order = _create(seller, probe, "");
        vm.prank(buyer);
        order.fill("", abi.encode(address(order), 0, abi.encodeCall(Order.close, ())));
        assertTrue(order.closed());
    }

    function test_selfCallCannotEscalate() public {
        Order order = _create(seller, probe, "");
        // The policy makes the order call its own execute: msg.sender is the order, not the policy.
        bytes memory inner = abi.encodeCall(Order.execute, (buyer, 0, ""));
        vm.expectRevert(Order.Unauthorized.selector);
        order.fill("", abi.encode(address(order), 0, inner));
    }

    function test_executeBubblesRevertReason() public {
        Order order = _create(seller, probe, "");
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 9));
        order.execute(address(nft), 0, abi.encodeCall(IERC721.ownerOf, (9)));
    }

    // ---- closing ----

    function test_closeStopsFillsButKeepsRecovery() public {
        Order order = _create(seller, probe, "");
        vm.deal(address(order), 1 ether);
        vm.expectEmit(address(order));
        emit Order.Closed();
        vm.prank(seller);
        order.close();
        assertTrue(order.closed());

        vm.expectRevert(Order.OrderClosed.selector);
        order.fill("", "");

        vm.prank(seller);
        order.execute(seller, 1 ether, "");
        assertEq(seller.balance, 1 ether);
    }

    function testFuzz_onlyOwnerOrSelfCloses(address caller) public {
        vm.assume(caller != seller);
        Order order = _create(seller, probe, "");
        vm.prank(caller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.close();
    }

    // ---- reentrancy and hostile policies ----

    function test_fillCannotReenter() public {
        Order order = _create(seller, new ReentrantPolicy(), "");
        vm.expectRevert(Order.Reentrant.selector);
        order.fill("", "");
    }

    function test_policyCannotKeepAuthority() public {
        StashPolicy stash = new StashPolicy();
        Order order = _create(seller, stash, "");
        vm.deal(address(order), 1 ether);
        order.fill("", "");
        assertEq(address(stash.stashed()), address(order));

        vm.expectRevert(Order.Unauthorized.selector);
        stash.useLater(attacker, 1 ether, "");
        assertEq(address(order).balance, 1 ether);
    }

    /// A hostile policy controls only the orders that chose it. It cannot touch an unrelated
    /// order's assets, or use approvals granted to that order.
    function test_hostilePolicyIsContainedToItsOwnOrders() public {
        DrainPolicy drain = new DrainPolicy(attacker);
        Order victimOfOwnChoice = _create(buyer, drain, "");
        vm.deal(address(victimOfOwnChoice), 3 ether);

        (Order sale,) = _listDutch(seller, 1);
        vm.deal(address(sale), 5 ether);
        nft.mint(seller, 2);
        vm.prank(seller);
        nft.approve(address(sale), 2);

        // Trying to move the unrelated order's NFT fails, so the whole fill reverts.
        vm.expectRevert(Order.Unauthorized.selector);
        victimOfOwnChoice.fill("", abi.encode(address(sale), address(nft), 1));

        // Without that, the drain policy takes only its own order's ETH.
        victimOfOwnChoice.fill("", "");
        assertEq(attacker.balance, 103 ether);
        assertEq(address(sale).balance, 5 ether);
        assertEq(nft.ownerOf(1), address(sale));
        assertEq(nft.getApproved(2), address(sale));
    }

    /// A policy pulling from an approval must use `caller`. Approving one order does not let
    /// any other order, or anyone filling that order, spend it.
    function test_approvalToOneOrderIsUnusableElsewhere() public {
        TestToken token = new TestToken("T");
        token.mint(seller, 100);
        Order a = _create(seller, probe, "");
        Order b = _create(seller, probe, "b");
        vm.prank(seller);
        token.approve(address(a), 100);

        bytes memory pull = abi.encodeCall(token.transferFrom, (seller, attacker, 100));
        vm.expectRevert();
        b.fill("b", abi.encode(address(token), 0, pull));
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        a.execute(address(token), 0, pull);
        assertEq(token.balanceOf(seller), 100);
    }

    /// A broken policy cannot trap assets: recovery never calls the policy.
    function test_ownerRecoversFromBrokenPolicy() public {
        TestToken token = new TestToken("T");
        TestMulti multi = new TestMulti();
        Order order = _create(seller, new RevertPolicy(), "");
        nft.mint(address(this), 1);
        nft.safeTransferFrom(address(this), address(order), 1);
        multi.mint(address(order), 5, 10);
        token.mint(address(order), 50);
        vm.deal(address(order), 1 ether);

        vm.startPrank(seller);
        order.close();
        order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 1)));
        order.execute(
            address(multi), 0, abi.encodeCall(multi.safeTransferFrom, (address(order), seller, 5, 10, ""))
        );
        order.execute(address(token), 0, abi.encodeCall(token.transfer, (seller, 50)));
        order.execute(seller, 1 ether, "");
        vm.stopPrank();

        assertEq(nft.ownerOf(1), seller);
        assertEq(multi.balanceOf(seller, 5), 10);
        assertEq(token.balanceOf(seller), 50);
        assertEq(seller.balance, 1 ether);
    }

    function test_acceptsEthAndTokenTransfers() public {
        Order order = _create(seller, probe, "");
        TestMulti multi = new TestMulti();
        multi.mint(seller, 1, 2);
        multi.mint(seller, 2, 2);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (1, 2, 1, 1);
        vm.startPrank(seller);
        multi.safeBatchTransferFrom(seller, address(order), ids, amounts, "");
        multi.safeTransferFrom(seller, address(order), 1, 1, "");
        vm.stopPrank();
        (bool ok,) = address(order).call{value: 1}("");
        assertTrue(ok);
        assertEq(multi.balanceOf(address(order), 1), 2);
    }

    /// An order cannot sign anything. Signature based protocols cannot act through it, so its
    /// authority exists only inside its own calls.
    function test_ordersDoNotValidateSignatures() public {
        Order order = _create(seller, probe, "");
        (bool ok,) = address(order).call(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok);
    }

    /// The factory has no function that moves assets: an approval to it is inert.
    function test_marketHoldsNoAuthority() public {
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.approve(address(market), 1);
        (bool ok,) = address(market).call(abi.encodeCall(IERC721.transferFrom, (seller, attacker, 1)));
        assertFalse(ok);
        assertEq(nft.ownerOf(1), seller);
    }
}
