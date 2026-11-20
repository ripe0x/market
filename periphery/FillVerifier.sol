// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FillVerifier
/// @notice Outcome checks for calls made within one transaction. A calling account can take
/// a snapshot, execute an order and check the resulting state. A failed check reverts its call;
/// reverting the entire transaction requires that failure to propagate through the caller:
/// payment and approvals are then rolled back with the execution.
///
///   1. `snapshot(nft, balanceOf(me))`
///   2. `order.execute(input)`, sent by the executing account itself, as usual
///   3. `requireIncrease(nft, balanceOf(me), 1)`, or `requireEqual(nft, ownerOf(id), me)`
///
/// It has no custody functions or owner, needs no approvals and reads other contracts only with
/// `staticcall`. Snapshots live in transient storage keyed by the caller, so only the account
/// that took one can use it; each serves one `requireIncrease`, and all vanish when the
/// transaction ends. Results depend on the queried contract's responses; these checks do not
/// authenticate its code or establish the meaning of the returned data.
contract FillVerifier {
    error QueryFailed();
    error NoSnapshot();
    error TooLittle(uint256 increase, uint256 minimum);
    error Mismatch(bytes result);

    /// @notice Record what `target` returns for `query` now, for `requireIncrease` later in
    /// this transaction. The result must be one uint256.
    function snapshot(address target, bytes calldata query) external {
        uint256 value = _uint(target, query);
        bytes32 slot = _slot(target, query);
        assembly ("memory-safe") {
            tstore(slot, value)
            tstore(add(slot, 1), 1)
        }
    }

    /// @notice Revert unless `target` now returns at least `minimum` more for `query` than at
    /// the caller's snapshot of the same query. Uses up the snapshot, so a second check needs a
    /// fresh one: otherwise two executions could both be judged against the first one's baseline.
    function requireIncrease(address target, bytes calldata query, uint256 minimum) external {
        bytes32 slot = _slot(target, query);
        uint256 before;
        uint256 taken;
        assembly ("memory-safe") {
            before := tload(slot)
            taken := tload(add(slot, 1))
            tstore(add(slot, 1), 0)
        }
        if (taken == 0) revert NoSnapshot();
        uint256 value = _uint(target, query);
        if (value < before + minimum) revert TooLittle(value > before ? value - before : 0, minimum);
    }

    /// @notice Revert unless `target` returns exactly `expected` for `query`, for example
    /// `ownerOf(id)` returning `abi.encode(me)`.
    function requireEqual(address target, bytes calldata query, bytes calldata expected) external view {
        bytes memory result = _call(target, query);
        if (keccak256(result) != keccak256(expected)) revert Mismatch(result);
    }

    /// @notice `account`'s ETH balance, so ETH can be checked like a token by querying this contract.
    function ethBalance(address account) external view returns (uint256) {
        return account.balance;
    }

    function _call(address target, bytes calldata query) private view returns (bytes memory result) {
        bool ok;
        (ok, result) = target.staticcall(query);
        if (!ok) revert QueryFailed();
    }

    function _uint(address target, bytes calldata query) private view returns (uint256) {
        bytes memory result = _call(target, query);
        if (result.length != 32) revert QueryFailed();
        return abi.decode(result, (uint256));
    }

    function _slot(address target, bytes calldata query) private view returns (bytes32) {
        return keccak256(abi.encode(msg.sender, target, query));
    }
}
