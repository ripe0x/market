// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order} from "../src/Order.sol";
import {HandlerBase} from "../examples/HandlerBase.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {Base} from "./utils/Base.sol";
import {FalseToken, FeeToken, NoReturnToken, TestToken} from "./utils/Mocks.sol";

contract TokenExchangeTest is Base {
    TestToken give;
    TestToken take;
    address payee = makeAddr("payee");

    function setUp() public override {
        super.setUp();
        give = new TestToken("GIVE");
        take = new TestToken("TAKE");
        take.mint(buyer, 1000e18);
    }

    /// Sells `amount` GIVE at 3 TAKE per 2 GIVE.
    function _open(address giveToken, address takeToken, uint256 amount)
        internal
        returns (Order order, bytes memory config)
    {
        config = abi.encode(
            TokenExchange.Config(IERC20(giveToken), IERC20(takeToken), 2, 3, payee, block.timestamp + 1 days)
        );
        order = _create(seller, exchange, config);
        TestToken(giveToken).mint(address(order), amount);
    }

    function _fill(Order order, bytes memory config, address token, uint256 amount) internal returns (uint256 owed) {
        vm.startPrank(buyer);
        IERC20(token).approve(address(order), type(uint256).max);
        owed = abi.decode(order.fill(config, abi.encode(amount, buyer)), (uint256));
        vm.stopPrank();
    }

    function test_partialFillsUntilEmpty() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100e18);
        assertEq(_fill(order, config, address(take), 40e18), 60e18);
        assertEq(_fill(order, config, address(take), 60e18), 90e18);
        assertEq(give.balanceOf(buyer), 100e18);
        assertEq(take.balanceOf(payee), 150e18);
        assertEq(give.balanceOf(address(order)), 0);

        vm.prank(buyer);
        vm.expectRevert();
        order.fill(config, abi.encode(1, buyer));

        // The owner tops the active order up and it trades again: the same order persists.
        give.mint(seller, 10e18);
        vm.prank(seller);
        give.transfer(address(order), 10e18);
        assertEq(_fill(order, config, address(take), 10e18), 15e18);
    }

    function test_roundsOwedUp() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100);
        assertEq(_fill(order, config, address(take), 1), 2); // 1.5 rounds up to 2
    }

    function test_expiry() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100e18);
        skip(1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(TokenExchange.Expired.selector);
        order.fill(config, abi.encode(1e18, buyer));
    }

    function test_rejectsEth() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100e18);
        vm.prank(buyer);
        vm.expectRevert(HandlerBase.UnexpectedETH.selector);
        order.fill{value: 1}(config, abi.encode(1e18, buyer));
    }

    /// A fee-on-transfer payment token delivers less than owed, so the trade reverts.
    function test_feeOnTransferPaymentRejected() public {
        FeeToken fee = new FeeToken();
        fee.mint(buyer, 1000e18);
        (Order order, bytes memory config) = _open(address(give), address(fee), 100e18);
        vm.startPrank(buyer);
        fee.approve(address(order), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(TokenExchange.ShortPayment.selector, 14.85e18, 15e18));
        order.fill(config, abi.encode(10e18, buyer));
        vm.stopPrank();
        assertEq(give.balanceOf(address(order)), 100e18);
    }

    /// The filler is checked the same way: a fee-on-transfer token being sold would deliver less
    /// than the filler paid for, so the trade reverts.
    function test_feeOnTransferDeliveryRejected() public {
        FeeToken fee = new FeeToken();
        (Order order, bytes memory config) = _open(address(fee), address(take), 100e18);
        vm.startPrank(buyer);
        take.approve(address(order), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(TokenExchange.ShortDelivery.selector, 9.9e18, 10e18));
        order.fill(config, abi.encode(10e18, buyer));
        vm.stopPrank();
        assertEq(take.balanceOf(buyer), 1000e18);
    }

    function test_tokensWithoutReturnValuesWork() public {
        NoReturnToken nrGive = new NoReturnToken();
        NoReturnToken nrTake = new NoReturnToken();
        nrTake.mint(buyer, 100);
        bytes memory config = abi.encode(
            TokenExchange.Config(IERC20(address(nrGive)), IERC20(address(nrTake)), 1, 1, payee, block.timestamp + 1)
        );
        Order order = _create(seller, exchange, config);
        nrGive.mint(address(order), 50);
        vm.startPrank(buyer);
        nrTake.approve(address(order), 50);
        order.fill(config, abi.encode(50, buyer));
        vm.stopPrank();
        assertEq(nrGive.balanceOf(buyer), 50);
        assertEq(nrTake.balanceOf(payee), 50);
    }

    /// A token that returns false is a failure even though the call itself succeeded.
    function test_falseReturningTokenRejected() public {
        FalseToken f = new FalseToken();
        (Order order, bytes memory config) = _open(address(f), address(take), 100e18);
        vm.startPrank(buyer);
        take.approve(address(order), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(HandlerBase.TokenCallFailed.selector, address(f)));
        order.fill(config, abi.encode(10e18, buyer));
        vm.stopPrank();
        assertEq(take.balanceOf(buyer), 1000e18); // payment rolled back
    }

    /// Paying yourself is not payment: the payee's balance must actually rise.
    function test_selfPaymentRejected() public {
        bytes memory config = abi.encode(
            TokenExchange.Config(IERC20(address(give)), IERC20(address(take)), 1, 1, buyer, block.timestamp + 1)
        );
        Order order = _create(seller, exchange, config);
        give.mint(address(order), 10);
        vm.startPrank(buyer);
        take.approve(address(order), 10);
        vm.expectRevert(abi.encodeWithSelector(TokenExchange.ShortPayment.selector, 0, 10));
        order.fill(config, abi.encode(10, buyer));
        vm.stopPrank();
    }

    /// If the order cannot deliver, the filler's payment is undone too.
    function test_insufficientInventoryRollsBackPayment() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 10e18);
        vm.startPrank(buyer);
        take.approve(address(order), type(uint256).max);
        vm.expectRevert();
        order.fill(config, abi.encode(11e18, buyer));
        vm.stopPrank();
        assertEq(take.balanceOf(buyer), 1000e18);
        assertEq(take.balanceOf(payee), 0);
    }

    /// An approval to the order can only be spent by its approver's own fills.
    function test_othersCannotSpendAnApproval() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100e18);
        vm.prank(buyer);
        take.approve(address(order), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        order.fill(config, abi.encode(10e18, attacker));
        assertEq(take.balanceOf(buyer), 1000e18);
    }

    /// Inventory is committed while the order is active: the owner withdraws it by closing
    /// first, which also stops further fills. TokenExchange has no maintenance action.
    function test_withdrawingInventoryRequiresClosing() public {
        (Order order, bytes memory config) = _open(address(give), address(take), 100e18);
        _fill(order, config, address(take), 40e18);
        bytes memory withdraw = abi.encodeCall(IERC20.transfer, (seller, 60e18));
        vm.startPrank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(give), 0, withdraw);
        order.close();
        order.execute(address(give), 0, withdraw);
        vm.stopPrank();
        assertEq(give.balanceOf(seller), 60e18);
        vm.prank(buyer);
        vm.expectRevert(Order.OrderClosed.selector);
        order.fill(config, abi.encode(1, buyer));
    }

    function testFuzz_payeeAlwaysReceivesOwed(uint128 amount, uint64 giveAmt, uint64 takeAmt) public {
        vm.assume(giveAmt > 0 && amount > 0);
        bytes memory config = abi.encode(
            TokenExchange.Config(IERC20(address(give)), IERC20(address(take)), giveAmt, takeAmt, payee, block.timestamp)
        );
        Order order = _create(seller, exchange, config);
        give.mint(address(order), amount);
        uint256 owed = exchange.owedFor(abi.decode(config, (TokenExchange.Config)), amount);
        take.mint(buyer, owed);
        uint256 buyerBefore = take.balanceOf(buyer);

        vm.startPrank(buyer);
        take.approve(address(order), owed);
        order.fill(config, abi.encode(uint256(amount), buyer));
        vm.stopPrank();

        assertEq(take.balanceOf(payee), owed);
        assertEq(buyerBefore - take.balanceOf(buyer), owed);
        assertGe(owed * giveAmt, uint256(amount) * takeAmt); // never below the rate
        assertLt(owed * giveAmt, uint256(amount) * takeAmt + giveAmt); // by less than one unit
        assertEq(give.balanceOf(buyer), amount);
    }
}
