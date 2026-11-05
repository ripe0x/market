// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPolicy, Order} from "../../src/Order.sol";

contract TestNFT is ERC721 {
    constructor() ERC721("Test", "TST") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract TestMulti is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract TestToken is ERC20 {
    constructor(string memory name) ERC20(name, name) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Burns 1% of every transfer.
contract FeeToken is TestToken("FEE") {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// USDT style: transfer functions return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Reports success without moving anything.
contract FalseToken is TestToken("FALSE") {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// Records what an order passes to its policy and lets the test script the fill.
contract ProbePolicy is IPolicy {
    address public caller;
    uint256 public value;
    bytes public config;
    bytes public input;
    bool public sawFilling;

    function onFill(address caller_, uint256 value_, bytes calldata config_, bytes calldata input_)
        external
        returns (bytes memory)
    {
        (caller, value, config, input) = (caller_, value_, config_, input_);
        sawFilling = Order(payable(msg.sender)).filling();
        // input: optional list of (target, value, data) calls to make as the order
        if (input_.length != 0) {
            (address target, uint256 v, bytes memory data) = abi.decode(input_, (address, uint256, bytes));
            return Order(payable(msg.sender)).execute(target, v, data);
        }
        return "probe";
    }
}

/// A hostile policy: sends everything the order holds in ETH to its author.
contract DrainPolicy is IPolicy {
    address public immutable thief;

    constructor(address thief_) {
        thief = thief_;
    }

    function onFill(address, uint256, bytes calldata, bytes calldata input) external returns (bytes memory) {
        Order(payable(msg.sender)).execute(thief, msg.sender.balance, "");
        // Also try to take whatever order and token the input names.
        if (input.length != 0) {
            (address victim, address token, uint256 id) = abi.decode(input, (address, address, uint256));
            Order(payable(victim)).execute(token, 0, abi.encodeCall(IERC721.transferFrom, (victim, thief, id)));
        }
        return "";
    }
}

/// A hostile policy that keeps a reference to its order and tries to act later.
contract StashPolicy is IPolicy {
    Order public stashed;

    function onFill(address, uint256, bytes calldata, bytes calldata) external returns (bytes memory) {
        stashed = Order(payable(msg.sender));
        return "";
    }

    function useLater(address target, uint256 value, bytes calldata data) external {
        stashed.execute(target, value, data);
    }
}

/// A policy that tries to fill its own order again from inside the fill.
contract ReentrantPolicy is IPolicy {
    function onFill(address, uint256, bytes calldata config, bytes calldata) external returns (bytes memory) {
        Order(payable(msg.sender)).fill(config, "");
        return "";
    }
}

/// A policy that always fails, standing in for a broken or hostile policy.
contract RevertPolicy is IPolicy {
    function onFill(address, uint256, bytes calldata, bytes calldata) external pure returns (bytes memory) {
        revert("broken");
    }
}

/// Receives ETH and tries something hostile with it. Swallows the failure so the outer call
/// continues, and records whether the attempt succeeded.
contract Reenterer {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        if (target == address(0) || attempted) return;
        attempted = true;
        (succeeded,) = target.call(payload);
    }

    function call(address to, uint256 value, bytes calldata data) external payable returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call{value: value}(data);
        require(ok, "call failed");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Rejects ETH.
contract Rejecter {}
