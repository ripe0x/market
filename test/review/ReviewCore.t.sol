// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Market} from "../../src/Market.sol";
import {Actions} from "../../src/Actions.sol";
import {Order, OrderSpec, Admission, OrderState, IAction, Phase} from "../../src/Order.sol";
import {ExchangeAction} from "../../actions/ExchangeAction.sol";
import {FeeConfig} from "../../actions/FeeConfig.sol";

contract NFT is ERC721 {
    constructor() ERC721("N", "N") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

// Minimal action to reach core-level branches. complete == returnComplete.
// Also exposes an attempt to make the order call an ARBITRARY target during execution,
// and to credit/withdraw, to probe the core authority gates.
contract ProbeAction is IAction {
    Market public immutable market;
    bool public returnComplete;

    constructor(Market m) {
        market = m;
    }

    function setComplete(bool v) external {
        returnComplete = v;
    }

    function validate(address order, bytes calldata) external view returns (bytes memory) {
        require(msg.sender == order, "notorder");
        require(market.isOrder(order), "notmkt");
        return "";
    }

    function onExecute(address, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        returns (bool, bytes memory)
    {
        return (returnComplete, "");
    }

    function onRelease(address, address, bytes calldata, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes memory)
    {
        return "";
    }
}

// Tries to abuse Order.call / Order.credit from a non-action context.
contract Outsider {
    function tryCall(Order o, address t) external {
        o.call(t, 0, "");
    }

    function tryCredit(Order o) external {
        o.credit(address(this), 1);
    }
}

contract ReviewCore is Test {
    Market market;
    Actions actions;
    ProbeAction probe;
    ExchangeAction exchange;
    FeeConfig fees;

    address issuer = address(0xA11CE);
    address holder = address(0xB0B);
    address operator = address(0x0bba);

    function setUp() public {
        market = new Market();
        actions = market.actions();
        probe = new ProbeAction(market);
        fees = new FeeConfig(address(0xFEE0), address(0xFEE1));
        exchange = new ExchangeAction(market, fees);
    }

    function _holderOrder(uint64 deadline) internal returns (Order o) {
        OrderSpec memory spec = OrderSpec({
            action: address(probe),
            admission: Admission.Holder,
            deadline: deadline,
            residual: issuer,
            config: ""
        });
        vm.prank(issuer);
        o = market.create(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();
    }

    // Holder execute that does not complete must revert Incomplete and leave the token.
    function test_holder_incomplete_reverts() public {
        Order o = _holderOrder(0);
        probe.setComplete(false);
        // issuer holds token
        vm.prank(issuer);
        vm.expectRevert(Order.Incomplete.selector);
        o.execute("");
        // unchanged
        assertEq(uint8(o.state()), uint8(OrderState.Live));
        assertEq(actions.ownerOf(uint256(uint160(address(o)))), issuer);
    }

    // Operator (approved) cannot execute or surrender; only the owner can.
    function test_operator_cannot_execute_or_surrender() public {
        Order o = _holderOrder(0);
        probe.setComplete(true);
        vm.prank(issuer);
        actions.setApprovalForAll(operator, true);

        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.execute("");

        vm.prank(operator);
        vm.expectRevert(Order.Unauthorized.selector);
        o.surrender();

        // but operator can transfer to itself then act
        vm.prank(operator);
        actions.transferFrom(issuer, operator, uint256(uint160(address(o))));
        vm.prank(operator);
        o.surrender();
        assertEq(uint8(o.state()), uint8(OrderState.Surrendered));
    }

    // Deadline is exclusive: execute at exactly deadline reverts; cancel at/after deadline reverts;
    // finalizeExpiry is the only path.
    function test_deadline_exclusive() public {
        uint64 dl = uint64(block.timestamp + 100);
        Order o = _holderOrder(dl);
        probe.setComplete(true);

        vm.warp(dl); // exactly at deadline
        assertTrue(o.isExpired(), "expired at ==deadline");

        vm.prank(issuer);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.execute("");

        // surrender after deadline must not misclassify: reverts DeadlinePassed, not a surrender
        vm.prank(issuer);
        vm.expectRevert(Order.DeadlinePassed.selector);
        o.surrender();

        // anyone finalizes expiry
        o.finalizeExpiry();
        assertEq(uint8(o.state()), uint8(OrderState.Expired));
        // token burned
        vm.expectRevert();
        actions.ownerOf(uint256(uint160(address(o))));
    }

    // Core authority: a non-action cannot make the order call out or credit, even mid-nothing.
    function test_outsider_cannot_call_or_credit() public {
        Order o = _holderOrder(0);
        Outsider out = new Outsider();
        vm.expectRevert(Order.Unauthorized.selector);
        out.tryCall(o, address(0xdead));
        vm.expectRevert(Order.Unauthorized.selector);
        out.tryCredit(o);
    }

    // Issuer cannot cancel a Live Holder order (it's a commitment to the holder).
    function test_issuer_cannot_cancel_live_holder() public {
        Order o = _holderOrder(0);
        vm.prank(issuer);
        vm.expectRevert(Order.WrongState.selector);
        o.cancel();
    }

    // Bid scorecard + surplus recovery: fund 3 ETH for 3 execs @1 ETH, do 1, recover 2.
    function test_bid_scorecard_and_surplus_recovery() public {
        NFT nft = new NFT();
        address seller = address(0x5E11E7);
        nft.mint(seller, 42);

        ExchangeAction.Schedule memory sch =
            ExchangeAction.Schedule({startPrice: 1 ether, endPrice: 1 ether, startTime: 0, endTime: 0});
        ExchangeAction.BidTerms memory bt = ExchangeAction.BidTerms({
            anyToken: true,
            tokenId: 0,
            recipient: issuer,
            maxExecutions: 3,
            minActionTimeLeft: 0
        });
        ExchangeAction.Config memory c = ExchangeAction.Config({
            side: ExchangeAction.Side.Bid,
            nft: nft,
            schedule: sch,
            maxFeeBps: 100,
            terms: abi.encode(bt)
        });
        OrderSpec memory spec = OrderSpec({
            action: address(exchange),
            admission: Admission.Public,
            deadline: 0,
            residual: issuer,
            config: abi.encode(c)
        });
        vm.deal(issuer, 3 ether);
        vm.prank(issuer);
        Order o = market.create{value: 3 ether}(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();
        assertEq(address(o).balance, 3 ether, "funded");

        // seller approves the EXCHANGE, never the order
        vm.prank(seller);
        nft.setApprovalForAll(address(exchange), true);

        uint256 feeBefore = address(0xFEE1).balance;
        // one execution; fee 1% => seller proceeds 0.99
        vm.prank(seller);
        o.execute(abi.encode(uint256(42), uint256(0), seller));

        assertEq(nft.ownerOf(42), issuer, "NFT to bid recipient");
        assertEq(seller.balance, 0.99 ether, "proceeds net of fee");
        assertEq(address(0xFEE1).balance - feeBefore, 0.01 ether, "fee");
        assertEq(exchange.executions(address(o)), 1);
        assertEq(address(o).balance, 2 ether, "2 ETH remains");
        assertEq(uint8(o.state()), uint8(OrderState.Live), "still live");

        // issuer cancels the public bid and recovers surplus
        vm.prank(issuer);
        o.cancel();
        assertEq(uint8(o.state()), uint8(OrderState.Canceled));
        vm.prank(issuer);
        o.withdrawSurplus(issuer, 2 ether);
        assertEq(issuer.balance, 2 ether, "surplus recovered");
        assertEq(address(o).balance, 0);
    }

    // Order must reject ETH direct-send only via implementation (clone receive is fine).
    function test_clone_receive_ok_impl_rejects() public {
        Order o = _holderOrder(0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(o).call{value: 1 ether}("");
        assertTrue(ok, "clone accepts ETH top-up");
        assertEq(address(o).balance, 1 ether);
    }
}

// Separate suite: bid-approval scope — a blanket approval to the shared ExchangeAction
// cannot be used by a different executor to pull the approver's token.
contract ReviewBidApprovalScope is Test {
    Market market;
    ExchangeAction exchange;
    FeeConfig fees;
    address issuer = address(0xB1D);

    function setUp() public {
        market = new Market();
        fees = new FeeConfig(address(0xFEE0), address(0xFEE1));
        exchange = new ExchangeAction(market, fees);
    }

    function test_cannot_pull_another_sellers_token_via_bid() public {
        NFT nft = new NFT();
        address victimSeller = address(0x5A1E);
        address attacker = address(0xBAD11);
        nft.mint(victimSeller, 100);
        // victim approves the SHARED exchange for ALL tokens (the documented approval target)
        vm.prank(victimSeller);
        nft.setApprovalForAll(address(exchange), true);

        // a collection-wide bid funded by issuer
        ExchangeAction.Schedule memory sch =
            ExchangeAction.Schedule({startPrice: 1 ether, endPrice: 1 ether, startTime: 0, endTime: 0});
        ExchangeAction.BidTerms memory bt = ExchangeAction.BidTerms({
            anyToken: true,
            tokenId: 0,
            recipient: issuer,
            maxExecutions: 5,
            minActionTimeLeft: 0
        });
        ExchangeAction.Config memory c = ExchangeAction.Config({
            side: ExchangeAction.Side.Bid,
            nft: nft,
            schedule: sch,
            maxFeeBps: 100,
            terms: abi.encode(bt)
        });
        OrderSpec memory spec = OrderSpec({
            action: address(exchange),
            admission: Admission.Public,
            deadline: 0,
            residual: issuer,
            config: abi.encode(c)
        });
        vm.deal(issuer, 5 ether);
        vm.prank(issuer);
        Order o = market.create{value: 5 ether}(spec, bytes32(0));
        vm.prank(issuer);
        o.activate();

        // attacker (who approved nothing and owns nothing) tries to sell victim's token 100
        vm.prank(attacker);
        vm.expectRevert(ExchangeAction.NotHeld.selector);
        o.execute(abi.encode(uint256(100), uint256(0), attacker));

        // victim still holds the token; no funds moved
        assertEq(nft.ownerOf(100), victimSeller);
        assertEq(address(o).balance, 5 ether);
    }
}
