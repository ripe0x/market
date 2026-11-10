// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";

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

/// Records what an order passes to its handler and lets the test script the fill.
contract ProbeHandler is IOrderHandler {
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

/// Runs a script taken from the fill's input. Each step is a call made either as the calling
/// order, through `execute`, or by the handler itself. Forwarding calldata from input breaks the
/// rules for handler authors on purpose: this stands in for any handler, honest or hostile, so
/// tests can check what the core allows whatever the handler does. Counts fills per order.
contract ScriptHandler is IOrderHandler {
    struct Step {
        bool asOrder;
        address target;
        uint256 value;
        bytes data;
    }

    mapping(address order => uint256) public fills;

    function onFill(address, uint256, bytes calldata, bytes calldata input) external returns (bytes memory) {
        fills[msg.sender] += 1;
        if (input.length == 0) return "";
        Step[] memory steps = abi.decode(input, (Step[]));
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            if (s.asOrder) {
                Order(payable(msg.sender)).execute(s.target, s.value, s.data);
            } else {
                (bool ok, bytes memory ret) = s.target.call{value: s.value}(s.data);
                if (!ok) {
                    assembly ("memory-safe") {
                        revert(add(ret, 0x20), mload(ret))
                    }
                }
            }
        }
        return "";
    }

    /// One step as a fill input.
    function script(bool asOrder, address target, uint256 value, bytes memory data)
        external
        pure
        returns (bytes memory)
    {
        Step[] memory steps = new Step[](1);
        steps[0] = Step(asOrder, target, value, data);
        return abi.encode(steps);
    }
}

/// A hostile handler: sends everything the order holds in ETH to its author.
contract DrainHandler is IOrderHandler {
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

/// A hostile handler that keeps a reference to its order and tries to act later.
contract StashHandler is IOrderHandler {
    Order public stashed;

    function onFill(address, uint256, bytes calldata, bytes calldata) external returns (bytes memory) {
        stashed = Order(payable(msg.sender));
        return "";
    }

    function useLater(address target, uint256 value, bytes calldata data) external {
        stashed.execute(target, value, data);
    }
}

/// A handler that tries to fill its own order again from inside the fill.
contract ReentrantHandler is IOrderHandler {
    function onFill(address, uint256, bytes calldata config, bytes calldata) external returns (bytes memory) {
        Order(payable(msg.sender)).fill(config, "");
        return "";
    }
}

/// A handler that always fails, standing in for a broken or hostile handler.
contract RevertHandler is IOrderHandler {
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

/// ERC721 with a settable ERC2981 royalty, reported through ERC165.
contract RoyaltyNFT is ERC721, ERC2981 {
    constructor() ERC721("Royalty", "RYL") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRoyalty(address receiver, uint96 bps) external {
        _setDefaultRoyalty(receiver, bps);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}

/// Reports ERC2981 but answers whatever the test scripts, or reverts.
contract ScriptedRoyaltyNFT is TestNFT {
    address public receiver;
    uint256 public amount;
    bool public broken;

    function script(address receiver_, uint256 amount_, bool broken_) external {
        (receiver, amount, broken) = (receiver_, amount_, broken_);
    }

    function royaltyInfo(uint256, uint256) external view returns (address, uint256) {
        require(!broken, "royalty broken");
        return (receiver, amount);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0x2a55205a || super.supportsInterface(id);
    }
}

/// Claims transfers succeed but moves nothing.
contract LyingNFT is TestNFT {
    function transferFrom(address, address, uint256) public pure override {}
}
