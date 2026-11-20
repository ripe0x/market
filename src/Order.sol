// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Actions} from "./Actions.sol";

/// @notice Who may execute a live order. Public: any account the action accepts, repeatedly
/// until the action reports completion. Holder: only the current owner of the order's Actions
/// token, in one call that must complete.
enum Admission {
    Public,
    Holder
}

enum OrderState {
    Pending,
    Live,
    Completed,
    Canceled,
    Expired,
    Surrendered
}

/// @notice What the order is doing within the current transaction. Every state-changing entry
/// point requires Idle, so an order never runs two operations at once.
enum Phase {
    Idle,
    Activating,
    Executing,
    Releasing,
    Withdrawing
}

/// @notice Every commitment an order address is derived from, except the issuer, the action's
/// runtime code hash and the salt.
struct OrderSpec {
    address action;
    Admission admission;
    /// Exclusive: the order cannot execute at or after this timestamp. Zero never expires.
    uint64 deadline;
    /// Receives backing and surplus once the order is no longer live. Never zero.
    address residual;
    bytes config;
}

/// @notice An action implementation, shared by many orders. Each callback comes from the order
/// it concerns; an implementation must authenticate that the caller is a Market order bound to
/// it and that the arguments match the order's own readable context before relying on them.
interface IAction {
    /// @notice Check backing and terms before the order goes live. The order stores the
    /// returned bytes once as its activation terms. Also used for advisory previews.
    function validate(address order, bytes calldata config) external view returns (bytes memory activationTerms);

    /// @notice Perform one execution through the calling order. `input` is untrusted. Return
    /// `complete` to end the order; a Holder order reverts unless this is true.
    function onExecute(
        address actor,
        uint256 suppliedValue,
        bytes calldata config,
        bytes calldata activationTerms,
        bytes calldata input
    ) external returns (bool complete, bytes memory result);

    /// @notice Clean up backing of an order that is not live. `recipient` is the residual
    /// beneficiary unless the residual itself called and chose another.
    function onRelease(
        address actor,
        address recipient,
        bytes calldata config,
        bytes calldata activationTerms,
        bytes calldata input
    ) external returns (bytes memory result);
}

/// @title Order
/// @notice An isolated account for one authorized contract action. Market deploys it as an
/// ERC-1167 clone of this contract with the issuer, the action, the action's runtime code hash,
/// the admission, deadline, residual beneficiary and full configuration appended to its code, so
/// every commitment is part of the address and stays readable after the order ends.
///
/// Lifecycle: Pending until activation, then Live, then exactly one terminal state. Only the
/// bound action acts as the order, and only inside `execute` or `release`. Neither the issuer nor
/// the residual beneficiary can make arbitrary calls as the order.
///
/// Native accounting: `totalCredits` of the balance is owed to credited beneficiaries and is
/// never spent by execution, release or surplus withdrawal.
///
/// The action code hash pins runtime bytecode only. It does not freeze a proxy's target,
/// mutable storage, dependencies or privileges held elsewhere.
contract Order {
    /// @dev Proxy code length preceding the appended arguments.
    uint256 private constant ARGS = 0x2d;
    /// @dev issuer 20, action 20, code hash 32, admission 1, deadline 8, residual 20.
    uint256 private constant FIXED_ARGS = 101;

    address public immutable market;
    Actions public immutable actions;
    address private immutable implementation = address(this);

    OrderState public state;
    /// @notice Stored once at activation.
    bytes public activationTerms;
    mapping(address beneficiary => uint256) public creditOf;
    uint256 public totalCredits;

    Phase public transient phase;
    /// @notice The caller of the current `execute` or `release`.
    address public transient actor;
    /// @notice ETH sent with the current `execute`.
    uint256 public transient suppliedValue;
    /// @notice Recipient of the current `release`.
    address public transient releaseRecipient;

    event Activated(bytes activationTerms);
    event Executed(address indexed actor, uint256 suppliedValue, bool complete);
    event Canceled();
    event Surrendered(address indexed holder);
    event Expired();
    event Released(address indexed actor, address indexed recipient);
    event Credited(address indexed beneficiary, uint256 amount);
    event CreditWithdrawn(address indexed beneficiary, address indexed recipient, uint256 amount);
    event SurplusWithdrawn(address indexed recipient, uint256 amount);

    error NotAnOrder();
    error Unauthorized();
    error WrongState();
    error Busy();
    error DeadlinePassed();
    error NotExpired();
    error ActionCodeChanged();
    error Incomplete();
    error EncumberedBalance();
    error ZeroAddress();
    error TransferFailed();

    constructor(address market_, Actions actions_) {
        market = market_;
        actions = actions_;
    }

    // ---- commitments ----

    function issuer() public view returns (address) {
        return address(bytes20(_word(0)));
    }

    function action() public view returns (address) {
        return address(bytes20(_word(20)));
    }

    function actionCodehash() public view returns (bytes32) {
        return _word(40);
    }

    function admission() public view returns (Admission) {
        return Admission(uint8(bytes1(_word(72))));
    }

    function deadline() public view returns (uint64) {
        return uint64(bytes8(_word(73)));
    }

    function residual() public view returns (address) {
        return address(bytes20(_word(81)));
    }

    function config() public view returns (bytes memory c) {
        _requireClone();
        uint256 size;
        assembly ("memory-safe") {
            size := sub(extcodesize(address()), add(ARGS, FIXED_ARGS))
        }
        c = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(address(), add(c, 0x20), add(ARGS, FIXED_ARGS), size)
        }
    }

    /// @notice The Actions token id of a Holder order: its own address.
    function tokenId() public view returns (uint256) {
        _requireClone();
        return uint256(uint160(address(this)));
    }

    // ---- views ----

    function freeBalance() public view returns (uint256) {
        return address(this).balance - totalCredits;
    }

    function isExpired() public view returns (bool) {
        uint256 end = deadline();
        return end != 0 && block.timestamp >= end;
    }

    /// @notice Executable now: live, unexpired and not in the middle of an operation.
    function isLive() public view returns (bool) {
        return state == OrderState.Live && phase == Phase.Idle && !isExpired();
    }

    /// @notice What `activate` would store, computed now. Advisory: backing can change before
    /// activation.
    function previewActivation() external view returns (bytes memory) {
        _checkCode();
        return IAction(action()).validate(address(this), config());
    }

    // ---- lifecycle ----

    /// @notice Validate backing and go live. Only the issuer, or Market inside
    /// `createAndActivate` for the order it just created. A Holder order mints its token to the
    /// issuer without a receiver callback.
    function activate() external {
        if (msg.sender != issuer() && msg.sender != market) revert Unauthorized();
        _requireIdle();
        if (state != OrderState.Pending) revert WrongState();
        if (isExpired()) revert DeadlinePassed();
        _checkCode();
        phase = Phase.Activating;
        bytes memory terms = IAction(action()).validate(address(this), config());
        activationTerms = terms;
        state = OrderState.Live;
        if (admission() == Admission.Holder) actions.mint(issuer(), tokenId());
        phase = Phase.Idle;
        emit Activated(terms);
    }

    /// @notice Run the action once. A failed action reverts every effect of the call.
    function execute(bytes calldata input) external payable returns (bytes memory result) {
        _requireIdle();
        if (state != OrderState.Live) revert WrongState();
        if (isExpired()) revert DeadlinePassed();
        bool holder = admission() == Admission.Holder;
        if (holder && actions.ownerOf(tokenId()) != msg.sender) revert Unauthorized();
        _checkCode();

        phase = Phase.Executing;
        actor = msg.sender;
        suppliedValue = msg.value;
        bool complete;
        (complete, result) = IAction(action()).onExecute(msg.sender, msg.value, config(), activationTerms, input);
        if (complete) {
            state = OrderState.Completed;
            if (holder) actions.burn(tokenId());
        } else if (holder) {
            revert Incomplete();
        }
        phase = Phase.Idle;
        actor = address(0);
        suppliedValue = 0;
        emit Executed(msg.sender, msg.value, complete);
    }

    /// @notice The issuer ends a Pending order, or a Live Public order. A Live Holder order is
    /// a commitment to its holder and cannot be canceled. After the deadline use finalizeExpiry.
    function cancel() external {
        _requireIdle();
        if (msg.sender != issuer()) revert Unauthorized();
        OrderState s = state;
        if (s != OrderState.Pending && !(s == OrderState.Live && admission() == Admission.Public)) {
            revert WrongState();
        }
        if (isExpired()) revert DeadlinePassed();
        state = OrderState.Canceled;
        emit Canceled();
    }

    /// @notice The holder gives up a Live Holder order before its deadline. Burns the token.
    function surrender() external {
        _requireIdle();
        if (state != OrderState.Live || admission() != Admission.Holder) revert WrongState();
        if (isExpired()) revert DeadlinePassed();
        if (actions.ownerOf(tokenId()) != msg.sender) revert Unauthorized();
        state = OrderState.Surrendered;
        actions.burn(tokenId());
        emit Surrendered(msg.sender);
    }

    /// @notice Anyone records expiry of a Pending or Live order once its deadline has passed.
    function finalizeExpiry() external {
        _requireIdle();
        OrderState s = state;
        if (s != OrderState.Pending && s != OrderState.Live) revert WrongState();
        if (deadline() == 0 || !isExpired()) revert NotExpired();
        state = OrderState.Expired;
        if (s == OrderState.Live && admission() == Admission.Holder) actions.burn(tokenId());
        emit Expired();
    }

    /// @notice Ask the action to clean up backing while the order is Pending or terminal.
    /// Only the residual beneficiary may choose a recipient other than itself; the action
    /// decides who else may trigger its cleanup.
    function release(address recipient, bytes calldata input) external returns (bytes memory result) {
        _requireIdle();
        if (state == OrderState.Live) revert WrongState();
        address r = residual();
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.sender != r && recipient != r) revert Unauthorized();
        _checkCode();
        phase = Phase.Releasing;
        actor = msg.sender;
        releaseRecipient = recipient;
        result = IAction(action()).onRelease(msg.sender, recipient, config(), activationTerms, input);
        phase = Phase.Idle;
        actor = address(0);
        releaseRecipient = address(0);
        emit Released(msg.sender, recipient);
    }

    // ---- action authority ----

    /// @notice Make one call as this order. Only the bound action, only during execute or
    /// release. Release calls carry no ETH. Never spends credited funds.
    function call(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        Phase p = phase;
        if (msg.sender != action() || (p != Phase.Executing && p != Phase.Releasing)) revert Unauthorized();
        if (p == Phase.Releasing && value != 0) revert Unauthorized();
        if (value > freeBalance()) revert EncumberedBalance();
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Reserve part of the free balance for `beneficiary`. Only the bound action, only
    /// during execution. Credits survive every terminal state.
    function credit(address beneficiary, uint256 amount) external {
        if (msg.sender != action() || phase != Phase.Executing) revert Unauthorized();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount > freeBalance()) revert EncumberedBalance();
        creditOf[beneficiary] += amount;
        totalCredits += amount;
        emit Credited(beneficiary, amount);
    }

    // ---- withdrawals ----

    /// @notice Anyone may pay a beneficiary its credit; the destination cannot be changed.
    function releaseCredit(address beneficiary) external {
        _withdrawCredit(beneficiary, beneficiary);
    }

    /// @notice A beneficiary sends its own credit wherever it chooses.
    function withdrawCredit(address recipient) external {
        _withdrawCredit(msg.sender, recipient);
    }

    /// @notice The residual beneficiary takes uncredited ETH once the order is not live.
    function withdrawSurplus(address recipient, uint256 amount) external {
        _requireIdle();
        if (msg.sender != residual()) revert Unauthorized();
        if (state == OrderState.Live) revert WrongState();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > freeBalance()) revert EncumberedBalance();
        _send(recipient, amount);
        emit SurplusWithdrawn(recipient, amount);
    }

    function _withdrawCredit(address beneficiary, address recipient) private {
        _requireIdle();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = creditOf[beneficiary];
        if (amount == 0) return;
        creditOf[beneficiary] = 0;
        totalCredits -= amount;
        _send(recipient, amount);
        emit CreditWithdrawn(beneficiary, recipient, amount);
    }

    /// @dev A failed transfer reverts, restoring any debit made before it.
    function _send(address to, uint256 amount) private {
        phase = Phase.Withdrawing;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        phase = Phase.Idle;
    }

    // ---- receiving ----

    receive() external payable {
        _requireClone();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        _requireClone();
        return this.onERC721Received.selector;
    }

    // ---- internals ----

    function _requireIdle() private view {
        if (phase != Phase.Idle) revert Busy();
    }

    function _checkCode() private view {
        if (action().codehash != actionCodehash()) revert ActionCodeChanged();
    }

    function _requireClone() private view {
        if (address(this) == implementation) revert NotAnOrder();
    }

    /// @dev 32 bytes of the appended arguments at `offset`. In a clone, `address()` is the
    /// clone, so this reads the clone's own code.
    function _word(uint256 offset) private view returns (bytes32 word) {
        _requireClone();
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(ARGS, offset), 0x20)
            word := mload(0)
        }
    }
}
