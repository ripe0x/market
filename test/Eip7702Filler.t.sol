// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPolicy, Order} from "../src/Order.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {Base} from "./utils/Base.sol";
import {TestToken} from "./utils/Mocks.sol";

/// Code an EOA can delegate to with EIP-7702: run calls as itself, then require a view call to
/// return exactly the expected bytes. Only the EOA itself can call it.
contract CheckedBatch {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function run(Call[] calldata calls, address check, bytes calldata checkData, bytes calldata expected)
        external
        payable
    {
        require(msg.sender == address(this), "only self");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(ok, "call failed");
        }
        (bool success, bytes memory ret) = check.staticcall(checkData);
        require(success && keccak256(ret) == keccak256(expected), "receipt check failed");
    }
}

/// A dishonest policy: takes the filler's tokens and delivers nothing.
contract PullOnlyPolicy is IPolicy {
    function onFill(address caller, uint256, bytes calldata config, bytes calldata) external returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(config, (address, uint256));
        Order(payable(msg.sender)).execute(token, 0, abi.encodeCall(IERC20.transferFrom, (caller, msg.sender, amount)));
        return "";
    }
}

/// A plain EOA, delegated with EIP-7702, approves an order, fills it and checks its own
/// receipt in one atomic transaction, without trusting the order's policy.
contract Eip7702FillerTest is Base {
    TestToken give;
    TestToken take;
    CheckedBatch batch;
    address eoa;
    uint256 eoaKey;

    function setUp() public override {
        super.setUp();
        give = new TestToken("GIVE");
        take = new TestToken("TAKE");
        batch = new CheckedBatch();
        (eoa, eoaKey) = makeAddrAndKey("eoa");
        take.mint(eoa, 100);
    }

    function _calls(Order order, bytes memory config, bytes memory input)
        internal
        view
        returns (CheckedBatch.Call[] memory calls)
    {
        calls = new CheckedBatch.Call[](2);
        calls[0] = CheckedBatch.Call(address(take), 0, abi.encodeCall(IERC20.approve, (address(order), 10)));
        calls[1] = CheckedBatch.Call(address(order), 0, abi.encodeCall(Order.fill, (config, input)));
    }

    function _run(Order order, bytes memory config, bytes memory input) internal {
        vm.signAndAttachDelegation(address(batch), eoaKey);
        vm.prank(eoa);
        CheckedBatch(payable(eoa)).run(
            _calls(order, config, input),
            address(give),
            abi.encodeCall(IERC20.balanceOf, (eoa)),
            abi.encode(uint256(10))
        );
    }

    function test_dishonestPolicyFailsTheEoasOwnCheck() public {
        bytes memory config = abi.encode(address(take), uint256(10));
        Order order = _create(attacker, new PullOnlyPolicy(), config);
        vm.expectRevert(bytes("receipt check failed"));
        this.runExternal(order, config, "");
        assertEq(take.balanceOf(eoa), 100);
        assertEq(take.allowance(eoa, address(order)), 0); // the approval was undone too
    }

    function test_honestPolicyPassesTheEoasOwnCheck() public {
        bytes memory config = abi.encode(
            TokenExchange.Config(IERC20(address(give)), IERC20(address(take)), 1, 1, seller, block.timestamp)
        );
        Order order = _create(seller, exchange, config);
        give.mint(address(order), 10);
        this.runExternal(order, config, abi.encode(uint256(10), eoa));
        assertEq(give.balanceOf(eoa), 10);
        assertEq(take.balanceOf(seller), 10);
    }

    function runExternal(Order order, bytes memory config, bytes memory input) external {
        _run(order, config, input);
    }
}
