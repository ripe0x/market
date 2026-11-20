// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Base} from "./utils/Base.sol";
import {Admission, Order, OrderSpec} from "../src/Order.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";

/// A collection that acts on its caller's identity: on any ETH it receives, if the caller is an
/// approved operator for the armed token, it moves that token. Models why approving a party that
/// can be made to call out (an Order) is dangerous, while approving ExchangeAction is not.
contract ApprovalThief is ERC721 {
    uint256 public armedId;
    address public victim;
    address public loot;
    bool public armed;

    constructor() ERC721("Thief", "THF") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm(uint256 id, address victim_, address loot_) external {
        armedId = id;
        victim = victim_;
        loot = loot_;
        armed = true;
    }

    receive() external payable {
        if (armed && (getApproved(armedId) == msg.sender || isApprovedForAll(victim, msg.sender))) {
            armed = false;
            _transfer(victim, loot, armedId);
        }
    }
}

/// On receiving bid proceeds, tries to reenter another live bid to pull a third party's token
/// that was approved to ExchangeAction. The attempt is caught so the outer trade still settles.
contract ReentryReceiver {
    Order public target;
    bytes public data;
    bool public attempted;
    bool public succeeded;

    function set(Order t, bytes calldata d) external {
        target = t;
        data = d;
    }

    receive() external payable {
        if (address(target) != address(0)) {
            attempted = true;
            try target.execute(data) {
                succeeded = true;
            } catch {
                succeeded = false;
            }
        }
    }
}

contract BidApprovalTest is Base {
    function _bid(IERC721 token, bool anyToken, uint256 id, address recipient, uint64 maxExec, uint256 funding)
        internal
        returns (Order o)
    {
        OrderSpec memory spec =
            _spec(address(exchange), Admission.Public, 0, bidder, _bidConfig(address(token), anyToken, id, _fixed(1 ether), recipient, maxExec, 0));
        vm.prank(bidder);
        o = market.createAndActivate{value: funding}(spec, bytes32(++salt));
    }

    // (1) Approving an Order lets the bid issuer steal a token through a hostile collection;
    //     approving ExchangeAction cannot be abused the same way.

    function test_approvingOrderLetsIssuerStealViaHostileCollection() public {
        ApprovalThief thief = new ApprovalThief();
        thief.mint(seller, 1);
        Order bid = _bid(IERC721(address(thief)), true, 0, bidder, 1, 1 ether);

        // The seller mistakenly approves the Order (not ExchangeAction) for the token.
        vm.prank(seller);
        thief.approve(address(bid), 1);
        thief.arm(1, seller, attacker);

        // The bid issuer cancels and routes surplus to the hostile collection, whose receive()
        // runs with msg.sender == the Order, an approved operator -> the token is stolen.
        vm.startPrank(bidder);
        bid.cancel();
        bid.withdrawSurplus(address(thief), 1 ether);
        vm.stopPrank();

        assertEq(thief.ownerOf(1), attacker, "approving the Order let the token be stolen");
    }

    function test_approvingExchangeCannotBeAbused() public {
        ApprovalThief thief = new ApprovalThief();
        thief.mint(seller, 1);
        Order bid = _bid(IERC721(address(thief)), true, 0, bidder, 1, 1 ether);

        // The seller approves ExchangeAction, as intended.
        vm.prank(seller);
        thief.approve(address(exchange), 1);
        thief.arm(1, seller, attacker);

        vm.startPrank(bidder);
        bid.cancel();
        bid.withdrawSurplus(address(thief), 1 ether);
        vm.stopPrank();

        // The Order is not the approved operator, so the hostile receive() does nothing.
        assertEq(thief.ownerOf(1), seller, "approving ExchangeAction kept the token safe");
        assertTrue(thief.armed(), "hostile hook never fired for the Order");
    }

    // (2) A malicious proceeds receiver cannot reenter to pull another holder's token.

    function test_maliciousProceedsReceiverCannotReenterToSteal() public {
        // Victim owns a token and approves ExchangeAction (the correct approval).
        nft.mint(makeAddr("victim"), 10);
        address victim = makeAddr("victim");
        vm.prank(victim);
        nft.approve(address(exchange), 10);

        // A live bid (bid2) that the attacker would love to drive to pull the victim's token.
        Order bid2 = _bid(nft, true, 0, attacker, 1, 1 ether);

        // The attacker's proceeds receiver will try to reenter bid2 with the victim's token.
        ReentryReceiver evil = new ReentryReceiver();
        evil.set(bid2, abi.encode(uint256(10), uint256(0), address(evil)));

        // bid1 pays proceeds to the evil receiver during a genuine execution by seller.
        Order bid1 = _bid(nft, true, 0, bidder, 1, 1 ether);
        nft.mint(seller, 11);
        vm.startPrank(seller);
        nft.approve(address(exchange), 11);
        bid1.execute(abi.encode(uint256(11), uint256(0), address(evil)));
        vm.stopPrank();

        assertTrue(evil.attempted(), "reentry was attempted");
        assertFalse(evil.succeeded(), "reentry to pull the victim's token failed");
        assertEq(nft.ownerOf(10), victim, "victim keeps the token");
        assertEq(nft.ownerOf(11), bidder, "the genuine bid still settled");
        assertEq(exchange.executions(address(bid2)), 0, "bid2 never consumed an execution");
    }

    // (3) Approving only the Order does not authorize a bid execution.

    function test_approvingOrderDoesNotAuthorizeBidExecution() public {
        nft.mint(seller, 20);
        Order bid = _bid(nft, true, 0, bidder, 1, 1 ether);
        vm.prank(seller);
        nft.approve(address(bid), 20); // approve the Order, not ExchangeAction

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", address(exchange), 20));
        bid.execute(abi.encode(uint256(20), uint256(0), seller));
    }

    // (4) ExchangeAction only ever pulls the executing actor's own token.

    function test_cannotPullNonActorToken() public {
        address victim = makeAddr("victim2");
        nft.mint(victim, 30);
        vm.prank(victim);
        nft.approve(address(exchange), 30);

        Order bid = _bid(nft, true, 0, bidder, 1, 1 ether);
        // attacker executes with the victim's token id: it is not the actor's token.
        vm.prank(attacker);
        vm.expectRevert(ExchangeAction.NotHeld.selector);
        bid.execute(abi.encode(uint256(30), uint256(0), attacker));
        assertEq(nft.ownerOf(30), victim);
    }
}
