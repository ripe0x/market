// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../../src/Market.sol";
import {IOrderHandler, Order} from "../../src/Order.sol";
import {HandlerBase} from "../../examples/HandlerBase.sol";
import {DutchAuction} from "../../examples/DutchAuction.sol";
import {TokenExchange} from "../../examples/TokenExchange.sol";
import {PaintAction} from "../../examples/PaintAction.sol";
import {AcquisitionBid, IBidStrategy, ICapitalSource} from "../../examples/AcquisitionBid.sol";
import {RisingStrategy, CapitalShareStrategy} from "../../examples/BidStrategies.sol";
import {TestNFT} from "./Mocks.sol";

abstract contract Base is Test {
    Market market;
    DutchAuction dutch;
    TokenExchange exchange;
    PaintAction paint;
    AcquisitionBid acquisition;
    RisingStrategy rising;
    CapitalShareStrategy share;
    TestNFT nft;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");
    address royalty = makeAddr("royalty");

    uint256 salt;

    function setUp() public virtual {
        vm.warp(1_000_000);
        market = new Market();
        dutch = new DutchAuction();
        exchange = new TokenExchange();
        paint = new PaintAction();
        acquisition = new AcquisitionBid();
        rising = new RisingStrategy();
        share = new CapitalShareStrategy();
        nft = new TestNFT();
        vm.deal(buyer, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    function _create(address owner, IOrderHandler handler, bytes memory config) internal returns (Order order) {
        vm.prank(owner);
        order = market.create(handler, config, bytes32(++salt));
    }

    function _payees(address to) internal pure returns (HandlerBase.Payee[] memory p) {
        p = new HandlerBase.Payee[](1);
        p[0] = HandlerBase.Payee(to, 10_000);
    }

    function _payees(address a, uint16 aBps, address b) internal pure returns (HandlerBase.Payee[] memory p) {
        p = new HandlerBase.Payee[](2);
        p[0] = HandlerBase.Payee(a, aBps);
        p[1] = HandlerBase.Payee(b, 10_000 - aBps);
    }

    /// A sale of `id` from 10 ETH down to 1 ETH over 1,000 seconds starting now, paid to `owner`.
    function _dutchConfig(uint256 id, address payee) internal view returns (DutchAuction.Config memory) {
        return DutchAuction.Config(nft, id, 10 ether, 1 ether, block.timestamp, block.timestamp + 1000, _payees(payee));
    }

    /// Mints `id` to `owner`, creates the sale and deposits the NFT.
    function _listDutch(address owner, uint256 id) internal returns (Order order, bytes memory config) {
        nft.mint(owner, id);
        config = abi.encode(_dutchConfig(id, owner));
        order = _create(owner, dutch, config);
        vm.prank(owner);
        nft.safeTransferFrom(owner, address(order), id);
    }

    function _risingParams(uint256 start, uint256 perSecond, uint256 resetBps) internal view returns (bytes memory) {
        return abi.encode(RisingStrategy.Params(start, block.timestamp, perSecond, resetBps));
    }

    function _bidConfig(address recipient, uint256 maxPrice, IBidStrategy strategy, bytes memory params, address source)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(AcquisitionBid.Config(nft, recipient, maxPrice, strategy, params, ICapitalSource(source)));
    }

    function _sellInto(address holder, Order bid, bytes memory config, uint256 id, uint256 price)
        internal
        returns (bytes memory)
    {
        vm.startPrank(holder);
        nft.approve(address(bid), id);
        bytes memory ret = bid.fill(config, abi.encode(id, price));
        vm.stopPrank();
        return ret;
    }
}
