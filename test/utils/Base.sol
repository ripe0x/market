// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../../src/Market.sol";
import {Actions} from "../../src/Actions.sol";
import {Admission, Order, OrderSpec, OrderState} from "../../src/Order.sol";
import {FeeConfig} from "../../actions/FeeConfig.sol";
import {ExchangeAction} from "../../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../../actions/CoveredNFTPurchase.sol";
import {ReservedAction} from "../../actions/ReservedAction.sol";
import {AcquireAndExecute} from "../../periphery/AcquireAndExecute.sol";
import {Artwork} from "../../examples/Artwork.sol";
import {TestNFT, RoyaltyNFT} from "./Mocks.sol";

/// Deploys the full system and offers builders. Tests never mock Market, Order, Actions or the
/// action implementations; hostile parties are real contracts defined in each test file.
abstract contract Base is Test {
    Market market;
    Actions actions;
    FeeConfig fees;
    ExchangeAction exchange;
    CoveredNFTPurchase covered;
    ReservedAction reserved;
    AcquireAndExecute acquire;
    Artwork art;
    TestNFT nft;
    RoyaltyNFT rnft;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address bidder = makeAddr("bidder");
    address issuer = makeAddr("issuer");
    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address feeAdmin = makeAddr("feeAdmin");
    address artist = makeAddr("artist");

    uint256 salt;
    uint64 constant T0 = 1_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        market = new Market();
        actions = market.actions();
        fees = new FeeConfig(feeAdmin, treasury);
        exchange = new ExchangeAction(market, fees);
        covered = new CoveredNFTPurchase(market);
        reserved = new ReservedAction(market);
        acquire = new AcquireAndExecute(market, exchange, covered);
        art = new Artwork(artist);
        nft = new TestNFT();
        rnft = new RoyaltyNFT();
        address[6] memory funded = [seller, buyer, bidder, issuer, holder, attacker];
        for (uint256 i; i < funded.length; ++i) vm.deal(funded[i], 1_000 ether);
    }

    // ---- specs ----

    function _spec(address action, Admission a, uint64 deadline, address residual, bytes memory config)
        internal
        pure
        returns (OrderSpec memory)
    {
        return OrderSpec(action, a, deadline, residual, config);
    }

    function _fixed(uint256 price) internal view returns (ExchangeAction.Schedule memory) {
        return ExchangeAction.Schedule(price, price, uint64(block.timestamp), uint64(block.timestamp));
    }

    function _saleConfig(address token, uint256 id, ExchangeAction.Schedule memory s, address proceedsTo, uint16 maxRoyaltyBps)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale,
                TestNFT(token),
                s,
                100,
                abi.encode(ExchangeAction.SaleTerms(id, proceedsTo, maxRoyaltyBps))
            )
        );
    }

    function _bidConfig(
        address token,
        bool anyToken,
        uint256 id,
        ExchangeAction.Schedule memory s,
        address recipient,
        uint64 maxExecutions,
        uint64 minActionTimeLeft
    ) internal pure returns (bytes memory) {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Bid,
                TestNFT(token),
                s,
                100,
                abi.encode(ExchangeAction.BidTerms(anyToken, id, recipient, maxExecutions, minActionTimeLeft))
            )
        );
    }

    function _coveredConfig(address token, uint256 id, uint256 price, address proceedsTo, uint16 maxRoyaltyBps)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(CoveredNFTPurchase.Config(TestNFT(token), id, price, proceedsTo, maxRoyaltyBps));
    }

    // ---- creation ----

    function _create(address who, OrderSpec memory spec, uint256 value) internal returns (Order o) {
        vm.prank(who);
        o = market.create{value: value}(spec, bytes32(++salt));
    }

    function _predict(address who, OrderSpec memory spec) internal view returns (address) {
        return market.orderAddress(who, spec, bytes32(salt + 1));
    }

    function _activate(Order o) internal {
        vm.prank(o.issuer());
        o.activate();
    }

    /// Mints `id` of `nft` to `owner`, escrows it in a live fixed-price sale paying `owner`.
    function _listSale(address owner, uint256 id, uint256 price) internal returns (Order o) {
        nft.mint(owner, id);
        o = _listToken(owner, address(nft), id, _fixed(price), 0);
    }

    /// Escrows an existing token `owner` holds in a live sale.
    function _listToken(address owner, address token, uint256 id, ExchangeAction.Schedule memory s, uint64 deadline)
        internal
        returns (Order o)
    {
        OrderSpec memory spec =
            _spec(address(exchange), Admission.Public, deadline, owner, _saleConfig(token, id, s, owner, 10_000));
        o = _create(owner, spec, 0);
        vm.startPrank(owner);
        TestNFT(token).transferFrom(owner, address(o), id);
        o.activate();
        vm.stopPrank();
    }

    /// A live bid funded with `funding` for `maxExecutions` tokens of `nft` (any token).
    function _bid(uint256 price, uint64 maxExecutions, uint256 funding) internal returns (Order o) {
        OrderSpec memory spec = _spec(
            address(exchange),
            Admission.Public,
            0,
            bidder,
            _bidConfig(address(nft), true, 0, _fixed(price), bidder, maxExecutions, 0)
        );
        vm.prank(bidder);
        o = market.createAndActivate{value: funding}(spec, bytes32(++salt));
    }

    /// A live covered purchase over `id` of `token`, issued by `issuer` and held by `issuer`.
    function _issueCovered(address token, uint256 id, uint256 price, uint64 deadline) internal returns (Order o) {
        OrderSpec memory spec = _spec(
            address(covered), Admission.Holder, deadline, issuer, _coveredConfig(token, id, price, issuer, 10_000)
        );
        o = _create(issuer, spec, 0);
        vm.startPrank(issuer);
        TestNFT(token).transferFrom(issuer, address(o), id);
        o.activate();
        vm.stopPrank();
    }

    function _id(Order o) internal pure returns (uint256) {
        return uint256(uint160(address(o)));
    }
}
