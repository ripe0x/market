// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Rights} from "./Rights.sol";

interface IExerciseHandler {
    /// @notice Validate backing and return fixed, inspectable exercise terms before minting.
    function validate(address account, bytes calldata config) external view returns (bytes memory terms);

    /// @notice Perform one operation through the calling account. Input is untrusted.
    function onExercise(
        address holder,
        uint256 value,
        bytes calldata config,
        bytes calldata terms,
        bytes calldata input
    ) external returns (bytes memory result);
}

interface IRightMarket {
    function isRight(address account) external view returns (bool);
}

/// @notice Isolated backing account for one transferable, one-use execution right.
contract Right {
    enum State {
        Pending,
        Active,
        Exercised,
        Expired,
        Surrendered,
        Canceled
    }

    IRightMarket public immutable market;
    Rights public immutable rights;
    address private immutable implementation = address(this);

    State public state;
    bool public transient exercising;
    bytes public activationTerms;
    mapping(address beneficiary => uint256) public creditOf;
    uint256 public totalCredits;

    event Activated(bytes terms);
    event Exercised(address indexed holder, uint256 value);
    event Expired();
    event Surrendered(address indexed holder);
    event SetupCanceled();
    event Credited(address indexed beneficiary, uint256 amount);
    event CreditWithdrawn(address indexed beneficiary, address indexed recipient, uint256 amount);

    error NotARight();
    error Unauthorized();
    error WrongState();
    error Reentrant();
    error WrongConfig();
    error HandlerCodeChanged();
    error DeadlinePassed();
    error NotExpired();
    error EncumberedBalance();
    error ZeroBeneficiary();

    constructor(address market_, Rights rights_) {
        market = IRightMarket(market_);
        rights = rights_;
    }

    function issuer() public view returns (address) {
        return address(bytes20(_arg(0)));
    }

    function handler() public view returns (IExerciseHandler) {
        return IExerciseHandler(address(bytes20(_arg(20))));
    }

    function handlerCodehash() public view returns (bytes32) {
        return _arg(40);
    }

    function configHash() public view returns (bytes32) {
        return _arg(72);
    }

    function deadline() public view returns (uint256) {
        return uint256(_arg(104));
    }

    function residual() public view returns (address) {
        return address(bytes20(_arg(136)));
    }

    function tokenId() public view returns (uint256) {
        _requireRight();
        return uint256(uint160(address(this)));
    }

    function isLive() public view returns (bool) {
        _requireRight();
        uint256 end = deadline();
        return state == State.Active && !exercising && (end == 0 || block.timestamp < end);
    }

    function activate(bytes calldata config) external {
        _requireRight();
        if (msg.sender != issuer()) revert Unauthorized();
        if (state != State.Pending) revert WrongState();
        if (keccak256(config) != configHash()) revert WrongConfig();
        _checkHandler();
        if (_deadlinePassed()) revert DeadlinePassed();
        bytes memory terms = handler().validate(address(this), config);
        activationTerms = terms;
        state = State.Active;
        rights.mint(issuer(), tokenId());
        emit Activated(terms);
    }

    function cancelSetup() external {
        _requireRight();
        if (msg.sender != issuer()) revert Unauthorized();
        if (state != State.Pending) revert WrongState();
        state = State.Canceled;
        emit SetupCanceled();
    }

    function exercise(bytes calldata config, bytes calldata input) external payable returns (bytes memory result) {
        _requireRight();
        if (state != State.Active) revert WrongState();
        if (exercising) revert Reentrant();
        if (_deadlinePassed()) revert DeadlinePassed();
        if (rights.ownerOf(tokenId()) != msg.sender) revert Unauthorized();
        if (keccak256(config) != configHash()) revert WrongConfig();
        _checkHandler();
        address holder = msg.sender;
        exercising = true;
        result = handler().onExercise(holder, msg.value, config, activationTerms, input);
        state = State.Exercised;
        rights.burn(tokenId());
        exercising = false;
        emit Exercised(holder, msg.value);
    }

    function surrender() external {
        _requireRight();
        if (exercising) revert Reentrant();
        if (state != State.Active) revert WrongState();
        if (_deadlinePassed()) revert DeadlinePassed();
        if (rights.ownerOf(tokenId()) != msg.sender) revert Unauthorized();
        state = State.Surrendered;
        rights.burn(tokenId());
        emit Surrendered(msg.sender);
    }

    function finalizeExpiry() external {
        _requireRight();
        if (exercising) revert Reentrant();
        State previous = state;
        if (previous != State.Pending && previous != State.Active) revert WrongState();
        if (!_deadlinePassed() || deadline() == 0) revert NotExpired();
        state = State.Expired;
        if (previous == State.Active) rights.burn(tokenId());
        emit Expired();
    }

    /// @notice Only the bound handler may use backing, and only during an authorized exercise.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        _requireRight();
        if (!exercising || msg.sender != address(handler())) revert Unauthorized();
        return _call(target, value, data);
    }

    /// @notice Reserve ETH for a beneficiary; the reservation survives every terminal state.
    function credit(address beneficiary, uint256 amount) external {
        _requireRight();
        if (!exercising || msg.sender != address(handler())) revert Unauthorized();
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (amount > address(this).balance - totalCredits) revert EncumberedBalance();
        creditOf[beneficiary] += amount;
        totalCredits += amount;
        emit Credited(beneficiary, amount);
    }

    /// @notice Anyone may pay a recorded beneficiary, but cannot change the destination.
    function releaseCredit(address beneficiary) external {
        _withdrawCredit(beneficiary, payable(beneficiary));
    }

    /// @notice A beneficiary may redirect only its own credit.
    function withdrawCredit(address payable recipient) external {
        _withdrawCredit(msg.sender, recipient);
    }

    function _withdrawCredit(address beneficiary, address payable recipient) private {
        _requireRight();
        if (exercising) revert Reentrant();
        if (recipient == address(0)) revert ZeroBeneficiary();
        uint256 amount = creditOf[beneficiary];
        if (amount == 0) return;
        creditOf[beneficiary] = 0;
        totalCredits -= amount;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "credit transfer failed");
        emit CreditWithdrawn(beneficiary, recipient, amount);
    }

    /// @notice Terminal recovery by the committed residual beneficiary, never from credits.
    function recover(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        _requireRight();
        if (exercising) revert Reentrant();
        if (msg.sender != residual()) revert Unauthorized();
        if (state == State.Pending || state == State.Active) revert WrongState();
        return _call(target, value, data);
    }

    receive() external payable {
        _requireRight();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        _requireRight();
        return this.onERC721Received.selector;
    }

    function _call(address target, uint256 value, bytes calldata data) private returns (bytes memory ret) {
        if (value > address(this).balance - totalCredits) revert EncumberedBalance();
        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
        }
        return result;
    }

    function _checkHandler() private view {
        if (address(handler()).codehash != handlerCodehash()) revert HandlerCodeChanged();
    }

    function _deadlinePassed() private view returns (bool) {
        uint256 end = deadline();
        return end != 0 && block.timestamp >= end;
    }

    function _requireRight() private view {
        if (address(this) == implementation || !market.isRight(address(this))) revert NotARight();
    }

    function _arg(uint256 offset) private view returns (bytes32 word) {
        _requireRight();
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(0x2d, offset), 0x20)
            word := mload(0)
        }
    }
}
