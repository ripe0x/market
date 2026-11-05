// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {TestNFT, TestToken} from "./utils/Mocks.sol";

/// An account that makes several calls in one call, as a filler's contract or wallet would.
/// Snapshots last one transaction, and Foundry ends one after every top-level test call, so
/// each scenario runs inside a single `run`.
contract Batch {
    function run(address[] memory targets, bytes[] memory data) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

contract FillVerifierTest is Test {
    FillVerifier verifier = new FillVerifier();
    TestToken token = new TestToken("T");
    TestNFT nft = new TestNFT();
    Batch alice = new Batch();
    Batch bob = new Batch();
    bytes aliceBalance = abi.encodeCall(IERC20.balanceOf, (address(alice)));

    function _run(Batch who, address t0, bytes memory d0, address t1, bytes memory d1) internal {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        (t[0], t[1], d[0], d[1]) = (t0, t1, d0, d1);
        who.run(t, d);
    }

    function _run(Batch who, address t0, bytes memory d0, address t1, bytes memory d1, address t2, bytes memory d2)
        internal
    {
        address[] memory t = new address[](3);
        bytes[] memory d = new bytes[](3);
        (t[0], t[1], t[2], d[0], d[1], d[2]) = (t0, t1, t2, d0, d1, d2);
        who.run(t, d);
    }

    function _snapshot(bytes memory query) internal view returns (bytes memory) {
        return abi.encodeCall(verifier.snapshot, (address(token), query));
    }

    function _requireIncrease(bytes memory query, uint256 minimum) internal view returns (bytes memory) {
        return abi.encodeCall(verifier.requireIncrease, (address(token), query, minimum));
    }

    function _mint(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(TestToken.mint, (to, amount));
    }

    function test_requireIncrease() public {
        token.mint(address(alice), 7);
        bytes memory mint5 = _mint(address(alice), 5);
        _run(
            alice,
            address(verifier),
            _snapshot(aliceBalance),
            address(token),
            mint5,
            address(verifier),
            _requireIncrease(aliceBalance, 5)
        );
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.TooLittle.selector, 5, 6));
        _run(
            alice,
            address(verifier),
            _snapshot(aliceBalance),
            address(token),
            mint5,
            address(verifier),
            _requireIncrease(aliceBalance, 6)
        );
    }

    function test_decreaseIsNoIncrease() public {
        token.mint(address(alice), 7);
        bytes memory spend = abi.encodeCall(IERC20.transfer, (address(bob), 3));
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.TooLittle.selector, 0, 1));
        _run(
            alice,
            address(verifier),
            _snapshot(aliceBalance),
            address(token),
            spend,
            address(verifier),
            _requireIncrease(aliceBalance, 1)
        );
    }

    /// Without a snapshot there is no baseline, so the check refuses rather than comparing to 0.
    function test_requireIncreaseNeedsOwnSnapshot() public {
        token.mint(address(alice), 7);
        vm.prank(address(alice));
        vm.expectRevert(FillVerifier.NoSnapshot.selector);
        verifier.requireIncrease(address(token), aliceBalance, 0);
    }

    /// Bob's snapshot of alice's balance is bob's: it does not give alice a baseline, and
    /// nobody but alice can set or overwrite hers.
    function test_snapshotsAreKeyedByCaller() public {
        Batch both = new Batch();
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        // bob snapshots inside the same transaction, then alice checks.
        address[] memory bt = new address[](1);
        bytes[] memory bd = new bytes[](1);
        (bt[0], bd[0]) = (address(verifier), _snapshot(aliceBalance));
        (t[0], d[0]) = (address(bob), abi.encodeCall(Batch.run, (bt, bd)));
        bt[0] = address(verifier);
        bd[0] = _requireIncrease(aliceBalance, 0);
        (t[1], d[1]) = (address(alice), abi.encodeCall(Batch.run, (bt, bd)));
        vm.expectRevert(FillVerifier.NoSnapshot.selector);
        both.run(t, d);
    }

    /// A zero balance is a real snapshot, distinct from no snapshot.
    function test_zeroSnapshotCounts() public {
        bytes memory mint1 = _mint(address(alice), 1);
        _run(
            alice,
            address(verifier),
            _snapshot(aliceBalance),
            address(token),
            mint1,
            address(verifier),
            _requireIncrease(aliceBalance, 1)
        );
    }

    function test_requireEqual() public {
        nft.mint(address(alice), 1);
        bytes memory owner1 = abi.encodeCall(IERC721.ownerOf, (1));
        verifier.requireEqual(address(nft), owner1, abi.encode(alice));
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.Mismatch.selector, abi.encode(alice)));
        verifier.requireEqual(address(nft), owner1, abi.encode(bob));
    }

    function test_ethBalance() public {
        vm.deal(address(alice), 3 ether);
        assertEq(verifier.ethBalance(address(alice)), 3 ether);
        bytes memory eth = abi.encodeCall(verifier.ethBalance, (address(alice)));
        bytes memory snap = abi.encodeCall(verifier.snapshot, (address(verifier), eth));
        bytes memory check = abi.encodeCall(verifier.requireIncrease, (address(verifier), eth, 1));
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.TooLittle.selector, 0, 1));
        _run(alice, address(verifier), snap, address(verifier), check);
    }

    /// Queries are static calls: even with an approval, the verifier cannot move anything.
    function test_queriesCannotChangeState() public {
        token.mint(address(this), 10);
        token.approve(address(verifier), 10);
        bytes memory pull = abi.encodeCall(IERC20.transferFrom, (address(this), address(bob), 10));
        vm.expectRevert(FillVerifier.QueryFailed.selector);
        verifier.snapshot(address(token), pull);
        vm.expectRevert(FillVerifier.QueryFailed.selector);
        verifier.requireEqual(address(token), pull, abi.encode(true));
        assertEq(token.balanceOf(address(this)), 10);
    }

    function test_failedOrMalformedQueryReverts() public {
        vm.expectRevert(FillVerifier.QueryFailed.selector);
        verifier.snapshot(makeAddr("eoa"), aliceBalance); // no code: empty result
        vm.expectRevert(FillVerifier.QueryFailed.selector);
        verifier.snapshot(address(nft), abi.encodeCall(IERC721.ownerOf, (99))); // reverts
    }
}
