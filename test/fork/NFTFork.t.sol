// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Market} from "../../src/Market.sol";
import {Actions} from "../../src/Actions.sol";
import {Admission, Order, OrderSpec, OrderState} from "../../src/Order.sol";
import {FeeConfig} from "../../actions/FeeConfig.sol";
import {ExchangeAction} from "../../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../../actions/CoveredNFTPurchase.sol";

/// @notice Sales, bids and covered purchases of real mainnet ERC721s on a fork pinned at `BLOCK`.
/// Token holders are the deployed ones, impersonated with `vm.prank`; every collection, royalty
/// setting and royalty receiver is read from the live contract. Settlement amounts are
/// price-proportional (fee = 1% of price, royalty = the collection's ERC2981 answer) and do not
/// depend on gas price, so they are asserted on the receiving side, never on the tx sender's
/// balance.
///
///   forge test --match-path test/fork/NFTFork.t.sol
///
/// RPC is fixed to Tenderly's public mainnet gateway, as required by the project.
contract NFTForkTest is Test {
    string constant RPC = "https://mainnet.gateway.tenderly.co";
    // Pinned ~2.8k blocks below head 26,452,802 at authoring (2026-11-19). Recent, to avoid
    // hiding live drift; holders and royalties were read at this block.
    uint256 constant BLOCK = 26_450_000;

    IERC721 constant BAYC = IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D); // no ERC2981
    IERC721 constant AZUKI = IERC721(0xED5AF388653567Af2F388E6224dC7C4b3241C544); // ERC721A, no ERC2981
    IERC721 constant OPEPEN = IERC721(0x6339e5E072086621540D0362C4e3Cea0d643E114); // ERC2981 2.5% to EOA
    IERC721 constant CHIMPERS = IERC721(0x80336Ad7A747236ef41F47ed2C7641828a480BAA); // ERC2981 5.5% to contract

    Market market;
    Actions actions;
    FeeConfig fees;
    ExchangeAction exchange;
    CoveredNFTPurchase covered;

    address buyer = makeAddr("fork buyer");
    address bidder = makeAddr("fork bidder");
    address vault = makeAddr("fork vault"); // bid delivery recipient
    address proceeds = makeAddr("fork proceeds");
    address treasury = makeAddr("fork fee recipient");
    address feeAdmin = makeAddr("fork fee admin");
    uint256 salt;

    function setUp() public {
        vm.createSelectFork(RPC, BLOCK);
        market = new Market();
        actions = market.actions();
        fees = new FeeConfig(feeAdmin, treasury); // feeBps defaults to 1% (MAX_FEE_BPS)
        exchange = new ExchangeAction(market, fees);
        covered = new CoveredNFTPurchase(market);
        vm.deal(buyer, 1000 ether);
        vm.deal(bidder, 1000 ether);
    }

    // ---- helpers ----

    function _royalty(IERC721 nft, uint256 id, uint256 price) internal view returns (address to, uint256 amount) {
        if (nft.supportsInterface(type(IERC2981).interfaceId)) {
            return IERC2981(address(nft)).royaltyInfo(id, price);
        }
    }

    function _fixed(uint256 price) internal view returns (ExchangeAction.Schedule memory) {
        return ExchangeAction.Schedule(price, price, uint64(block.timestamp), uint64(block.timestamp));
    }

    function _listSale(IERC721 nft, uint256 id, uint256 price) internal returns (Order order) {
        address holder = nft.ownerOf(id);
        bytes memory config = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale, nft, _fixed(price), 100, abi.encode(ExchangeAction.SaleTerms(id, proceeds, 10_000))
            )
        );
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, 0, holder, config);
        vm.startPrank(holder);
        order = market.create(spec, bytes32(++salt));
        nft.transferFrom(holder, address(order), id);
        order.activate();
        vm.stopPrank();
        assertEq(nft.ownerOf(id), address(order), "escrowed");
    }

    // ---- sales ----

    /// A real BAYC with no royalty, sold to the buyer. Seller gets price less the 1% fee.
    function test_sale_BAYC_noRoyalty() public {
        uint256 price = 10 ether;
        Order order = _listSale(BAYC, 1, price);
        uint256 fee = price / 100;

        vm.prank(buyer);
        order.execute{value: price}(abi.encode(buyer, price, uint64(0)));

        assertEq(BAYC.ownerOf(1), buyer, "delivered");
        assertEq(proceeds.balance, price - fee, "seller proceeds");
        assertEq(treasury.balance, fee, "fee");
        assertEq(address(order).balance, 0, "order drained");
        assertEq(uint8(order.state()), uint8(OrderState.Completed), "completed");
    }

    /// Opepen pays 2.5% ERC2981 to an EOA. Price, fee, royalty and proceeds reconcile to the wei.
    function test_sale_Opepen_royaltyToEOA() public {
        uint256 price = 10 ether;
        (address royaltyTo, uint256 royalty) = _royalty(OPEPEN, 1, price);
        assertEq(royalty, 0.25 ether, "2.5% at this block");
        assertEq(royaltyTo.code.length, 0, "royalty receiver is an EOA");

        Order order = _listSale(OPEPEN, 1, price);
        uint256 fee = price / 100;
        // The order sends the royalty directly; receivers may forward it, so check the payment.
        vm.expectCall(royaltyTo, royalty, "");

        vm.prank(buyer);
        order.execute{value: price}(abi.encode(buyer, price, uint64(0)));

        assertEq(OPEPEN.ownerOf(1), buyer, "delivered");
        assertEq(proceeds.balance, price - fee - royalty, "seller proceeds net of fee and royalty");
        assertEq(treasury.balance, fee, "fee");
        assertEq(address(order).balance, 0, "order drained");
    }

    // ---- bids ----

    function _bid(IERC721 nft, uint256 price, uint64 maxExec, uint256 funding) internal returns (Order order) {
        bytes memory config = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Bid,
                nft,
                _fixed(price),
                100,
                abi.encode(ExchangeAction.BidTerms(true, 0, vault, maxExec, 0))
            )
        );
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, 0, bidder, config);
        vm.prank(bidder);
        order = market.createAndActivate{value: funding}(spec, bytes32(++salt));
    }

    /// A collection bid on Azuki (no royalty) filled by the token's real holder; one of two
    /// executions, so the bid keeps the rest of its funding.
    function test_bid_Azuki_noRoyalty() public {
        uint256 price = 5 ether;
        Order order = _bid(AZUKI, price, 2, 11 ether);
        address holder = AZUKI.ownerOf(1);
        uint256 fee = price / 100;
        uint256 before = holder.balance;

        vm.prank(holder);
        AZUKI.approve(address(exchange), 1);
        vm.prank(holder);
        order.execute(abi.encode(uint256(1), price - fee, holder));

        assertEq(AZUKI.ownerOf(1), vault, "delivered to vault");
        assertEq(holder.balance - before, price - fee, "seller proceeds net of fee");
        assertEq(treasury.balance, fee, "fee");
        assertEq(address(order).balance, 11 ether - price, "bid keeps the remainder");
        assertEq(uint8(order.state()), uint8(OrderState.Live), "still live, one fill left");
    }

    /// Chimpers pays 5.5% ERC2981 to a contract receiver. The bid pays it as the collection
    /// reports and delivers the token.
    function test_bid_Chimpers_royaltyToContract() public {
        uint256 price = 5 ether;
        (address royaltyTo, uint256 royalty) = _royalty(CHIMPERS, 3000, price);
        assertEq(royalty, 0.275 ether, "5.5% at this block");
        assertGt(royaltyTo.code.length, 0, "royalty receiver is a contract");

        Order order = _bid(CHIMPERS, price, 1, price);
        address holder = CHIMPERS.ownerOf(3000);
        uint256 fee = price / 100;
        uint256 before = holder.balance;

        vm.prank(holder);
        CHIMPERS.approve(address(exchange), 3000);
        vm.expectCall(royaltyTo, royalty, "");
        vm.prank(holder);
        order.execute(abi.encode(uint256(3000), price - fee - royalty, holder));

        assertEq(CHIMPERS.ownerOf(3000), vault, "delivered");
        assertEq(holder.balance - before, price - fee - royalty, "seller proceeds net of fee and royalty");
        assertEq(treasury.balance, fee, "fee");
        assertEq(address(order).balance, 0, "single-execution bid fully spent");
        assertEq(uint8(order.state()), uint8(OrderState.Completed), "completed");
    }

    // ---- covered purchase ----

    /// A Holder covered purchase of a real Opepen: the holder of the Actions token buys the NFT
    /// for the fixed price; the 2.5% royalty and the proceeds are credited inside the order and
    /// withdrawn to their beneficiaries. No trading fee applies to covered purchases.
    function test_covered_Opepen_creditsRoyaltyAndProceeds() public {
        uint256 price = 8 ether;
        (address royaltyTo, uint256 royalty) = _royalty(OPEPEN, 1, price);
        assertEq(royalty, 0.2 ether, "2.5% of 8 ether");

        address holder = OPEPEN.ownerOf(1);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(OPEPEN, 1, price, proceeds, 10_000));
        OrderSpec memory spec = OrderSpec(address(covered), Admission.Holder, 0, holder, config);
        vm.startPrank(holder);
        Order order = market.create(spec, bytes32(++salt));
        OPEPEN.transferFrom(holder, address(order), 1);
        order.activate();
        vm.stopPrank();
        uint256 tokenId = uint256(uint160(address(order)));
        assertEq(actions.ownerOf(tokenId), holder, "Actions token minted to issuer");

        // The issuer transfers the purchase right to a funded buyer, who redeems it.
        vm.prank(holder);
        actions.transferFrom(holder, buyer, tokenId);
        vm.prank(buyer);
        order.execute{value: price}(abi.encode(buyer));

        assertEq(OPEPEN.ownerOf(1), buyer, "delivered to buyer");
        assertEq(order.creditOf(royaltyTo), royalty, "royalty credited");
        assertEq(order.creditOf(proceeds), price - royalty, "proceeds credited");
        assertEq(address(order).balance, price, "price held as credits");
        assertEq(uint8(order.state()), uint8(OrderState.Completed), "completed");

        uint256 royaltyBefore = royaltyTo.balance;
        order.releaseCredit(royaltyTo);
        order.releaseCredit(proceeds);
        assertEq(royaltyTo.balance - royaltyBefore, royalty, "royalty paid out");
        assertEq(proceeds.balance, price - royalty, "proceeds paid out");
        assertEq(address(order).balance, 0, "order drained after withdrawals");
    }
}
