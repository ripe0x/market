// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {FeeConfig} from "../actions/FeeConfig.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {ReservedAction} from "../actions/ReservedAction.sol";
import {AcquireAndExecute} from "../periphery/AcquireAndExecute.sol";
import {Artwork} from "../examples/Artwork.sol";
import {TestNFT, RoyaltyNFT} from "../test/utils/Mocks.sol";

/// @title ActionsLifecycle
/// @notice A local, simulated end-to-end walk of the unified-actions protocol that prints every
/// receipt (premium, execution price, fee, royalty, refund, recovery, credits). It deploys the
/// whole system and example assets in memory and drives real parties with cheatcodes, so it
/// broadcasts nothing and never touches a chain. Run it as a plain simulation:
///
///   forge script script/ActionsLifecycle.s.sol
///
/// `rehearse.sh` runs it against a throwaway anvil to confirm it works in that environment.
contract ActionsLifecycle is Script {
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

    address seller = _actor("seller");
    address buyer = _actor("buyer");
    address bidder = _actor("bidder");
    address issuer = _actor("issuer");
    address artist = _actor("artist");
    address treasury = _actor("treasury");
    address feeAdmin = _actor("feeAdmin");
    address royaltyRx = _actor("royaltyRx");
    address payer = _actor("payer");

    uint256 salt;
    uint256 nextId = 1;

    /// Actors from private keys nobody holds. Small keys such as 1..9 are public, and on mainnet
    /// their addresses carry EIP-7702 sweeper delegations that forward any ETH they receive, which
    /// would corrupt balance checks on a fork. `run` requires every actor to have no code.
    function _actor(string memory label) internal pure returns (address) {
        return vm.addr(uint256(keccak256(abi.encodePacked("market.lifecycle.", label))));
    }

    function run() external {
        address[9] memory all = [seller, buyer, bidder, issuer, artist, treasury, feeAdmin, royaltyRx, payer];
        for (uint256 i; i < all.length; ++i) require(all[i].code.length == 0, "actor has code");
        vm.warp(1_000_000);
        market = new Market();
        actions = market.actions();
        fees = new FeeConfig(feeAdmin, treasury); // 1% fee
        exchange = new ExchangeAction(market, fees);
        covered = new CoveredNFTPurchase(market);
        reserved = new ReservedAction(market);
        acquire = new AcquireAndExecute(market, exchange, covered);
        art = new Artwork(artist);
        nft = new TestNFT();
        rnft = new RoyaltyNFT();
        rnft.setRoyalty(royaltyRx, 500); // 5%
        address[6] memory funded = [seller, buyer, bidder, issuer, payer, artist];
        for (uint256 i; i < funded.length; ++i) vm.deal(funded[i], 1_000 ether);

        console.log("== ActionsLifecycle: unified-actions walk ==");
        console.log("market", address(market));
        _sale();
        _bidWithReplenish();
        _coveredResaleAndExecute();
        _reservedArtwork();
        _acquireAndExecute();
        _cancelAndRelease();
        _expiryAndRelease();
        console.log("== done ==");
    }

    // 1) Immediate sale with a royalty collection; buyer overpays and is refunded.
    function _sale() internal {
        console.log("\n-- 1. sale (royalty collection) --");
        uint256 id = nextId++;
        rnft.mint(seller, id);
        uint256 price = 10 ether;
        Order o = _listRoyaltySale(seller, id, price);

        ExchangeAction.Quote memory q = exchange.quote(o, abi.encode(buyer, price, uint64(0)));
        uint256 sellerBefore = seller.balance;
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        o.execute{value: price + 1 ether}(abi.encode(buyer, price, uint64(0)));

        console.log("  price        ", q.price);
        console.log("  fee  -> trez ", q.fee);
        console.log("  royalty ->rx ", q.royalty);
        console.log("  proceeds->slr", q.proceeds);
        console.log("  refund ->buyr", buyerBefore - buyer.balance == price ? uint256(1 ether) : 0);
        console.log("  seller gained", seller.balance - sellerBefore);
        require(rnft.ownerOf(id) == buyer, "sale delivery");
        require(o.state() == OrderState.Completed, "sale completed");
    }

    // 2) Replenishable bid: fund, top up, and fill twice.
    function _bidWithReplenish() internal {
        console.log("\n-- 2. bid with replenish (2 executions) --");
        uint256 price = 3 ether;
        bytes memory config = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Bid,
                IERC721(address(nft)),
                _fixed(price),
                100,
                abi.encode(ExchangeAction.BidTerms(true, 0, bidder, uint64(2), uint64(0)))
            )
        );
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, 0, bidder, config);
        vm.prank(bidder);
        Order o = market.createAndActivate{value: 3 ether}(spec, bytes32(++salt));
        console.log("  funded with ", address(o).balance);
        vm.prank(bidder);
        (bool ok,) = address(o).call{value: 3 ether}(""); // replenish (anyone may top up)
        require(ok, "replenish");
        console.log("  replenished->", address(o).balance);

        for (uint256 i; i < 2; ++i) {
            uint256 tid = nextId++;
            address s = i == 0 ? seller : issuer;
            nft.mint(s, tid);
            uint256 before = s.balance;
            vm.startPrank(s);
            nft.approve(address(exchange), tid);
            o.execute(abi.encode(tid, price - price / 100, s));
            vm.stopPrank();
            console.log("  fill", i);
            console.log("    seller proceeds", s.balance - before);
        }
        console.log("  bid leftover ", address(o).balance);
        require(o.state() == OrderState.Completed, "bid completed");
    }

    // 3) Issue a covered purchase, resell its Actions token, then the new holder executes it.
    function _coveredResaleAndExecute() internal {
        console.log("\n-- 3. covered issue -> Actions resale -> execute --");
        uint256 id = nextId++;
        rnft.mint(issuer, id);
        uint256 price = 8 ether;
        Order acc = _issueCovered(issuer, address(rnft), id, price, 0);
        uint256 tokenId = uint256(uint160(address(acc)));
        console.log("  covered order", address(acc));
        console.log("  Actions token minted to issuer:", actions.ownerOf(tokenId) == issuer);

        // issuer lists the Actions token via an exchange sale
        uint256 premium = 2 ether;
        Order listing = _listActionsToken(issuer, tokenId, premium);
        ExchangeAction.Quote memory lq = exchange.quote(listing, abi.encode(buyer, premium, uint64(0)));
        vm.prank(buyer);
        listing.execute{value: premium}(abi.encode(buyer, premium, uint64(0)));
        console.log("  resale premium", lq.price);
        console.log("  resale fee    ", lq.fee);
        console.log("  resale proceed", lq.proceeds);
        require(actions.ownerOf(tokenId) == buyer, "token resold");

        // the new holder executes the covered purchase
        vm.prank(buyer);
        acc.execute{value: price}(abi.encode(buyer));
        uint256 royalty = rnft.ownerOf(id) == buyer ? _royaltyOf(id, price) : 0;
        console.log("  exec price    ", price);
        console.log("  royalty credit", acc.creditOf(royaltyRx));
        console.log("  proceeds creds", acc.creditOf(issuer));
        require(acc.creditOf(royaltyRx) == royalty, "royalty credit");
        require(acc.creditOf(issuer) == price - royalty, "proceeds credit");

        // beneficiaries withdraw their credits
        uint256 issuerBefore = issuer.balance;
        acc.releaseCredit(royaltyRx);
        vm.prank(issuer);
        acc.withdrawCredit(issuer);
        console.log("  issuer withdrew", issuer.balance - issuerBefore);
        require(address(acc).balance == 0, "covered drained");
    }

    // 4) Reserved Artwork action: reserve a change, then perform it through the order.
    function _reservedArtwork() internal {
        console.log("\n-- 4. reserved Artwork action --");
        uint256 aid = nextId++;
        vm.prank(artist);
        art.mint(issuer, aid);
        uint256 targetValue = 0.5 ether;
        uint256 price = 1.5 ether;
        bytes memory op = art.operation(aid, art.PALETTE(), type(uint256).max);
        bytes memory config = abi.encode(ReservedAction.Config(art, op, price, targetValue, issuer));
        OrderSpec memory spec = OrderSpec(address(reserved), Admission.Public, 0, issuer, config);
        bytes32 s = bytes32(++salt);
        address predicted = market.orderAddress(issuer, spec, s);
        vm.startPrank(issuer);
        art.reserve(predicted, aid, art.PALETTE(), type(uint256).max, 0, targetValue);
        Order o = market.create(spec, s);
        o.activate();
        vm.stopPrank();

        uint256 artBefore = address(art).balance;
        vm.prank(payer);
        o.execute{value: price}(abi.encode(uint8(42)));
        console.log("  exec price    ", price);
        console.log("  value->artwork", address(art).balance - artBefore);
        console.log("  proceeds creds", o.creditOf(issuer));
        require(art.colorOf(aid) == 42, "palette changed");
        require(o.creditOf(issuer) == price - targetValue, "reserved proceeds");
    }

    // 5) AcquireAndExecute: buy an Actions listing and execute its covered purchase atomically.
    function _acquireAndExecute() internal {
        console.log("\n-- 5. AcquireAndExecute (atomic buy + execute) --");
        uint256 id = nextId++;
        nft.mint(issuer, id);
        uint256 execPrice = 5 ether;
        Order acc = _issueCovered(issuer, address(nft), id, execPrice, uint64(block.timestamp + 7 days));
        uint256 tokenId = uint256(uint160(address(acc)));
        uint256 premium = 1 ether;
        Order listing = _listActionsToken(issuer, tokenId, premium);

        AcquireAndExecute.Params memory p = AcquireAndExecute.Params({
            listing: listing,
            account: acc,
            nft: IERC721(address(nft)),
            tokenId: id,
            executionPrice: execPrice,
            activationTermsHash: keccak256(acc.activationTerms()),
            maxPremium: premium,
            maxTotal: premium + execPrice,
            recipient: buyer,
            refundTo: payer,
            deadline: block.timestamp + 1 days
        });
        uint256 payerBefore = payer.balance;
        vm.prank(payer);
        acquire.acquireAndExecute{value: premium + execPrice + 1 ether}(p);
        console.log("  premium       ", premium);
        console.log("  exec price    ", execPrice);
        console.log("  refund ->payer", uint256(1 ether));
        console.log("  payer spent   ", payerBefore - payer.balance);
        require(nft.ownerOf(id) == buyer, "acquire delivery");
        require(payerBefore - payer.balance == premium + execPrice, "exact spend");
    }

    // 6) Cancel a live sale and recover the escrowed NFT through release.
    function _cancelAndRelease() internal {
        console.log("\n-- 6. cancel + release --");
        uint256 id = nextId++;
        nft.mint(seller, id);
        Order o = _listSale(seller, address(nft), id, 4 ether, 0);
        vm.prank(seller);
        o.cancel();
        vm.prank(seller);
        o.release(seller, "");
        console.log("  recovered NFT to seller:", nft.ownerOf(id) == seller);
        require(o.state() == OrderState.Canceled, "canceled");
        require(nft.ownerOf(id) == seller, "recovered");
    }

    // 7) Let a sale expire, finalize it, and recover the NFT through release.
    function _expiryAndRelease() internal {
        console.log("\n-- 7. expiry + release --");
        uint256 id = nextId++;
        nft.mint(seller, id);
        uint64 deadline = uint64(block.timestamp + 1 days);
        Order o = _listSale(seller, address(nft), id, 4 ether, deadline);
        vm.warp(block.timestamp + 2 days); // past the deadline
        o.finalizeExpiry();
        vm.prank(seller);
        o.release(seller, "");
        console.log("  recovered NFT to seller:", nft.ownerOf(id) == seller);
        require(o.state() == OrderState.Expired, "expired");
        require(nft.ownerOf(id) == seller, "recovered");
    }

    // ---- builders ----

    function _fixed(uint256 price) internal view returns (ExchangeAction.Schedule memory) {
        return ExchangeAction.Schedule(price, price, uint64(block.timestamp), uint64(block.timestamp));
    }

    function _royaltyOf(uint256 id, uint256 price) internal view returns (uint256) {
        (, uint256 amount) = rnft.royaltyInfo(id, price);
        return amount;
    }

    function _listSale(address owner, address token, uint256 id, uint256 price, uint64 deadline)
        internal
        returns (Order o)
    {
        bytes memory config = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale,
                IERC721(token),
                _fixed(price),
                100,
                abi.encode(ExchangeAction.SaleTerms(id, owner, 10_000))
            )
        );
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, deadline, owner, config);
        vm.startPrank(owner);
        o = market.create(spec, bytes32(++salt));
        IERC721(token).transferFrom(owner, address(o), id);
        o.activate();
        vm.stopPrank();
    }

    function _listRoyaltySale(address owner, uint256 id, uint256 price) internal returns (Order o) {
        return _listSale(owner, address(rnft), id, price, 0);
    }

    function _listActionsToken(address owner, uint256 tokenId, uint256 premium) internal returns (Order o) {
        bytes memory config = abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale,
                IERC721(address(actions)),
                _fixed(premium),
                100,
                abi.encode(ExchangeAction.SaleTerms(tokenId, owner, 10_000))
            )
        );
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, 0, owner, config);
        vm.startPrank(owner);
        o = market.create(spec, bytes32(++salt));
        actions.transferFrom(owner, address(o), tokenId);
        o.activate();
        vm.stopPrank();
    }

    function _issueCovered(address iss, address token, uint256 id, uint256 price, uint64 deadline)
        internal
        returns (Order o)
    {
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(IERC721(token), id, price, iss, 10_000));
        OrderSpec memory spec = OrderSpec(address(covered), Admission.Holder, deadline, iss, config);
        vm.startPrank(iss);
        o = market.create(spec, bytes32(++salt));
        IERC721(token).transferFrom(iss, address(o), id);
        o.activate();
        vm.stopPrank();
    }
}
