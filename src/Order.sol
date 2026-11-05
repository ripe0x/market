// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The code an order's creator chose to decide what a fill does.
/// @dev A policy acts only by calling back `Order.execute` on the order that called it.
/// It should hold no assets and no authority of its own, because every order bound to it
/// calls it, and anyone can call it directly while pretending to be an order.
interface IPolicy {
    /// @notice Called by an order from inside `Order.fill`. While this call runs, and only
    /// then, `msg.sender.execute` accepts calls from this policy. Revert to reject the fill;
    /// everything the fill did is undone.
    /// @param caller The account that called `fill`. The only account a fill may take from.
    /// @param value ETH sent with `fill`. The order already holds it.
    /// @param config The order's configuration. The order has checked it against its commitment.
    /// @param input The caller's parameters. Untrusted.
    /// @return result Returned to the caller of `fill`.
    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory result);
}

/// @title Order
/// @notice An account holding one authorized execution commitment. Every order is an ERC-1167
/// clone of this contract deployed by `Market`, with its own address, balance and storage.
///
/// Authority over this account's assets and permissions belongs to exactly two parties:
/// - `owner`, at any time except during a fill: recovery, revocation and anything else.
/// - `policy`, only during a fill, which anyone may start by calling `fill`.
///
/// The owner, the policy, the policy's code hash and the hash of its configuration are appended
/// to the clone's code at deployment, so they are part of the order's address and can never
/// change. There is no initializer. Nothing in this contract knows what the order trades. The
/// only `delegatecall` is the clone's own, to this fixed code; there is no upgrade path and no
/// other privileged party.
contract Order {
    /// @notice Permanently stops fills. The owner keeps `execute` for recovery.
    bool public closed;
    /// @notice True only while `fill` is running. External contracts that grant this order
    /// authority can check it to accept calls made through the policy and refuse the owner.
    bool public transient filling;

    /// @dev Inside a clone `address(this)` is the clone, so this matches only direct calls to
    /// the implementation, which has no owner, policy or terms and must never act as an order.
    address private immutable implementation = address(this);

    event Filled(address indexed caller, uint256 value);
    event Closed();

    error Unauthorized();
    error OrderClosed();
    error Reentrant();
    error WrongConfig();
    error PolicyCodeChanged();
    error NotAnOrder();

    function owner() public view returns (address) {
        return address(bytes20(_arg(0)));
    }

    function policy() public view returns (IPolicy) {
        return IPolicy(address(bytes20(_arg(20))));
    }

    /// @notice The policy's code hash when this order was created. Fills require it unchanged.
    function policyCodehash() public view returns (bytes32) {
        return _arg(40);
    }

    function configHash() public view returns (bytes32) {
        return _arg(72);
    }

    /// @notice Ask this order to execute. The policy decides what happens and may take
    /// payment only from `msg.sender`. Reverts entirely if any part fails.
    function fill(bytes calldata config, bytes calldata input) external payable returns (bytes memory result) {
        if (closed) revert OrderClosed();
        if (filling) revert Reentrant();
        if (keccak256(config) != configHash()) revert WrongConfig();
        IPolicy p = policy();
        // Since EIP-6780 deployed code can change only by being destroyed in its creation
        // transaction and redeployed; this refuses to run code other than what was committed.
        if (address(p).codehash != policyCodehash()) revert PolicyCodeChanged();
        filling = true;
        result = p.onFill(msg.sender, msg.value, config, input);
        filling = false;
        emit Filled(msg.sender, msg.value);
    }

    /// @notice Make one call as this order. During a fill only the policy may call this;
    /// otherwise only the owner. A failing call reverts with its own reason.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        if (msg.sender != (filling ? address(policy()) : owner())) revert Unauthorized();
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Stop all future fills. Callable by the owner, or by this order itself, which
    /// lets a policy end a single use order from inside its fill. Permissions this account
    /// holds in other contracts are not revoked; the owner or the policy must do that.
    function close() external {
        if (msg.sender != owner() && msg.sender != address(this)) revert Unauthorized();
        closed = true;
        emit Closed();
    }

    receive() external payable {
        _requireClone();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        _requireClone();
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        _requireClone();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _requireClone();
        return this.onERC1155BatchReceived.selector;
    }

    function _requireClone() private view {
        if (address(this) == implementation) revert NotAnOrder();
    }

    /// @dev 32 bytes of the arguments `Market` appended after the 45 byte ERC-1167 proxy code:
    /// owner (20 bytes), policy (20), policy code hash (32), config hash (32). In a clone,
    /// `address()` is the clone, so this reads the clone's own code.
    function _arg(uint256 offset) private view returns (bytes32 word) {
        _requireClone();
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(0x2d, offset), 0x20)
            word := mload(0)
        }
    }
}
