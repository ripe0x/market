// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {HandlerBase} from "../../examples/HandlerBase.sol";
import {DutchAuction} from "../../examples/DutchAuction.sol";
import {CapitalPool} from "../../examples/CapitalPool.sol";
import {AcquisitionBid, ICapitalSource, IBidStrategy} from "../../examples/AcquisitionBid.sol";
import {RisingStrategy} from "../../examples/BidStrategies.sol";
import {Base} from "../utils/Base.sol";
import {TestNFT} from "../utils/Mocks.sol";

// ---------------------------------------------------------------------------
// Helper handlers / mocks used only by this review file.
// ---------------------------------------------------------------------------

/// During its own order's fill, tries to reach into a DIFFERENT order (chosen by someone
/// else, bound to a different handler) and drain it.
contract CrossOrderAttackHandler is IOrderHandler {
    function onFill(address, uint256, bytes calldata, bytes calldata input)
        external
        returns (bytes memory)
    {
        (address victim, address to) = abi.decode(input, (address, address));
        Order(payable(victim)).execute(to, victim.balance, "");
        return "";
    }
}

/// A handler whose owner can flip its behaviour AFTER an order is created and funded, without
/// changing the order's address or its committed config hash. Models an upgradeable / mutable
/// handler: the config commitment binds config bytes and the handler *address*, never its code.
contract MutableHandler is HandlerBase {
    address public immutable boss;
    bool public rugged;

    constructor(address boss_) {
        boss = boss_;
    }

    function rug() external {
        require(msg.sender == boss, "only boss");
        rugged = true;
    }

    // config = abi.encode(IERC721 nft, uint256 id, uint256 price, address seller)
    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory)
    {
        (IERC721 nft, uint256 id, uint256 price, address payee) =
            abi.decode(config, (IERC721, uint256, uint256, address));
        address recipient = abi.decode(input, (address));
        require(value >= price, "underpaid");
        if (rugged) {
            // Keep the buyer's ETH, deliver nothing.
            _sendETH(payee, value);
            return "";
        }
        _exec(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (msg.sender, recipient, id)));
        _sendETH(payee, price);
        _sendETH(caller, value - price);
        return "";
    }
}

/// Pretends to be an order mid-fill and re-enters `draw` from its ETH-receive hook to try to
/// pull more than its accrued allowance in a single outer call.
contract ReentrantGrantee {
    CapitalPool public pool;
    uint256 public totalReceived;
    bool private entered;

    function filling() external pure returns (bool) {
        return true;
    }

    function set(CapitalPool p) external {
        pool = p;
    }

    function go(uint256 amount) external {
        pool.draw(amount);
    }

    receive() external payable {
        totalReceived += msg.value;
        if (!entered) {
            entered = true;
            // Try to pull the same amount again while the first draw is still unwinding.
            try pool.draw(msg.value) {} catch {}
        }
    }
}

contract ReviewPoC is Base {
    // -----------------------------------------------------------------------
    // 1. Cross-handler isolation: an order's handler cannot touch an order that
    //    did not choose it. (Confirms the central isolation property.)
    // -----------------------------------------------------------------------
    function test_crossHandlerIsolationHolds() public {
        // Attacker's own order, bound to a hostile handler.
        CrossOrderAttackHandler evil = new CrossOrderAttackHandler();
        Order attackOrder = _create(attacker, evil, "");

        // An unrelated victim: a funded DutchAuction sale owned by `seller`.
        (Order victim,) = _listDutch(seller, 1);
        vm.deal(address(victim), 7 ether);

        // Filling the attacker's order cannot drain the victim: victim.execute rejects the
        // attacker order as an unauthorised caller, so the whole fill reverts.
        vm.prank(attacker);
        vm.expectRevert(Order.Unauthorized.selector);
        attackOrder.fill("", abi.encode(address(victim), attacker));

        assertEq(address(victim).balance, 7 ether, "victim ETH untouched");
        assertEq(nft.ownerOf(1), address(victim), "victim NFT untouched");
    }

    // -----------------------------------------------------------------------
    // 2. A mutable/upgradeable handler can change an order's behaviour AFTER a
    //    counterparty inspects it, with the SAME order address and config hash.
    //    The config commitment does not pin the handler's code.
    // -----------------------------------------------------------------------
    function test_mutableHandlerChangesTermsAfterCommit() public {
        address boss = makeAddr("boss");
        MutableHandler pol = new MutableHandler(boss);
        nft.mint(seller, 42);

        bytes memory config = abi.encode(IERC721(address(nft)), uint256(42), uint256(1 ether), seller);
        Order order = _create(seller, pol, config);
        vm.prank(seller);
        nft.transferFrom(seller, address(order), 42);

        // Honest fill works: buyer gets the NFT for 1 ETH.
        vm.prank(buyer);
        order.fill{value: 1 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(42), buyer);

        // Boss flips behaviour. No change to the order address or config hash.
        bytes32 hashBefore = order.configHash();
        vm.prank(boss);
        pol.rug();
        assertEq(order.configHash(), hashBefore, "config hash unchanged");

        // A second listing of the same kind now steals the buyer's ETH and delivers nothing.
        nft.mint(seller, 43);
        bytes memory config2 = abi.encode(IERC721(address(nft)), uint256(43), uint256(1 ether), seller);
        Order order2 = _create(seller, pol, config2);
        vm.prank(seller);
        nft.transferFrom(seller, address(order2), 43);

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        order2.fill{value: 1 ether}(config2, abi.encode(buyer));
        assertEq(nft.ownerOf(43), address(order2), "NFT NOT delivered after rug");
        assertEq(buyer.balance, buyerBefore - 1 ether, "buyer still charged");
        assertEq(seller.balance, 1 ether + 1 ether, "seller kept both payments");
    }

    // -----------------------------------------------------------------------
    // 3. CapitalPool: a reentrant grantee cannot exceed its accrued allowance.
    //    (Confirms checks-effects-interactions in draw.)
    // -----------------------------------------------------------------------
    function test_capitalPoolReentrancyBounded() public {
        address funder = makeAddr("funder");
        vm.deal(funder, 100 ether);
        vm.prank(funder);
        CapitalPool pool = new CapitalPool{value: 10 ether}(funder);

        ReentrantGrantee g = new ReentrantGrantee();
        g.set(pool);

        // Grant that accrues fast and is capped at exactly 1 ETH.
        vm.prank(funder);
        pool.setGrant(address(g), 1 ether, 1 ether); // 1 ETH/sec, cap 1 ETH
        skip(5); // allowance pegged at the 1 ETH cap
        assertEq(pool.allowance(address(g)), 1 ether);

        // Draw the whole allowance; the receive hook tries to draw again and must fail.
        g.go(1 ether);

        assertEq(g.totalReceived(), 1 ether, "reentry gained nothing extra");
        assertEq(pool.allowance(address(g)), 0, "allowance fully spent, not more");
        assertEq(address(pool).balance, 9 ether, "pool lost exactly the allowance");
    }

    // -----------------------------------------------------------------------
    // 4. AcquisitionBid: donating ETH to the order to inflate `currentBid` does
    //    not let a seller extract extra value from the capital pool. The order
    //    spends its own balance (incl. the donation) before drawing.
    // -----------------------------------------------------------------------
    function test_bidDonationDoesNotOverdrawPool() public {
        address funder = makeAddr("funder");
        address operator = makeAddr("operator");
        address vault = makeAddr("vault");
        address holder = makeAddr("holder");
        vm.deal(funder, 100 ether);
        vm.deal(operator, 10 ether);

        vm.prank(funder);
        CapitalPool pool = new CapitalPool{value: 10 ether}(funder);

        // Strategy bids 100% of available capital (so capital is the binding constraint),
        // maxPrice high, funded by a generous pool grant.
        bytes memory config =
            _bidConfig(vault, 100 ether, share, abi.encode(uint256(10_000)), address(pool));
        vm.prank(operator);
        Order bid = market.create{value: 1 ether}(acquisition, config, 0);
        vm.prank(funder);
        pool.setGrant(address(bid), 1 ether, 5 ether);
        skip(10); // grant accrues to its 5 ETH cap

        nft.mint(holder, 1);
        uint256 poolBefore = address(pool).balance;

        // Holder donates 3 ETH to the order, then sells at the (now higher) currentBid.
        vm.deal(holder, 3 ether);
        vm.prank(holder);
        (bool ok,) = address(bid).call{value: 3 ether}("");
        assertTrue(ok);

        AcquisitionBid.Config memory c = abi.decode(config, (AcquisitionBid.Config));
        uint256 current = acquisition.currentBid(address(bid), c);

        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        bid.fill(config, abi.encode(uint256(1), current));
        vm.stopPrank();

        uint256 drawnFromPool = poolBefore - address(pool).balance;
        // The pool only ever covered (price - order's own balance). The 3 ETH donation was
        // the holder's own money round-tripping, not a drain on the pool.
        assertLe(drawnFromPool, 5 ether, "pool draw within grant cap");
        // Net to holder from the POOL = payout - their own donation.
        // payout == current; donation == 3 ETH; order had 1 ETH of its own.
        // So pool contributed current - 4 ETH (order's 1 + donation 3) when positive.
        uint256 orderOwnFunds = 4 ether; // 1 ETH created + 3 ETH donated
        uint256 expectedPoolDraw = current > orderOwnFunds ? current - orderOwnFunds : 0;
        assertEq(drawnFromPool, expectedPoolDraw, "pool only funds the shortfall after order funds");
    }

    // -----------------------------------------------------------------------
    // 5. AcquisitionBid: a griefer sells a collection token for price 0, recording a
    //    zero clearing price. Originally this reset RisingStrategy's base to 0 and
    //    suppressed the bid curve. Repaired: the base never restarts below startPrice.
    //    (Edited by the lead after the fix; the reviewer's original asserted a bid of 0.)
    // -----------------------------------------------------------------------
    function test_zeroPriceFillResetsStrategyBase() public {
        address operator = makeAddr("operator");
        address vault = makeAddr("vault");
        address griefer = makeAddr("griefer");
        vm.deal(operator, 10 ether);

        // RisingStrategy: starts 1 ETH, +0.01/s, resets to 80% of clearing price.
        bytes memory config =
            _bidConfig(vault, 10 ether, rising, _risingParams(1 ether, 0.01 ether, 8000), address(0));
        vm.prank(operator);
        Order bid = market.create{value: 5 ether}(acquisition, config, 0);
        AcquisitionBid.Config memory c = abi.decode(config, (AcquisitionBid.Config));

        skip(1000); // quote has risen well above 1 ETH
        uint256 before = acquisition.currentBid(address(bid), c);
        assertGt(before, 1 ether);

        // Griefer tries to sell a (cheap) collection token for 0. Repaired: refused outright,
        // so nothing is recorded and the climb continues.
        nft.mint(griefer, 1);
        vm.startPrank(griefer);
        nft.approve(address(bid), 1);
        vm.expectRevert(AcquisitionBid.ZeroPrice.selector);
        bid.fill(config, abi.encode(uint256(1), uint256(0)));
        vm.stopPrank();

        (,, uint64 count) = acquisition.state(address(bid));
        assertEq(count, 0, "nothing recorded");
        assertEq(acquisition.currentBid(address(bid), c), before, "bid unchanged");
        assertEq(nft.ownerOf(1), griefer);
    }
}
