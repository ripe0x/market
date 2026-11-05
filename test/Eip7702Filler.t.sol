// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {Base} from "./utils/Base.sol";
import {TestToken} from "./utils/Mocks.sol";

/// Stands in for a smart wallet's batch executor, which an EOA delegates to with EIP-7702.
/// It runs calls as the EOA, all or nothing, and knows nothing about Market.
contract WalletBatch {
    receive() external payable {}

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function execute(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "only self");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// A dishonest handler: takes the filler's tokens and delivers nothing.
contract PullOnlyHandler is IOrderHandler {
    function onFill(address caller, uint256, bytes calldata config, bytes calldata) external returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(config, (address, uint256));
        Order(payable(msg.sender)).execute(token, 0, abi.encodeCall(IERC20.transferFrom, (caller, msg.sender, amount)));
        return "";
    }
}

/// A plain EOA, delegated with EIP-7702 to an ordinary wallet batch executor, approves an
/// order, fills it and checks its own receipt with `FillVerifier` in one atomic transaction,
/// without trusting the order's handler.
contract Eip7702FillerTest is Base {
    TestToken give;
    TestToken take;
    WalletBatch wallet;
    FillVerifier verifier;
    address eoa;
    uint256 eoaKey;

    function setUp() public override {
        super.setUp();
        give = new TestToken("GIVE");
        take = new TestToken("TAKE");
        wallet = new WalletBatch();
        verifier = new FillVerifier();
        (eoa, eoaKey) = makeAddrAndKey("eoa");
        take.mint(eoa, 100);
    }

    /// Pay 10 TAKE, require at least 10 GIVE more than before.
    function _buyGive(Order order, bytes memory config, bytes memory input)
        internal
        view
        returns (WalletBatch.Call[] memory calls)
    {
        bytes memory myGive = abi.encodeCall(IERC20.balanceOf, (eoa));
        calls = new WalletBatch.Call[](4);
        calls[0] = WalletBatch.Call(address(verifier), 0, abi.encodeCall(verifier.snapshot, (address(give), myGive)));
        calls[1] = WalletBatch.Call(address(take), 0, abi.encodeCall(IERC20.approve, (address(order), 10)));
        calls[2] = WalletBatch.Call(address(order), 0, abi.encodeCall(Order.fill, (config, input)));
        calls[3] = WalletBatch.Call(
            address(verifier), 0, abi.encodeCall(verifier.requireIncrease, (address(give), myGive, 10))
        );
    }

    function run(WalletBatch.Call[] memory calls) external {
        vm.signAndAttachDelegation(address(wallet), eoaKey);
        vm.prank(eoa);
        WalletBatch(payable(eoa)).execute(calls);
    }

    function test_dishonestHandlerFailsTheWalletsCheck() public {
        bytes memory config = abi.encode(address(take), uint256(10));
        Order order = _create(attacker, new PullOnlyHandler(), config);
        vm.expectRevert(abi.encodeWithSelector(FillVerifier.TooLittle.selector, 0, 10));
        this.run(_buyGive(order, config, ""));
        assertEq(take.balanceOf(eoa), 100);
        assertEq(take.allowance(eoa, address(order)), 0); // the approval was undone too
    }

    function test_honestHandlerPassesTheWalletsCheck() public {
        bytes memory config = abi.encode(
            TokenExchange.Config(IERC20(address(give)), IERC20(address(take)), 1, 1, seller, block.timestamp)
        );
        Order order = _create(seller, exchange, config);
        give.mint(address(order), 10);
        this.run(_buyGive(order, config, abi.encode(uint256(10), eoa)));
        assertEq(give.balanceOf(eoa), 10);
        assertEq(take.balanceOf(seller), 10);
    }

    /// Selling an NFT into a bid: the wallet requires the ETH it asked for, measured as its own
    /// balance change through `FillVerifier.ethBalance`.
    function test_sellerChecksEthReceived() public {
        bytes memory config = _bidConfig(seller, 5 ether, rising, _risingParams(1 ether, 0, 5000), address(0));
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        Order bid = market.create{value: 1 ether}(acquisition, config, 0);
        nft.mint(eoa, 7);

        bytes memory myEth = abi.encodeCall(verifier.ethBalance, (eoa));
        WalletBatch.Call[] memory calls = new WalletBatch.Call[](4);
        calls[0] = WalletBatch.Call(address(verifier), 0, abi.encodeCall(verifier.snapshot, (address(verifier), myEth)));
        calls[1] = WalletBatch.Call(address(nft), 0, abi.encodeCall(IERC721.approve, (address(bid), 7)));
        calls[2] = WalletBatch.Call(address(bid), 0, abi.encodeCall(Order.fill, (config, abi.encode(7, 1 ether))));
        calls[3] = WalletBatch.Call(
            address(verifier), 0, abi.encodeCall(verifier.requireIncrease, (address(verifier), myEth, 1 ether))
        );
        this.run(calls);
        assertEq(eoa.balance, 1 ether);
        assertEq(nft.ownerOf(7), seller);
    }

    /// A delegated EOA has code, but code its key can swap at any time: Market refuses it as a handler.
    function test_delegatedAccountCannotBeHandler() public {
        this.run(new WalletBatch.Call[](0));
        assertEq(eoa.code, abi.encodePacked(hex"ef0100", address(wallet)));
        vm.expectRevert(Market.DelegatedHandler.selector);
        market.create(IOrderHandler(eoa), "", 0);
    }
}
