// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {AcquisitionBid} from "../examples/AcquisitionBid.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {Base} from "./utils/Base.sol";
import {Reenterer, ScriptHandler, TestToken} from "./utils/Mocks.sol";

/// Sells `token` for ETH at `price` wei per unit, and lets the order's owner take unsold
/// inventory back without closing: a maintenance fill this handler explicitly allows. Without
/// such a branch the owner of an active order cannot move anything it holds.
contract RestockableSale is IOrderHandler {
    error NotOwner();
    error WrongPayment();

    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        (IERC20 token, uint256 price) = abi.decode(config, (IERC20, uint256));
        (bool withdraw, uint256 amount) = abi.decode(input, (bool, uint256));
        Order order = Order(payable(msg.sender));
        address owner = order.owner();
        if (withdraw) {
            if (caller != owner || value != 0) revert NotOwner();
            order.execute(address(token), 0, abi.encodeCall(IERC20.transfer, (owner, amount)));
        } else {
            if (value != amount * price) revert WrongPayment();
            order.execute(address(token), 0, abi.encodeCall(IERC20.transfer, (caller, amount)));
            order.execute(owner, value, "");
        }
        return "";
    }
}

/// One handler serves many orders. Each order keeps its own assets, authority, config and
/// lifecycle; the handler can act through an order only while that order is filling.
contract SharedHandlerTest is Base {
    ScriptHandler script;
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        script = new ScriptHandler();
    }

    /// Two sales on one handler, by different owners with different terms, are separate
    /// accounts: separate NFTs, balances, permissions and lifecycles.
    function test_ordersSharingAHandlerAreIndependent() public {
        (Order a, bytes memory configA) = _listDutch(seller, 1);
        nft.mint(other, 2);
        DutchAuction.Config memory cb = _dutchConfig(2, other);
        (cb.startPrice, cb.endPrice) = (3 ether, 3 ether);
        bytes memory configB = abi.encode(cb);
        Order b = _create(other, dutch, configB);
        vm.prank(other);
        nft.safeTransferFrom(other, address(b), 2);
        assertEq(address(a.handler()), address(b.handler()));

        vm.prank(buyer);
        vm.expectRevert(Order.WrongConfig.selector);
        b.fill{value: 10 ether}(configA, abi.encode(buyer));

        // A's owner has no power over B, and closing A leaves B active.
        vm.startPrank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        b.close();
        a.close();
        vm.expectRevert(Order.Unauthorized.selector);
        b.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(b), seller, 2)));
        vm.stopPrank();
        assertTrue(a.closed());
        assertFalse(b.closed());

        vm.prank(buyer);
        b.fill{value: 3 ether}(configB, abi.encode(buyer));
        assertEq(nft.ownerOf(2), buyer);
        assertEq(other.balance, 3 ether);
        assertEq(nft.ownerOf(1), address(a));
        assertEq(seller.balance, 0);
    }

    /// A hostile handler reaches no order that is not filling under it: not a sibling that
    /// shares it, and not an order bound to another handler, even in the middle of its fill.
    function test_hostileHandlerCannotReachUnrelatedOrders() public {
        Order mine = _create(attacker, script, "");
        Order sibling = _create(seller, script, "s");
        vm.deal(address(sibling), 1 ether);
        bytes memory steal =
            script.script(false, address(sibling), 0, abi.encodeCall(Order.execute, (attacker, 1 ether, "")));
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        mine.fill("", steal);

        // A sale on DutchAuction refunds its buyer; the buyer's hook fills the attacker's order,
        // whose script tries to take ETH the sale holds while the sale is still filling.
        (Order sale, bytes memory saleConfig) = _listDutch(seller, 1);
        vm.deal(address(sale), 5 ether);
        Reenterer buyerContract = new Reenterer();
        vm.deal(address(buyerContract), 11 ether);
        bytes memory grab =
            script.script(false, address(sale), 0, abi.encodeCall(Order.execute, (attacker, 5 ether, "")));
        buyerContract.arm(address(mine), abi.encodeCall(Order.fill, ("", grab)));
        buyerContract.call(address(sale), 11 ether, abi.encodeCall(Order.fill, (saleConfig, abi.encode(buyer))));
        assertTrue(buyerContract.attempted());
        assertFalse(buyerContract.succeeded());
        assertEq(address(sale).balance, 5 ether);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(attacker.balance, 100 ether);
    }

    /// Nested fills of two orders on one handler. While both are filling the handler can act
    /// through each, and at no other time. The core cannot tell which order a shared handler is
    /// acting for, so keeping them apart is the handler's job: act only through `msg.sender`.
    function test_nestedFillsOnOneHandler() public {
        Order a = _create(seller, script, "a");
        Order b = _create(other, script, "b");
        vm.deal(address(a), 1 ether);
        vm.deal(address(b), 1 ether);

        // Inside B's fill, nested in A's: B pays as itself, and a direct call reaches A.
        ScriptHandler.Step[] memory inner = new ScriptHandler.Step[](2);
        inner[0] = ScriptHandler.Step(true, buyer, 1 ether, "");
        inner[1] = ScriptHandler.Step(false, address(a), 0, abi.encodeCall(Order.execute, (buyer, 1 ether, "")));
        bytes memory nested = abi.encodeCall(Order.fill, ("b", abi.encode(inner)));
        a.fill("a", script.script(false, address(b), 0, nested));
        assertEq(buyer.balance, 102 ether);
        assertEq(script.fills(address(a)), 1);
        assertEq(script.fills(address(b)), 1);

        // Once the fills are over, neither order accepts the handler.
        vm.startPrank(address(script));
        vm.expectRevert(Order.Unauthorized.selector);
        a.execute(buyer, 0, "");
        vm.expectRevert(Order.Unauthorized.selector);
        b.execute(buyer, 0, "");
        vm.stopPrank();

        // Without a fill of its own, B is out of reach from A's fill.
        vm.deal(address(b), 1 ether);
        bytes memory reach = script.script(false, address(b), 0, abi.encodeCall(Order.execute, (buyer, 1 ether, "")));
        vm.expectRevert(Order.Unauthorized.selector);
        a.fill("a", reach);

        // An order cannot be filled again inside its own fill, however deeply nested.
        bytes memory back = abi.encodeCall(
            Order.fill, ("b", script.script(false, address(a), 0, abi.encodeCall(Order.fill, ("a", ""))))
        );
        bytes memory reenter = script.script(false, address(b), 0, back);
        vm.expectRevert(Order.Reentrant.selector);
        a.fill("a", reenter);

        // Calling the handler directly, as if it were an order, touches only the caller's state.
        vm.prank(attacker);
        script.onFill(attacker, 0, "", "");
        assertEq(script.fills(attacker), 1);
        assertEq(script.fills(address(a)), 1);
        assertEq(address(b).balance, 1 ether);
    }

    /// One AcquisitionBid handler serves two bids. A seller paid by bid A sells into bid B from
    /// inside that payment. Each bid's recorded history and funds reflect only its own fill.
    function test_sharedHandlerStateStaysPerOrder() public {
        address vaultA = makeAddr("vaultA");
        address vaultB = makeAddr("vaultB");
        bytes memory ca = _bidConfig(vaultA, 5 ether, rising, _risingParams(1 ether, 0, 5000), address(0));
        bytes memory cb = _bidConfig(vaultB, 5 ether, rising, _risingParams(2 ether, 0, 5000), address(0));
        vm.deal(seller, 3 ether);
        vm.deal(other, 3 ether);
        vm.prank(seller);
        Order a = market.create{value: 3 ether}(acquisition, ca, 0);
        vm.prank(other);
        Order b = market.create{value: 3 ether}(acquisition, cb, 0);

        Reenterer holder = new Reenterer();
        nft.mint(address(holder), 1);
        nft.mint(address(holder), 2);
        bytes memory approveAll = abi.encodeWithSignature("setApprovalForAll(address,bool)", address(a), true);
        holder.call(address(nft), 0, approveAll);
        holder.call(address(nft), 0, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(b), true));
        holder.arm(address(b), abi.encodeCall(Order.fill, (cb, abi.encode(2, 2 ether))));
        holder.call(address(a), 0, abi.encodeCall(Order.fill, (ca, abi.encode(1, 1 ether))));
        assertTrue(holder.succeeded());

        (uint128 priceA,, uint64 countA) = acquisition.state(address(a));
        (uint128 priceB,, uint64 countB) = acquisition.state(address(b));
        assertEq(priceA, 1 ether);
        assertEq(priceB, 2 ether);
        assertEq(countA, 1);
        assertEq(countB, 1);
        assertEq(address(a).balance, 2 ether);
        assertEq(address(b).balance, 1 ether);
        assertEq(nft.ownerOf(1), vaultA);
        assertEq(nft.ownerOf(2), vaultB);
        assertEq(address(holder).balance, 3 ether);
    }

    /// Maintenance on an active order goes through its handler. This handler lets the owner,
    /// and only the owner, take inventory back in a fill, and the order stays active.
    function test_handlerCanAllowOwnerMaintenance() public {
        RestockableSale handler = new RestockableSale();
        TestToken token = new TestToken("T");
        bytes memory config = abi.encode(token, uint256(1 gwei));
        Order order = _create(seller, handler, config);
        token.mint(address(order), 100);

        vm.prank(seller);
        vm.expectRevert(Order.Unauthorized.selector);
        order.execute(address(token), 0, abi.encodeCall(IERC20.transfer, (seller, 40)));
        vm.prank(attacker);
        vm.expectRevert(RestockableSale.NotOwner.selector);
        order.fill(config, abi.encode(true, 40));

        vm.prank(seller);
        order.fill(config, abi.encode(true, 40));
        assertEq(token.balanceOf(seller), 40);
        assertFalse(order.closed());

        vm.prank(buyer);
        order.fill{value: 10 gwei}(config, abi.encode(false, 10));
        assertEq(token.balanceOf(buyer), 10);
        assertEq(seller.balance, 10 gwei);
        assertEq(token.balanceOf(address(order)), 50);
    }
}
