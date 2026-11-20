// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {Actions} from "../src/Actions.sol";
import {Admission, Order, OrderSpec, OrderState} from "../src/Order.sol";
import {FeeConfig} from "../actions/FeeConfig.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {ReservedAction} from "../actions/ReservedAction.sol";
import {Artwork} from "../examples/Artwork.sol";
import {TestNFT, RoyaltyNFT} from "./utils/Mocks.sol";

/// @title Handler
/// @notice Drives the whole Market system with valid-by-construction calls and keeps an
/// independent ghost model of every order's accounting, token existence and NFT custody. The
/// model tracks, per order, expected free balance, expected credits (to the issuer and to the
/// royalty receiver), expected state, and for Holder orders the token's current owner; globally
/// it tracks expected NFT owners and asserts exact ETH conservation across the closed account
/// set {users, fee recipient, artist, Artwork, all orders}. Every state-changing path chooses an
/// existing account in the right state so no call is expected to revert; the few intentional
/// rejections run through `probeReject` under `vm.expectRevert`. Nothing is wrapped in try/catch
/// that could swallow an unexpected error.
contract Handler is Test {
    // ---- system ----
    Market market;
    Actions actions;
    FeeConfig fees;
    ExchangeAction exchange;
    CoveredNFTPurchase covered;
    ReservedAction reserved;
    Artwork art;
    TestNFT nft;
    RoyaltyNFT rnft;

    // ---- actors (closed ETH set) ----
    address[5] public users;
    address feeAdmin = makeAddr("feeAdmin");
    address treasury = makeAddr("treasury"); // fee recipient
    address artist = makeAddr("artist");
    uint256 constant START = 10_000 ether;
    uint256 public totalDealt;
    uint16 constant ROYALTY_BPS = 500; // RoyaltyNFT default royalty, paid to users[4]

    // ---- time / ids ----
    uint256 public nowTs = 1_000_000;
    uint256 salt;
    uint256 nextId = 1; // ids for nft/rnft
    uint256 nextArt = 1;

    // ---- order states (mirror OrderState) ----
    uint8 constant S_PENDING = 0;
    uint8 constant S_LIVE = 1;
    uint8 constant S_COMPLETED = 2;
    uint8 constant S_CANCELED = 3;
    uint8 constant S_EXPIRED = 4;
    uint8 constant S_SURRENDERED = 5;

    // ---- order kinds ----
    uint8 constant K_SALE = 0;
    uint8 constant K_BID = 1;
    uint8 constant K_COVERED = 2;
    uint8 constant K_RESERVED = 3;
    uint8 constant K_LISTING = 4; // ExchangeAction sale whose NFT is the Actions collection

    struct Entry {
        Order order;
        uint8 kind;
        bool holderAdm;
        uint8 state;
        uint64 deadline;
        address issuer; // == residual == proceedsTo
        address nftAddr; // nft / rnft / actions / art
        uint256 nftId; // real id, or covered-token id for a listing, or art id for reserved
        uint16 royaltyBps; // sale: 0 or ROYALTY_BPS
        uint256 price;
        uint16 feeBps; // fee snapshot at activation (exchange orders)
        uint256 royaltyAmt; // covered snapshot
        uint64 maxExec;
        uint64 execCount;
        address recipient; // bid delivery recipient
        uint256 targetValue; // reserved
        uint256 linked; // 1-based index of the covered entry a listing escrows
        bool parked; // covered token escrowed inside a listing
        address holder; // owner of a Holder order's token while live (or the listing order)
        bool escrowed; // sale/covered/listing: the NFT/token is still in the order
        uint256 expFree; // ghost: free balance
        uint256 creditProceeds; // ghost: credit owed to issuer
        uint256 creditRoyalty; // ghost: credit owed to users[4]
    }

    Entry[] public entries;
    uint256 constant MAX_ENTRIES = 40;

    // ghost expected NFT owner, for real nft/rnft/art ids
    mapping(address => mapping(uint256 => address)) public expOwner;
    address[] trackNftAddr;
    uint256[] trackNftId;

    // ---- counters ----
    uint256 constant NACT = 21;
    uint256[NACT] public accepted;
    uint256[NACT] public skipped;
    uint256 public rejCompletedExec; // WrongState on execute of a terminal order
    uint256 public rejCancelHolder; // WrongState cancelling a live Holder order
    uint256 public rejSurplusAuth; // Unauthorized withdrawSurplus by non-residual

    // ---- reached transition bitmap (for the trace test) ----
    uint256 public reached;

    constructor() {
        vm.warp(nowTs);
        market = new Market();
        actions = market.actions();
        fees = new FeeConfig(feeAdmin, treasury);
        exchange = new ExchangeAction(market, fees);
        covered = new CoveredNFTPurchase(market);
        reserved = new ReservedAction(market);
        art = new Artwork(artist);
        nft = new TestNFT();
        rnft = new RoyaltyNFT();
        rnft.setRoyalty(makeAddr("u4"), ROYALTY_BPS); // placeholder; overwritten below
        for (uint256 i; i < 5; ++i) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            vm.deal(users[i], START);
            totalDealt += START;
        }
        rnft.setRoyalty(users[4], ROYALTY_BPS); // royalty receiver is a tracked user
    }

    // ================= helpers =================

    function entriesLength() external view returns (uint256) {
        return entries.length;
    }

    function _expired(Entry storage e) internal view returns (bool) {
        return e.deadline != 0 && nowTs >= e.deadline;
    }

    function _live(Entry storage e) internal view returns (bool) {
        return e.state == S_LIVE && !_expired(e);
    }

    function _isOrder(address a) internal view returns (bool) {
        return market.isOrder(a);
    }

    function _richest() internal view returns (address who, uint256 bal) {
        for (uint256 i; i < 5; ++i) {
            if (users[i].balance >= bal) {
                bal = users[i].balance;
                who = users[i];
            }
        }
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % 5];
    }

    /// @dev Issuers / proceeds beneficiaries are users[0..3]; users[4] is the royalty receiver
    /// only, so an order's proceeds credit and royalty credit never merge into one balance.
    function _issuer(uint256 seed) internal view returns (address) {
        return users[seed % 4];
    }

    function _start(uint256 seed) internal view returns (uint256) {
        uint256 n = entries.length;
        return n == 0 ? 0 : seed % n;
    }

    function _hit(uint8 b) internal {
        reached |= (uint256(1) << b);
    }

    function _trackNft(address a, uint256 id) internal {
        trackNftAddr.push(a);
        trackNftId.push(id);
    }

    function _tokenExists(uint256 id) internal view returns (bool, address) {
        try actions.ownerOf(id) returns (address o) {
            return (true, o);
        } catch {
            return (false, address(0));
        }
    }

    // ================= creation =================

    function createSale(uint256 seed) external {
        if (entries.length >= MAX_ENTRIES) {
            skipped[0]++;
            return;
        }
        address seller = _issuer(seed);
        bool royal = (seed >> 1) & 1 == 1;
        address col = royal ? address(rnft) : address(nft);
        uint256 id = nextId++;
        if (royal) rnft.mint(seller, id);
        else nft.mint(seller, id);
        uint64 dl = (seed >> 2) % 3 == 0 ? 0 : uint64(nowTs + _bound(seed, 1 days, 30 days));
        uint256 price = _bound(seed >> 8, 0.01 ether, 5 ether);
        bytes memory config = _saleConfig(col, id, price, seller);
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, dl, seller, config);
        bytes32 s = bytes32(++salt);
        vm.startPrank(seller);
        Order o = market.create(spec, s);
        IERC721(col).transferFrom(seller, address(o), id);
        o.activate();
        vm.stopPrank();

        Entry storage e = entries.push();
        e.order = o;
        e.kind = K_SALE;
        e.holderAdm = false;
        e.state = S_LIVE;
        e.deadline = dl;
        e.issuer = seller;
        e.nftAddr = col;
        e.nftId = id;
        e.royaltyBps = royal ? ROYALTY_BPS : 0;
        e.price = price;
        e.feeBps = fees.feeBps();
        e.escrowed = true;
        expOwner[col][id] = address(o);
        _trackNft(col, id);
        accepted[0]++;
        _hit(0);
    }

    function createBid(uint256 seed) external {
        if (entries.length >= MAX_ENTRIES) {
            skipped[1]++;
            return;
        }
        address bidder = _issuer(seed);
        uint64 maxExec = uint64(_bound(seed >> 1, 1, 3));
        uint256 price = _bound(seed >> 4, 0.01 ether, 2 ether);
        address recipient = _user(seed >> 9);
        uint256 want = price * maxExec + _bound(seed >> 12, 0, 1 ether);
        uint256 funding = want > bidder.balance ? bidder.balance : want;
        uint64 dl = (seed >> 20) & 1 == 1 ? uint64(nowTs + _bound(seed, 1 days, 30 days)) : 0;
        bytes memory config = _bidConfig(price, recipient, maxExec);
        OrderSpec memory spec = OrderSpec(address(exchange), Admission.Public, dl, bidder, config);
        vm.prank(bidder);
        Order o = market.createAndActivate{value: funding}(spec, bytes32(++salt));

        Entry storage e = entries.push();
        e.order = o;
        e.kind = K_BID;
        e.state = S_LIVE;
        e.deadline = dl;
        e.issuer = bidder;
        e.nftAddr = address(nft);
        e.price = price;
        e.feeBps = fees.feeBps();
        e.maxExec = maxExec;
        e.recipient = recipient;
        e.expFree = funding;
        accepted[1]++;
        _hit(1);
    }

    function createCovered(uint256 seed) external {
        if (entries.length >= MAX_ENTRIES) {
            skipped[2]++;
            return;
        }
        address iss = _issuer(seed);
        bool royal = (seed >> 1) & 1 == 1;
        address col = royal ? address(rnft) : address(nft);
        uint256 id = nextId++;
        if (royal) rnft.mint(iss, id);
        else nft.mint(iss, id);
        uint256 price = _bound(seed >> 8, 0.01 ether, 5 ether);
        uint64 dl = (seed >> 2) % 3 == 0 ? 0 : uint64(nowTs + _bound(seed, 1 days, 30 days));
        bool activateNow = (seed >> 5) % 4 != 0;
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(TestNFT(col), id, price, iss, 10_000));
        OrderSpec memory spec = OrderSpec(address(covered), Admission.Holder, dl, iss, config);
        bytes32 s = bytes32(++salt);
        vm.startPrank(iss);
        Order o = market.create(spec, s);
        IERC721(col).transferFrom(iss, address(o), id);
        if (activateNow) o.activate();
        vm.stopPrank();

        Entry storage e = entries.push();
        e.order = o;
        e.kind = K_COVERED;
        e.holderAdm = true;
        e.state = activateNow ? S_LIVE : S_PENDING;
        e.deadline = dl;
        e.issuer = iss;
        e.nftAddr = col;
        e.nftId = id;
        e.price = price;
        e.royaltyBps = royal ? ROYALTY_BPS : 0;
        e.royaltyAmt = royal ? price * ROYALTY_BPS / 10_000 : 0;
        e.escrowed = true;
        if (activateNow) e.holder = iss;
        expOwner[col][id] = address(o);
        _trackNft(col, id);
        accepted[2]++;
        _hit(activateNow ? 2 : 3);
    }

    function createReserved(uint256 seed) external {
        if (entries.length >= MAX_ENTRIES) {
            skipped[3]++;
            return;
        }
        address iss = _issuer(seed);
        uint256 aid = nextArt++;
        vm.prank(artist);
        art.mint(iss, aid);
        uint8 kind = uint8((seed >> 1) & 1);
        uint256 allowed = type(uint256).max;
        uint256 tv = _bound(seed >> 8, 0, 1 ether);
        uint256 price = tv + _bound(seed >> 16, 0, 2 ether);
        bytes memory op = art.operation(aid, kind, allowed);
        bytes memory config = abi.encode(ReservedAction.Config(art, op, price, tv, iss));
        OrderSpec memory spec = OrderSpec(address(reserved), Admission.Public, 0, iss, config);
        bytes32 s = bytes32(++salt);
        address predicted = market.orderAddress(iss, spec, s);
        vm.startPrank(iss);
        art.reserve(predicted, aid, kind, allowed, 0, tv);
        Order o = market.create(spec, s);
        o.activate();
        vm.stopPrank();
        require(address(o) == predicted, "predict");

        Entry storage e = entries.push();
        e.order = o;
        e.kind = K_RESERVED;
        e.state = S_LIVE;
        e.issuer = iss;
        e.nftAddr = address(art);
        e.nftId = aid;
        e.price = price;
        e.targetValue = tv;
        expOwner[address(art)][aid] = iss;
        _trackNft(address(art), aid);
        accepted[3]++;
        _hit(4);
    }

    function createListing(uint256 seed) external {
        if (entries.length + 2 > MAX_ENTRIES) {
            skipped[4]++;
            return;
        }
        address iss = _issuer(seed);
        uint256 id = nextId++;
        nft.mint(iss, id);
        uint256 price = _bound(seed >> 8, 0.01 ether, 5 ether);
        bytes memory cConfig = abi.encode(CoveredNFTPurchase.Config(nft, id, price, iss, 10_000));
        OrderSpec memory cSpec = OrderSpec(address(covered), Admission.Holder, 0, iss, cConfig);
        bytes32 cs = bytes32(++salt);
        vm.startPrank(iss);
        Order c = market.create(cSpec, cs);
        nft.transferFrom(iss, address(c), id);
        c.activate();
        vm.stopPrank();
        uint256 cTokenId = uint256(uint160(address(c)));

        uint256 premium = _bound(seed >> 20, 0.01 ether, 3 ether);
        bytes memory lConfig = _saleConfig(address(actions), cTokenId, premium, iss);
        OrderSpec memory lSpec = OrderSpec(address(exchange), Admission.Public, 0, iss, lConfig);
        bytes32 ls = bytes32(++salt);
        vm.startPrank(iss);
        Order l = market.create(lSpec, ls);
        actions.transferFrom(iss, address(l), cTokenId);
        l.activate();
        vm.stopPrank();

        // covered entry (parked)
        Entry storage ce = entries.push();
        ce.order = c;
        ce.kind = K_COVERED;
        ce.holderAdm = true;
        ce.state = S_LIVE;
        ce.issuer = iss;
        ce.nftAddr = address(nft);
        ce.nftId = id;
        ce.price = price;
        ce.escrowed = true;
        ce.parked = true;
        ce.holder = address(l);
        expOwner[address(nft)][id] = address(c);
        _trackNft(address(nft), id);
        uint256 coveredIdx = entries.length - 1;

        // listing entry
        Entry storage le = entries.push();
        le.order = l;
        le.kind = K_LISTING;
        le.state = S_LIVE;
        le.issuer = iss;
        le.nftAddr = address(actions);
        le.nftId = cTokenId;
        le.price = premium;
        le.feeBps = fees.feeBps();
        le.escrowed = true;
        le.linked = coveredIdx + 1;
        accepted[4]++;
        _hit(5);
    }

    // ================= execution / trading =================

    function buySale(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if ((e.kind != K_SALE && e.kind != K_LISTING) || !_live(e) || !e.escrowed) continue;
            (address buyer, uint256 bal) = _richest();
            if (bal < e.price) {
                skipped[5]++;
                return;
            }
            uint256 fee = e.price * e.feeBps / 10_000;
            uint256 royalty;
            if (e.royaltyBps != 0) {
                royalty = e.price * e.royaltyBps / 10_000;
                if (royalty > e.price - fee) royalty = e.price - fee;
            }
            uint256 extra = _bound(seed >> 8, 0, 0.5 ether);
            uint256 value = bal >= e.price + extra ? e.price + extra : e.price;
            address recipient = _user(seed >> 16);
            vm.prank(buyer);
            e.order.execute{value: value}(abi.encode(recipient, e.price, uint64(0)));

            if (e.kind == K_LISTING) {
                Entry storage ce = entries[e.linked - 1];
                ce.parked = false;
                ce.holder = recipient;
                _hit(7);
            } else {
                expOwner[e.nftAddr][e.nftId] = recipient;
                _hit(6);
            }
            e.escrowed = false;
            e.state = S_COMPLETED;
            accepted[5]++;
            return;
        }
        skipped[5]++;
    }

    function sellIntoBid(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_BID || !_live(e) || e.execCount >= e.maxExec || e.expFree < e.price) continue;
            address seller = _user(seed);
            uint256 tid = nextId++;
            nft.mint(seller, tid);
            expOwner[address(nft)][tid] = seller;
            _trackNft(address(nft), tid);
            address proceedsTo = _user(seed >> 8);
            vm.startPrank(seller);
            nft.approve(address(exchange), tid);
            e.order.execute(abi.encode(tid, uint256(0), proceedsTo));
            vm.stopPrank();

            uint256 fee = e.price * e.feeBps / 10_000;
            e.expFree -= e.price; // pays fee + proceeds out of free balance
            fee; // (fee -> treasury, proceeds -> proceedsTo; both tracked users)
            e.execCount += 1;
            expOwner[address(nft)][tid] = e.recipient;
            if (e.execCount >= e.maxExec) {
                e.state = S_COMPLETED;
                _hit(9);
            } else {
                _hit(8);
            }
            accepted[6]++;
            return;
        }
        skipped[6]++;
    }

    function replenishBid(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_BID || e.state != S_LIVE) continue;
            (address funder, uint256 bal) = _richest();
            if (bal < 0.01 ether) {
                skipped[7]++;
                return;
            }
            uint256 amt = _bound(seed >> 8, 0.01 ether, bal < 2 ether ? bal : 2 ether);
            vm.prank(funder);
            (bool ok,) = address(e.order).call{value: amt}("");
            require(ok, "replenish");
            e.expFree += amt;
            accepted[7]++;
            _hit(10);
            return;
        }
        skipped[7]++;
    }

    function executeCovered(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_COVERED || e.parked || !_live(e) || !e.escrowed) continue;
            address h = e.holder; // a user
            if (h.balance < e.price) {
                skipped[8]++;
                return;
            }
            address recipient = _user(seed >> 8);
            vm.prank(h);
            e.order.execute{value: e.price}(abi.encode(recipient));

            expOwner[e.nftAddr][e.nftId] = recipient;
            e.escrowed = false;
            if (e.royaltyAmt != 0) e.creditRoyalty += e.royaltyAmt;
            if (e.price > e.royaltyAmt) e.creditProceeds += e.price - e.royaltyAmt;
            e.state = S_COMPLETED;
            e.holder = address(0);
            accepted[8]++;
            _hit(11);
            return;
        }
        skipped[8]++;
    }

    function executeReserved(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_RESERVED || e.state != S_LIVE) continue;
            (address actor, uint256 bal) = _richest();
            if (bal < e.price) {
                skipped[9]++;
                return;
            }
            uint8 choice = uint8(_bound(seed >> 8, 0, 255));
            vm.prank(actor);
            e.order.execute{value: e.price}(abi.encode(choice));

            if (e.price > e.targetValue) e.creditProceeds += e.price - e.targetValue;
            e.state = S_COMPLETED;
            accepted[9]++;
            _hit(12);
            return;
        }
        skipped[9]++;
    }

    function transferToken(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_COVERED || e.parked || !_live(e) || e.holder == address(0)) continue;
            address from = e.holder;
            address to = _user(seed >> 8);
            if (to == from) to = users[(seed >> 8) % 5 == 4 ? 0 : (seed >> 8) % 5 + 1];
            uint256 tid = uint256(uint160(address(e.order)));
            vm.prank(from);
            actions.transferFrom(from, to, tid);
            e.holder = to;
            accepted[10]++;
            _hit(13);
            return;
        }
        skipped[10]++;
    }

    // ================= lifecycle endings =================

    function cancelOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            bool pend = e.state == S_PENDING && !_expired(e);
            bool livePublic = e.state == S_LIVE && !e.holderAdm && !_expired(e);
            if (!pend && !livePublic) continue;
            vm.prank(e.issuer);
            e.order.cancel();
            e.state = S_CANCELED;
            accepted[11]++;
            _hit(pend ? 14 : 15);
            return;
        }
        skipped[11]++;
    }

    function surrenderOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.kind != K_COVERED || e.parked || !_live(e) || e.holder == address(0)) continue;
            vm.prank(e.holder);
            e.order.surrender();
            e.state = S_SURRENDERED;
            e.holder = address(0);
            accepted[12]++;
            _hit(16);
            return;
        }
        skipped[12]++;
    }

    function finalizeExpiryOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.deadline == 0 || nowTs < e.deadline) continue;
            if (e.state != S_PENDING && e.state != S_LIVE) continue;
            bool holderLive = e.state == S_LIVE && e.holderAdm;
            vm.prank(users[0]);
            e.order.finalizeExpiry();
            e.state = S_EXPIRED;
            if (holderLive) {
                e.holder = address(0);
                _hit(17);
            } else {
                _hit(18);
            }
            accepted[13]++;
            return;
        }
        skipped[13]++;
    }

    function releaseOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            bool terminalOrPending = e.state == S_PENDING || e.state == S_CANCELED || e.state == S_EXPIRED
                || e.state == S_SURRENDERED;
            if (!terminalOrPending) continue;
            address recipient = _user(seed >> 8);
            if (e.kind == K_RESERVED) {
                vm.prank(e.issuer);
                e.order.release(recipient, "");
                accepted[14]++;
                _hit(20);
                return;
            }
            if (!e.escrowed) continue; // sale/covered/listing need the asset still inside
            if (e.kind == K_LISTING) {
                vm.prank(e.issuer);
                e.order.release(recipient, "");
                Entry storage ce = entries[e.linked - 1];
                ce.parked = false;
                ce.holder = recipient;
                e.escrowed = false;
                accepted[14]++;
                _hit(21);
                return;
            }
            // sale or covered: NFT returns to recipient
            vm.prank(e.issuer);
            e.order.release(recipient, "");
            expOwner[e.nftAddr][e.nftId] = recipient;
            e.escrowed = false;
            accepted[14]++;
            _hit(19);
            return;
        }
        skipped[14]++;
    }

    function withdrawSurplusOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.state == S_LIVE || e.expFree == 0) continue;
            uint256 amt = _bound(seed >> 8, 0, e.expFree);
            address recipient = _user(seed >> 16);
            vm.prank(e.issuer);
            e.order.withdrawSurplus(recipient, amt);
            e.expFree -= amt;
            accepted[15]++;
            _hit(22);
            return;
        }
        skipped[15]++;
    }

    function releaseCreditOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            if (e.creditProceeds == 0) continue;
            vm.prank(users[0]);
            e.order.releaseCredit(e.issuer); // pays issuer to itself
            e.creditProceeds = 0;
            accepted[16]++;
            _hit(23);
            return;
        }
        skipped[16]++;
    }

    function withdrawCreditOrder(uint256 seed) external {
        uint256 n = entries.length;
        uint256 st = _start(seed);
        for (uint256 k; k < n; ++k) {
            Entry storage e = entries[(st + k) % n];
            address recipient = _user(seed >> 8);
            if (e.creditRoyalty != 0) {
                vm.prank(users[4]);
                e.order.withdrawCredit(recipient);
                e.creditRoyalty = 0;
                accepted[17]++;
                _hit(24);
                return;
            }
            if (e.creditProceeds != 0) {
                vm.prank(e.issuer);
                e.order.withdrawCredit(recipient);
                e.creditProceeds = 0;
                accepted[17]++;
                _hit(24);
                return;
            }
        }
        skipped[17]++;
    }

    function setFee(uint256 seed) external {
        uint16 bps = uint16(_bound(seed, 0, 100));
        vm.prank(feeAdmin);
        fees.setFee(bps);
        accepted[18]++;
        _hit(25);
    }

    function warpTime(uint256 seed) external {
        nowTs += _bound(seed, 1 hours, 5 days);
        vm.warp(nowTs);
        accepted[19]++;
        _hit(26);
    }

    /// @notice Deterministic time jump used only by the trace test to carry orders past their
    /// deadlines; excluded from the invariant campaign's target selectors.
    function forceWarp(uint256 secs) external {
        nowTs += secs;
        vm.warp(nowTs);
    }

    /// @notice Intentional invalid calls, each asserted to revert with its exact selector.
    function probeReject(uint256 seed) external {
        uint256 n = entries.length;
        if (n == 0) {
            skipped[20]++;
            return;
        }
        uint256 st = _start(seed);
        uint256 variant = seed % 3;
        if (variant == 0) {
            for (uint256 k; k < n; ++k) {
                Entry storage e = entries[(st + k) % n];
                if (e.state == S_LIVE || e.state == S_PENDING) continue; // need a terminal order
                vm.prank(users[0]);
                vm.expectRevert(Order.WrongState.selector);
                e.order.execute("");
                accepted[20]++; rejCompletedExec++;
                _hit(27);
                return;
            }
        } else if (variant == 1) {
            for (uint256 k; k < n; ++k) {
                Entry storage e = entries[(st + k) % n];
                if (!(e.kind == K_COVERED && _live(e))) continue; // live Holder order
                vm.prank(e.issuer);
                vm.expectRevert(Order.WrongState.selector);
                e.order.cancel();
                accepted[20]++; rejCancelHolder++;
                _hit(27);
                return;
            }
        } else {
            Entry storage e = entries[st];
            address notResidual = e.issuer == users[0] ? users[1] : users[0];
            vm.prank(notResidual);
            vm.expectRevert(Order.Unauthorized.selector);
            e.order.withdrawSurplus(notResidual, 0);
            accepted[20]++; rejSurplusAuth++;
            _hit(27);
            return;
        }
        skipped[20]++;
    }

    // ================= config builders =================

    function _saleConfig(address col, uint256 id, uint256 price, address proceedsTo)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Sale,
                IERC721(col),
                ExchangeAction.Schedule(price, price, uint64(nowTs), uint64(nowTs)),
                100,
                abi.encode(ExchangeAction.SaleTerms(id, proceedsTo, 10_000))
            )
        );
    }

    function _bidConfig(uint256 price, address recipient, uint64 maxExec) internal view returns (bytes memory) {
        return abi.encode(
            ExchangeAction.Config(
                ExchangeAction.Side.Bid,
                IERC721(address(nft)),
                ExchangeAction.Schedule(price, price, uint64(nowTs), uint64(nowTs)),
                100,
                abi.encode(ExchangeAction.BidTerms(true, 0, recipient, maxExec, 0))
            )
        );
    }

    // ================= invariant checks =================

    function check() external {
        uint256 ethSum;
        for (uint256 i; i < 5; ++i) ethSum += users[i].balance;
        ethSum += treasury.balance + artist.balance + address(art).balance;

        for (uint256 i; i < entries.length; ++i) {
            Entry storage e = entries[i];
            Order o = e.order;
            ethSum += address(o).balance;

            // state mirror
            assertEq(uint8(o.state()), e.state, "state");

            // accounting: balance == credits + free; totalCredits == model; per-beneficiary credits
            uint256 tc = e.creditProceeds + e.creditRoyalty;
            assertEq(o.totalCredits(), tc, "totalCredits");
            assertEq(address(o).balance, tc + e.expFree, "balance==credits+free");
            assertEq(o.creditOf(e.issuer), e.creditProceeds, "creditProceeds");
            if (e.royaltyBps != 0 || e.creditRoyalty != 0) {
                assertEq(o.creditOf(users[4]), e.creditRoyalty, "creditRoyalty");
            }
            // free balance never negative
            assertGe(address(o).balance, o.totalCredits(), "free>=0");

            // Holder token existence / custody
            if (e.kind == K_COVERED) {
                (bool exists, address owner) = _tokenExists(uint256(uint160(address(o))));
                if (e.state == S_LIVE) {
                    assertTrue(exists, "token should exist");
                    assertEq(owner, e.holder, "token owner");
                    assertTrue(owner != address(o), "token not self-owned");
                } else {
                    assertTrue(!exists, "token should be burned");
                }
            }

            // bid executions bound
            if (e.kind == K_BID) {
                assertLe(e.execCount, e.maxExec, "execCount<=maxExec");
                if (e.state == S_COMPLETED) assertEq(e.execCount, e.maxExec, "complete==max");
            }
        }

        assertEq(ethSum, totalDealt, "eth conservation");

        // NFT custody for every real nft/rnft/art id
        for (uint256 j; j < trackNftId.length; ++j) {
            address col = trackNftAddr[j];
            uint256 id = trackNftId[j];
            assertEq(IERC721(col).ownerOf(id), expOwner[col][id], "nft owner");
        }
    }

    function summary() external view {
        string[NACT] memory names = [
            "createSale",
            "createBid",
            "createCovered",
            "createReserved",
            "createListing",
            "buySale",
            "sellIntoBid",
            "replenishBid",
            "executeCovered",
            "executeReserved",
            "transferToken",
            "cancelOrder",
            "surrenderOrder",
            "finalizeExpiry",
            "releaseOrder",
            "withdrawSurplus",
            "releaseCredit",
            "withdrawCredit",
            "setFee",
            "warpTime",
            "probeReject"
        ];
        console.log("=== Market invariant handler summary ===");
        console.log("entries created:", entries.length);
        console.log("action                 accepted   skipped");
        for (uint256 i; i < NACT; ++i) {
            console.log(string.concat(_pad(names[i]), _padNum(accepted[i]), "   ", vm.toString(skipped[i])));
        }
        console.log("expected rejections (execTerminal / cancelHolder / surplusAuth):");
        console.log(rejCompletedExec, rejCancelHolder, rejSurplusAuth);
        console.log("reached transition bitmap:", reached);
    }

    function _pad(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= 22) return s;
        bytes memory out = new bytes(22);
        for (uint256 i; i < 22; ++i) out[i] = i < b.length ? b[i] : bytes1(" ");
        return string(out);
    }

    function _padNum(uint256 v) internal pure returns (string memory) {
        return string.concat(vm.toString(v), "         ");
    }
}

/// @notice Wires the handler as the only invariant target and asserts the full ghost model after
/// every call. Run the heavy campaign with `FOUNDRY_PROFILE=invariant`.
contract InvariantTest is StdInvariant, Test {
    Handler handler;

    function setUp() public {
        handler = new Handler();
        bytes4[] memory sel = new bytes4[](21);
        sel[0] = handler.createSale.selector;
        sel[1] = handler.createBid.selector;
        sel[2] = handler.createCovered.selector;
        sel[3] = handler.createReserved.selector;
        sel[4] = handler.createListing.selector;
        sel[5] = handler.buySale.selector;
        sel[6] = handler.sellIntoBid.selector;
        sel[7] = handler.replenishBid.selector;
        sel[8] = handler.executeCovered.selector;
        sel[9] = handler.executeReserved.selector;
        sel[10] = handler.transferToken.selector;
        sel[11] = handler.cancelOrder.selector;
        sel[12] = handler.surrenderOrder.selector;
        sel[13] = handler.finalizeExpiryOrder.selector;
        sel[14] = handler.releaseOrder.selector;
        sel[15] = handler.withdrawSurplusOrder.selector;
        sel[16] = handler.releaseCreditOrder.selector;
        sel[17] = handler.withdrawCreditOrder.selector;
        sel[18] = handler.setFee.selector;
        sel[19] = handler.warpTime.selector;
        sel[20] = handler.probeReject.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice The whole ghost model holds after every handler call.
    function invariant_model() public {
        handler.check();
    }

    function afterInvariant() public {
        handler.summary();
    }
}

/// @notice A fixed sequence proving the handler is active and reaches every transition type. It
/// loops all actions with varied seeds until the reached-bitmap is full, then asserts the model.
contract InvariantTraceTest is Test {
    Handler handler;
    uint256 constant ALL = (uint256(1) << 28) - 1;

    function setUp() public {
        handler = new Handler();
    }

    function test_trace_reachesEveryTransition() public {
        // Deterministic preamble: force the transitions that a fully-random loop starves because
        // every deadlined order is consumed before it can expire. Seed 100 gives createCovered an
        // activated order with a deadline, and createSale a deadline.
        handler.createSale(100); // entry 0: live public sale with a deadline
        handler.createCovered(100); // entry 1: live Holder covered with a deadline, held by issuer
        handler.createReserved(7); // entry 2: live public reserved
        handler.forceWarp(31 days); // past both deadlines (<= 30 days)
        handler.finalizeExpiryOrder(0); // entry 0 expires -> bit 18 (pending/public)
        handler.finalizeExpiryOrder(1); // entry 1 expires, Holder token burned -> bit 17
        handler.cancelOrder(2); // cancel the reserved order (still live, deadline 0)
        handler.releaseOrder(2); // release the reserved order's reservation -> bit 20
        handler.createListing(5); // entries 3 (parked covered) + 4 (listing sale)
        handler.cancelOrder(4); // cancel the listing (entry 4, live public)
        handler.releaseOrder(4); // release the escrowed Actions token from the listing -> bit 21
        handler.check();

        uint256 i;
        for (; i < 400 && handler.reached() != ALL; ++i) {
            uint256 s = uint256(keccak256(abi.encode(i)));
            handler.createSale(s);
            handler.createBid(s >> 2);
            handler.createCovered(s >> 4);
            handler.createReserved(s >> 6);
            handler.createListing(s >> 8);
            handler.buySale(s >> 10);
            handler.sellIntoBid(s >> 12);
            handler.replenishBid(s >> 14);
            handler.transferToken(s >> 16);
            handler.executeCovered(s >> 18);
            handler.executeReserved(s >> 20);
            handler.warpTime(s >> 22);
            handler.finalizeExpiryOrder(s >> 24);
            handler.cancelOrder(s >> 26);
            handler.surrenderOrder(s >> 28);
            handler.releaseOrder(s >> 30);
            handler.withdrawSurplusOrder(s >> 32);
            handler.releaseCreditOrder(s >> 34);
            handler.withdrawCreditOrder(s >> 36);
            handler.setFee(s >> 38);
            handler.probeReject(s >> 40);
            if (i % 100 == 0) handler.check(); // model holds through the sequence
        }
        handler.check();
        handler.summary();
        console.log("trace iterations:", i);
        uint256 r = handler.reached();
        for (uint8 b; b < 28; ++b) {
            if (r & (uint256(1) << b) == 0) console.log("MISSING bit", b);
        }
        assertEq(r, ALL, "not every transition reached");
    }
}
