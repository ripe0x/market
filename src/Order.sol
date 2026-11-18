// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Defines what happens when an order is filled: checks conditions, decides which calls
/// the order makes and may keep state between fills. One handler can serve many orders.
/// @dev Order.execute grants authority over the calling order only during its fill. A handler
/// must authenticate its caller before using separately granted authority or trusting fill
/// context. NFTBid uses ERC721 approvals granted to the shared handler. State shared between
/// orders must be keyed by the authenticated order.
interface IOrderHandler {
    /// @notice Called by an order from inside `Order.fill`. While this call runs, and only
    /// then, `msg.sender.execute` accepts calls from this handler. Revert to reject the fill;
    /// everything the fill did is undone.
    /// @param caller The authenticated account that called fill. The handler must enforce
    /// any limits on using that account's assets or approvals.
    /// @param value ETH sent with `fill`. The order already holds it.
    /// @param config The order's configuration. The order has checked it against its commitment.
    /// @param input The caller's parameters. Untrusted.
    /// @return result Returned to the caller of `fill`.
    function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
        external
        returns (bytes memory result);
}

/// @title Order
/// @notice A cancelable execution account with its own address, balance and storage. Market
/// creates ERC-1167 clones with immutable arguments. Compatible clones can also be deployed
/// outside Market; those accounts have no Market.createdAt record.
///
/// Authority over this account's assets and permissions follows its lifecycle:
/// - Active: only `handler`, only during a fill, which anyone may start by calling `fill`.
///   The owner may only `close`.
/// - Closed, permanently: no more fills. The current fill retains handler execution authority
///   until it returns; otherwise only `owner` can execute for recovery and revocation.
/// Recovery remains subject to external asset rules, including Rights transfer restrictions.
///
/// The owner, the handler, the handler's code hash and the hash of its configuration are
/// appended to the clone's code at deployment, so they are part of the order's address and can
/// never change. There is no initializer. Nothing in this contract knows what the order trades.
/// The only `delegatecall` is the clone's own, to this fixed code; there is no upgrade path and
/// no other privileged party.
contract Order {
    /// @notice Permanently stops new fills. Owner execution begins after any current fill ends.
    bool public closed;
    /// @notice True only while `fill` is running. External contracts that grant this order
    /// authority can check it to accept calls made through the handler and refuse the owner.
    bool public transient filling;

    /// @dev Inside a clone `address(this)` is the clone, so this matches only direct calls to
    /// the implementation, which has no owner, handler or terms and must never act as an order.
    address private immutable implementation = address(this);

    event Filled(address indexed caller, uint256 value);
    event Closed();

    error Unauthorized();
    error OrderClosed();
    error Reentrant();
    error WrongConfig();
    error HandlerCodeChanged();
    error NotAnOrder();

    function owner() public view returns (address) {
        return address(bytes20(_arg(0)));
    }

    function handler() public view returns (IOrderHandler) {
        return IOrderHandler(address(bytes20(_arg(20))));
    }

    /// @notice Committed handler runtime bytecode hash. Fills require it unchanged; mutable
    /// handler storage and external dependencies are not committed by this hash.
    function handlerCodehash() public view returns (bytes32) {
        return _arg(40);
    }

    function configHash() public view returns (bytes32) {
        return _arg(72);
    }

    /// @notice Invoke the bound handler with the caller, value and committed configuration.
    /// The handler defines settlement conditions and payment authorization. A handler revert
    /// rolls back the entire fill.
    function fill(bytes calldata config, bytes calldata input) external payable returns (bytes memory result) {
        if (closed) revert OrderClosed();
        if (filling) revert Reentrant();
        if (keccak256(config) != configHash()) revert WrongConfig();
        IOrderHandler h = handler();
        // Since EIP-6780 deployed code can change only by being destroyed in its creation
        // transaction and redeployed; this refuses to run code other than what was committed.
        if (address(h).codehash != handlerCodehash()) revert HandlerCodeChanged();
        filling = true;
        result = h.onFill(msg.sender, msg.value, config, input);
        filling = false;
        emit Filled(msg.sender, msg.value);
    }

    /// @notice Make one call as this order. During a fill only the handler may call this, even
    /// if it has closed the order in that fill. Otherwise only the owner, and only once the order
    /// is closed. A failing call reverts with its own reason.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        bool allowed = filling ? msg.sender == address(handler()) : closed && msg.sender == owner();
        if (!allowed) revert Unauthorized();
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Stop all future fills. Owner execution is available once the current fill ends.
    /// Outside a fill only the owner may call this. During a fill only this order itself may,
    /// through execute, so only the handler can end the order mid-fill. The owner cannot close
    /// under it. External permissions remain until the owner or handler revokes them.
    function close() external {
        if (msg.sender != (filling ? address(this) : owner())) revert Unauthorized();
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

    /// @dev Read 32 bytes of immutable arguments after the 45 byte ERC-1167 proxy code:
    /// owner (20 bytes), handler (20), handler code hash (32), config hash (32). In a clone,
    /// `address()` is the clone, so this reads the clone's own code.
    function _arg(uint256 offset) private view returns (bytes32 word) {
        _requireClone();
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(0x2d, offset), 0x20)
            word := mload(0)
        }
    }
}
