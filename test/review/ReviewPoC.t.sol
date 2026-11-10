// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {HandlerBase} from "../../handlers/HandlerBase.sol";
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

contract ReviewPoC is Base {
    // -----------------------------------------------------------------------
    // 1. Cross-handler isolation: an order's handler cannot touch an order that
    //    did not choose it. (Confirms the central isolation property.)
    // -----------------------------------------------------------------------
    function test_crossHandlerIsolationHolds() public {
        // Attacker's own order, bound to a hostile handler.
        CrossOrderAttackHandler evil = new CrossOrderAttackHandler();
        Order attackOrder = _create(attacker, evil, "");

        // An unrelated victim: a funded NFTSale order owned by `seller`.
        (Order victim,) = _listSale(seller, 1, 1 ether);
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
}
