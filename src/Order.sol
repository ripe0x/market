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
/// @notice An account holding one authorized execution commitment. Deployed by `Market`.
///
/// Authority over this account's assets and permissions belongs to exactly two parties:
/// - `owner`, at any time except during a fill: recovery, revocation and anything else.
/// - `policy`, only during a fill, which anyone may start by calling `fill`.
///
/// The policy and the hash of its configuration are fixed at deployment and are part of this
/// account's address. Nothing in this contract knows what the order trades. There is no
/// delegatecall, no upgrade path and no other privileged party.
contract Order {
    address public immutable owner;
    IPolicy public immutable policy;
    bytes32 public immutable configHash;

    /// @notice Permanently stops fills. The owner keeps `execute` for recovery.
    bool public closed;
    /// @notice True only while `fill` is running. External contracts that grant this order
    /// authority can check it to accept calls made through the policy and refuse the owner.
    bool public transient filling;

    event Filled(address indexed caller, uint256 value);
    event Closed();

    error Unauthorized();
    error OrderClosed();
    error Reentrant();
    error WrongConfig();

    constructor(address owner_, IPolicy policy_, bytes32 configHash_) payable {
        owner = owner_;
        policy = policy_;
        configHash = configHash_;
    }

    /// @notice Ask this order to execute. The policy decides what happens and may take
    /// payment only from `msg.sender`. Reverts entirely if any part fails.
    function fill(bytes calldata config, bytes calldata input) external payable returns (bytes memory result) {
        if (closed) revert OrderClosed();
        if (filling) revert Reentrant();
        if (keccak256(config) != configHash) revert WrongConfig();
        filling = true;
        result = policy.onFill(msg.sender, msg.value, config, input);
        filling = false;
        emit Filled(msg.sender, msg.value);
    }

    /// @notice Make one call as this order. During a fill only the policy may call this;
    /// otherwise only the owner. A failing call reverts with its own reason.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        if (msg.sender != (filling ? address(policy) : owner)) revert Unauthorized();
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Stop all future fills. Callable by the owner, or by this order itself, which
    /// lets a policy end a single use order from inside its fill.
    function close() external {
        if (msg.sender != owner && msg.sender != address(this)) revert Unauthorized();
        closed = true;
        emit Closed();
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
