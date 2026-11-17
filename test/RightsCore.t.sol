// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {IExerciseHandler, Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";

/// A permissionless handler accepted by Market. Its backed asset is one ETH in the right
/// account; exercise adds exactly 0.5 ETH of payment credit without moving that backing.
contract ETHRightHandler is IExerciseHandler {
    address public immutable market;

    constructor(Market market_) {
        market = address(market_);
    }

    function validate(address account, bytes calldata config) external view returns (bytes memory) {
        require(Market(market).isRight(account), "unknown account");
        require(account.balance >= 1 ether, "unbacked");
        (address payee, address callback) = abi.decode(config, (address, address));
        require(payee != address(0), "payee");
        return abi.encode(payee, callback);
    }

    function onExercise(address, uint256 value, bytes calldata, bytes calldata terms, bytes calldata)
        external
        returns (bytes memory)
    {
        require(Market(market).isRight(msg.sender), "unknown account");
        Right account = Right(payable(msg.sender));
        require(address(account.handler()) == address(this) && account.exercising(), "not exercising");
        require(value == 0.5 ether, "exact payment");
        (address payee, address callback) = abi.decode(terms, (address, address));
        if (callback != address(0)) account.execute(callback, 0, abi.encodeWithSignature("attack()"));
        account.credit(payee, value);
        return "";
    }
}

contract ReentryHolder {
    Right public right;
    Rights public rights;
    bool public anySucceeded;

    constructor(Rights rights_) {
        rights = rights_;
    }

    function setRight(Right right_) external {
        require(address(right) == address(0));
        right = right_;
    }

    function exercise(bytes calldata config) external payable {
        right.exercise{value: msg.value}(config, "");
    }

    function attack() external {
        uint256 id = right.tokenId();
        (bool a,) = address(rights).call(abi.encodeCall(IERC721.transferFrom, (address(this), address(0xBEEF), id)));
        (bool b,) = address(right).call(abi.encodeCall(Right.surrender, ()));
        (bool c,) = address(right).call(abi.encodeCall(Right.finalizeExpiry, ()));
        (bool d,) = address(right).call(abi.encodeCall(Right.recover, (address(this), 0, "")));
        (bool e,) = address(right).call(abi.encodeCall(Right.exercise, ("", "")));
        anySucceeded = a || b || c || d || e;
    }

    receive() external payable {}
}

/// An accepted handler that composes two distinct rights in one transaction. It also tries
/// to use a sibling account outside that sibling's exercise window.
contract NestedRightHandler is IExerciseHandler {
    Market public immutable market;
    bool public siblingBypassSucceeded;
    uint256 public exercises;

    constructor(Market market_) {
        market = market_;
    }

    function validate(address account, bytes calldata) external view returns (bytes memory) {
        require(market.isRight(account) && msg.sender == account, "not account");
        return "";
    }

    function onExercise(address, uint256, bytes calldata config, bytes calldata, bytes calldata)
        external
        returns (bytes memory)
    {
        require(market.isRight(msg.sender), "not account");
        Right account = Right(payable(msg.sender));
        require(address(account.handler()) == address(this) && account.exercising(), "not exercising");
        address sibling = abi.decode(config, (address));
        if (sibling != address(0)) {
            (bool ok,) = sibling.call(abi.encodeCall(Right.execute, (address(this), 0, "")));
            siblingBypassSucceeded = ok;
            Right(payable(sibling)).exercise(abi.encode(address(0)), "");
        }
        exercises++;
        return "";
    }
}

contract RightsCoreTest is Test {
    Market market;
    Rights rights;
    ETHRightHandler handler;
    address issuer = makeAddr("issuer");
    address buyer = makeAddr("buyer");
    address second = makeAddr("second");
    address residual = makeAddr("residual");
    address payee = makeAddr("payee");
    bytes config;

    function setUp() public {
        vm.warp(1_000_000);
        market = new Market();
        rights = market.rights();
        handler = new ETHRightHandler(market);
        config = abi.encode(payee, address(0));
        vm.deal(issuer, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(second, 10 ether);
    }

    function _pending(uint256 deadline) internal returns (Right account) {
        vm.prank(issuer);
        account = market.createRight{value: 1 ether}(handler, config, deadline, residual, bytes32(uint256(1)));
    }

    function _active(uint256 deadline) internal returns (Right account) {
        account = _pending(deadline);
        vm.prank(issuer);
        account.activate(config);
    }

    function test_pendingHasNoTokenOrExecutionAndCancellationIsPermanent() public {
        Right account = _pending(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        assertEq(uint256(account.state()), uint256(Right.State.Pending));
        vm.expectRevert();
        rights.ownerOf(id);
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.execute(issuer, 1 ether, "");
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.recover(issuer, 1 ether, "");
        vm.prank(issuer);
        account.cancelSetup();
        vm.prank(issuer);
        vm.expectRevert(Right.WrongState.selector);
        account.activate(config);
        vm.prank(residual);
        account.recover(residual, 1 ether, "");
        assertEq(residual.balance, 1 ether);
    }

    function test_transferExerciseAndReservedCredits() public {
        Right account = _active(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        assertEq(rights.ownerOf(id), issuer);
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.prank(buyer);
        rights.transferFrom(buyer, second, id);
        assertEq(address(account).balance, 1 ether, "backing stays put");
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.exercise{value: 0.5 ether}(config, "");
        vm.prank(second);
        account.exercise{value: 0.5 ether}(config, "");
        assertEq(uint256(account.state()), uint256(Right.State.Exercised));
        assertEq(account.creditOf(payee), 0.5 ether);
        assertEq(account.totalCredits(), 0.5 ether);
        vm.expectRevert();
        rights.ownerOf(id);
        vm.prank(residual);
        vm.expectRevert(Right.EncumberedBalance.selector);
        account.recover(residual, 1.5 ether, "");
        vm.prank(residual);
        account.recover(residual, 1 ether, "");
        vm.prank(payee);
        account.withdrawCredit(payable(payee));
        assertEq(residual.balance, 1 ether);
        assertEq(payee.balance, 0.5 ether);
        assertEq(address(account).balance, 0);
        vm.prank(second);
        vm.expectRevert(Right.WrongState.selector);
        account.exercise{value: 0.5 ether}(config, "");
    }

    function test_expiryBoundaryAndPerpetualCommitment() public {
        uint256 end = block.timestamp + 100;
        Right account = _active(end);
        uint256 id = account.tokenId();
        vm.warp(end - 1);
        assertTrue(account.isLive());
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.warp(end);
        assertFalse(account.isLive());
        vm.prank(buyer);
        vm.expectRevert(Right.DeadlinePassed.selector);
        account.exercise{value: 0.5 ether}(config, "");
        vm.prank(buyer);
        vm.expectRevert(Rights.InvalidTransfer.selector);
        rights.transferFrom(buyer, issuer, id);
        account.finalizeExpiry();
        vm.expectRevert();
        rights.ownerOf(id);
        vm.prank(residual);
        account.recover(residual, 1 ether, "");

        vm.prank(issuer);
        Right perpetual = market.createRight{value: 1 ether}(handler, config, 0, residual, bytes32(uint256(2)));
        vm.prank(issuer);
        perpetual.activate(config);
        vm.warp(end + 1000 days);
        assertTrue(perpetual.isLive());
        vm.expectRevert(Right.NotExpired.selector);
        perpetual.finalizeExpiry();
    }

    function test_surrenderAndNoIssuerShortcut() public {
        Right account = _active(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.surrender();
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.recover(issuer, 1 ether, "");
        vm.prank(buyer);
        account.surrender();
        vm.prank(residual);
        account.recover(residual, 1 ether, "");
        assertEq(residual.balance, 1 ether);
        vm.prank(issuer);
        vm.expectRevert(Right.WrongState.selector);
        account.activate(config);
    }

    function test_directImplementationAndCounterfeitAccountCannotMint() public {
        Right direct = Right(payable(market.rightImplementation()));
        vm.expectRevert(Right.NotARight.selector);
        direct.activate(config);
        Right counterfeit = Right(payable(Clones.clone(market.rightImplementation())));
        vm.expectRevert(Right.NotARight.selector);
        counterfeit.activate(config);
        vm.prank(address(counterfeit));
        vm.expectRevert(Rights.NotBackingAccount.selector);
        rights.mint(issuer, uint256(uint160(address(counterfeit))));
        Right account = _pending(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        vm.prank(address(account));
        vm.expectRevert(Rights.NotBackingAccount.selector);
        rights.mint(issuer, id);
    }

    function test_transferIntoOwnBackingAccountRejected() public {
        Right account = _active(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        vm.prank(issuer);
        vm.expectRevert(Rights.InvalidTransfer.selector);
        rights.transferFrom(issuer, address(account), id);
    }

    function test_approvedOperatorCanTransferButCannotDirectlyExercise() public {
        Right account = _active(block.timestamp + 1 days);
        uint256 id = account.tokenId();
        vm.prank(issuer);
        rights.approve(attacker(), id);
        vm.prank(attacker());
        vm.expectRevert(Right.Unauthorized.selector);
        account.exercise(config, "");
        vm.prank(attacker());
        rights.transferFrom(issuer, buyer, id);
        assertEq(rights.ownerOf(id), buyer);
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        account.surrender();
    }

    function attacker() internal pure returns (address) {
        return address(0xA77AC);
    }

    function test_localExecutionLockCoversAllSameRightEntrypoints() public {
        ReentryHolder hostile = new ReentryHolder(rights);
        bytes memory hostileConfig = abi.encode(payee, address(hostile));
        vm.prank(issuer);
        Right guarded = market.createRight{value: 1 ether}(
            handler, hostileConfig, block.timestamp + 1 days, address(hostile), bytes32(uint256(2))
        );
        hostile.setRight(guarded);
        vm.prank(issuer);
        guarded.activate(hostileConfig);
        uint256 id = guarded.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, address(hostile), id);
        vm.deal(address(hostile), 0.5 ether);
        hostile.exercise{value: 0.5 ether}(hostileConfig);
        assertFalse(hostile.anySucceeded());
        assertEq(uint256(guarded.state()), uint256(Right.State.Exercised));
    }

    function test_distinctAccountsComposeWithoutSharedExecutionAuthority() public {
        NestedRightHandler nested = new NestedRightHandler(market);
        bytes memory secondConfig = abi.encode(address(0));
        vm.prank(issuer);
        Right secondRight =
            market.createRight(nested, secondConfig, block.timestamp + 1 days, residual, bytes32(uint256(10)));
        vm.prank(issuer);
        secondRight.activate(secondConfig);
        uint256 secondId = secondRight.tokenId();
        vm.prank(issuer);
        rights.transferFrom(issuer, address(nested), secondId);

        bytes memory firstConfig = abi.encode(address(secondRight));
        vm.prank(issuer);
        Right firstRight =
            market.createRight(nested, firstConfig, block.timestamp + 1 days, residual, bytes32(uint256(11)));
        vm.prank(issuer);
        firstRight.activate(firstConfig);
        vm.prank(issuer);
        firstRight.exercise(firstConfig, "");
        assertFalse(nested.siblingBypassSucceeded());
        assertEq(nested.exercises(), 2);
        assertEq(uint256(firstRight.state()), uint256(Right.State.Exercised));
        assertEq(uint256(secondRight.state()), uint256(Right.State.Exercised));
    }
}
