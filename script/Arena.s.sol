// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Market} from "../src/Market.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {NFTTrade} from "../handlers/NFTTrade.sol";
import {Addresses} from "./Deploy.s.sol";

/// A test collection only its owner can mint, paying a 5% ERC2981 royalty to `royaltyTo`.
contract ArenaNFT is ERC721, ERC2981 {
    address public immutable owner;

    constructor(address owner_, address royaltyTo) ERC721("Market Arena", "ARENA") {
        owner = owner_;
        _setDefaultRoyalty(royaltyTo, 500);
    }

    function mint(address to, uint256 id) external {
        require(msg.sender == owner, "owner");
        _mint(to, id);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}

/// One participant: its own address, ETH and NFTs, driven by `boss`. `attempt` records a call
/// that is expected to fail instead of reverting the transaction.
contract Party {
    address public immutable boss;

    event Attempted(address indexed target, bytes4 indexed selector, bool succeeded, bytes result);

    constructor(address boss_) {
        boss = boss_;
    }

    function act(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        require(msg.sender == boss, "boss");
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function attempt(address target, uint256 value, bytes calldata data) external returns (bool ok) {
        require(msg.sender == boss, "boss");
        bytes memory ret;
        (ok, ret) = target.call{value: value}(data);
        emit Attempted(target, bytes4(data), ok, ret);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// An independent matcher: buys from a sale and sells into a bid in one transaction, keeps
/// nothing, returns everything to its caller, and requires at least `minProfit`.
contract ArenaMatcher {
    function matchSaleToBid(
        Order saleOrder,
        bytes calldata saleConfig,
        uint256 maxPrice,
        Order bidOrder,
        bytes calldata bidConfig,
        IERC721 nft,
        uint256 id,
        uint256 minProceeds,
        uint256 minProfit
    ) external payable {
        saleOrder.fill{value: msg.value}(saleConfig, abi.encode(address(this), maxPrice));
        nft.approve(address(bidOrder.handler()), id);
        bidOrder.fill(bidConfig, abi.encode(id, minProceeds, address(this)));
        uint256 out = address(this).balance;
        require(out >= msg.value + minProfit, "unprofitable");
        (bool ok,) = msg.sender.call{value: out}("");
        require(ok, "send");
    }

    receive() external payable {}
}

/// Shaped like an order: forwards token calls, silently drops ETH payments and `close`.
contract CounterfeitOrder {
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        if (value != 0 || data.length == 0 || bytes4(data) == Order.close.selector) return "";
        (, ret) = target.call(data);
    }

    function announce(NFTSale handler, bytes calldata config) external {
        handler.onFill(msg.sender, 1000 ether, config, abi.encode(msg.sender, 1000 ether));
    }
}

/// A hostile handler: during its own order's fill, tries to empty the order named in config.
contract DrainHandler is IOrderHandler {
    function onFill(address caller, uint256, bytes calldata config, bytes calldata) external returns (bytes memory) {
        address victim = abi.decode(config, (address));
        Order(payable(victim)).execute(caller, victim.balance, "");
        return "";
    }
}

/// Multi-step attacks the adversary triggers with one call each.
contract Tricks {
    /// A clone of the real implementation, deployed without Market, owned by this contract and
    /// bound to `bids` with the live bid's config: closed, then made to call the handler as if
    /// filling for `holder`.
    function closedRogueClone(Market market, NFTBid bids, bytes calldata bidConfig, address holder, uint256 id) external {
        Order clone = _clone(market, bids, bidConfig);
        clone.close();
        clone.execute(
            address(bids),
            0,
            abi.encodeCall(IOrderHandler.onFill, (holder, 0, bidConfig, abi.encode(id, uint256(0), address(this))))
        );
    }

    /// The same clone, funded and filled for the holder's token.
    function fundedRogueClone(Market market, NFTBid bids, bytes calldata bidConfig, uint256 id) external payable {
        Order clone = _clone(market, bids, bidConfig);
        (bool ok,) = address(clone).call{value: msg.value}("");
        require(ok, "fund");
        clone.fill(bidConfig, abi.encode(id, uint256(0), address(this)));
    }

    /// An order of our own on a hostile handler that tries to empty `victim` during its fill.
    function hostileHandler(Market market, DrainHandler drain, address victim) external {
        bytes memory config = abi.encode(victim);
        market.create(drain, config, keccak256(abi.encode(block.number, gasleft()))).fill(config, "");
    }

    function _clone(Market market, NFTBid bids, bytes calldata bidConfig) internal returns (Order) {
        bytes memory args = abi.encodePacked(address(this), address(bids), address(bids).codehash, keccak256(bidConfig));
        return Order(payable(Clones.cloneWithImmutableArgs(market.implementation(), args)));
    }

    receive() external payable {}
}

/// Runs a list of attacks from its own address. Each attack is one call in its own frame;
/// failures are expected and recorded, and `successes` must stay 0.
contract Adversary {
    struct Attack {
        string name;
        address target;
        uint256 value;
        bytes data;
    }

    address public immutable boss;
    uint256 public attempts;
    uint256 public successes;

    event Attempt(string name, bool succeeded, bytes result);

    constructor(address boss_) {
        boss = boss_;
    }

    function run(Attack[] calldata attacks) external {
        require(msg.sender == boss, "boss");
        for (uint256 i; i < attacks.length; ++i) {
            (bool ok, bytes memory ret) = attacks[i].target.call{value: attacks[i].value}(attacks[i].data);
            attempts += 1;
            if (ok) successes += 1;
            emit Attempt(attacks[i].name, ok, ret);
        }
    }

    function withdraw() external {
        require(msg.sender == boss, "boss");
        (bool ok,) = boss.call{value: address(this).balance}("");
        require(ok, "send");
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice An adversarial exercise of the deployed release with separate participants: a seller
/// lists a falling NFTSale, a bidder funds a rising NFTBid, a holder approves the handler, an
/// adversary attacks all of it, an independent matcher settles the sale into the bid once the
/// prices cross, the holder sells into the same bid, and the bidder, once its bid is closed,
/// tries to misuse the holder's approval. Every participant is a contract driven by the sender;
/// all ETH returns to the sender at the end except gas.
///
/// Run in order, with the same `id` and the `start` that `setup` prints:
///   setup(id)            19 transactions; sends 0.012 + 0.01 ETH to participants
///   attack(id, start)    1 transaction; 15 attacks, all must fail
///   settle(id, start)    2 transactions; only after the prices cross, about 19 minutes after start
///   cleanup(id, start)   owner misuse attempts, bid recovery and sweep of every participant
contract Arena is Addresses {
    uint256 constant DURATION = 1800;
    /// The fixed-price sale filled and closed by the lifecycle run on Sepolia (DEPLOYMENT.md).
    address constant CLOSED_ORDER = 0xEB454891C38a45DD08379c41fe1e16AA3D82ba04;

    struct Cast {
        Party seller;
        Party bidder;
        Party holder;
        Party artist;
        ArenaNFT nft;
        ArenaMatcher matcher;
        Adversary adversary;
        Tricks tricks;
        CounterfeitOrder counterfeit;
        DrainHandler drain;
    }

    function _salt(uint256 id, string memory role) internal pure returns (bytes32) {
        return keccak256(abi.encode("market.arena", id, role));
    }

    function _party(uint256 id, string memory role, address boss) internal pure returns (Party) {
        return Party(
            payable(vm.computeCreate2Address(
                    _salt(id, role), keccak256(abi.encodePacked(type(Party).creationCode, abi.encode(boss)))
                ))
        );
    }

    function cast(uint256 id, address boss) public pure returns (Cast memory c) {
        c.seller = _party(id, "seller", boss);
        c.bidder = _party(id, "bidder", boss);
        c.holder = _party(id, "holder", boss);
        c.artist = _party(id, "artist", boss);
        c.nft = ArenaNFT(
            vm.computeCreate2Address(
                _salt(id, "nft"),
                keccak256(abi.encodePacked(type(ArenaNFT).creationCode, abi.encode(boss, address(c.artist))))
            )
        );
        c.matcher = ArenaMatcher(
            payable(vm.computeCreate2Address(_salt(id, "matcher"), keccak256(type(ArenaMatcher).creationCode)))
        );
        c.tricks = Tricks(payable(vm.computeCreate2Address(_salt(id, "tricks"), keccak256(type(Tricks).creationCode))));
        c.counterfeit =
            CounterfeitOrder(vm.computeCreate2Address(_salt(id, "counterfeit"), keccak256(type(CounterfeitOrder).creationCode)));
        c.drain = DrainHandler(vm.computeCreate2Address(_salt(id, "drain"), keccak256(type(DrainHandler).creationCode)));
        c.adversary = Adversary(
            payable(vm.computeCreate2Address(
                    _salt(id, "adversary"), keccak256(abi.encodePacked(type(Adversary).creationCode, abi.encode(boss)))
                ))
        );
    }

    function saleConfig(Cast memory c, uint256 start) public pure returns (bytes memory) {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(0.01 ether, 0.001 ether, start, start + DURATION, start + 7 days);
        return abi.encode(NFTSale.Config(c.nft, 1, s, address(c.seller), 1000));
    }

    function bidConfig(Cast memory c, uint256 start) public pure returns (bytes memory) {
        NFTTrade.Schedule memory s = NFTTrade.Schedule(0.002 ether, 0.006 ether, start, start + DURATION, start + 7 days);
        return abi.encode(NFTBid.Config(c.nft, true, 0, s, address(c.bidder), 2));
    }

    function orders(uint256 id, Cast memory c, uint256 start) public view returns (Order saleOrder, Order bidOrder) {
        saleOrder = Order(
            payable(market().orderAddress(address(c.seller), nftSale(), keccak256(saleConfig(c, start)), bytes32(id)))
        );
        bidOrder = Order(
            payable(market().orderAddress(address(c.bidder), nftBid(), keccak256(bidConfig(c, start)), bytes32(id)))
        );
    }

    function setup(uint256 id) external {
        address boss = msg.sender;
        Cast memory c = cast(id, boss);
        require(address(c.seller).code.length == 0, "id already used");
        uint256 start = block.timestamp;
        vm.startBroadcast(boss);
        new Party{salt: _salt(id, "seller")}(boss);
        new Party{salt: _salt(id, "bidder")}(boss);
        new Party{salt: _salt(id, "holder")}(boss);
        new Party{salt: _salt(id, "artist")}(boss);
        new ArenaNFT{salt: _salt(id, "nft")}(boss, address(c.artist));
        new ArenaMatcher{salt: _salt(id, "matcher")}();
        new Adversary{salt: _salt(id, "adversary")}(boss);
        new Tricks{salt: _salt(id, "tricks")}();
        new CounterfeitOrder{salt: _salt(id, "counterfeit")}();
        new DrainHandler{salt: _salt(id, "drain")}();
        c.nft.mint(address(c.seller), 1);
        c.nft.mint(address(c.holder), 2);
        c.nft.mint(address(c.holder), 3);
        (bool ok,) = address(c.bidder).call{value: 0.012 ether}("");
        (bool ok2,) = address(c.adversary).call{value: 0.01 ether}("");
        require(ok && ok2, "fund");
        c.seller.act(address(market()), 0, abi.encodeCall(Market.create, (nftSale(), saleConfig(c, start), bytes32(id))));
        (Order saleOrder, Order bidOrder) = orders(id, c, start);
        c.seller.act(address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (address(c.seller), address(saleOrder), 1)));
        c.bidder.act(
            address(market()), 0.012 ether, abi.encodeCall(Market.create, (nftBid(), bidConfig(c, start), bytes32(id)))
        );
        c.holder.act(address(c.nft), 0, abi.encodeCall(IERC721.setApprovalForAll, (address(nftBid()), true)));
        vm.stopBroadcast();

        require(c.nft.ownerOf(1) == address(saleOrder) && address(bidOrder).balance == 0.012 ether, "setup");
        console.log("start", start);
        console.log("sale order", address(saleOrder));
        console.log("bid order", address(bidOrder));
        console.log("adversary", address(c.adversary));
    }

    /// The attacks, as calls the adversary makes from its own address. Every one must fail.
    function attacks(uint256 id, Cast memory c, uint256 start) public view returns (Adversary.Attack[] memory a) {
        (Order saleOrder, Order bidOrder) = orders(id, c, start);
        bytes memory sc = saleConfig(c, start);
        bytes memory bc = bidConfig(c, start);
        address me = address(c.adversary);
        address holder = address(c.holder);
        bytes memory tampered = bytes.concat(sc);
        tampered[tampered.length - 1] = bytes1(uint8(tampered[tampered.length - 1]) ^ 1);
        Order closed = Order(payable(CLOSED_ORDER));
        a = new Adversary.Attack[](15);
        a[0] = Adversary.Attack(
            "sale onFill called directly",
            address(nftSale()),
            0,
            abi.encodeCall(IOrderHandler.onFill, (me, 1000 ether, sc, abi.encode(me, 1000 ether)))
        );
        a[1] = Adversary.Attack(
            "bid onFill called directly, naming the holder",
            address(nftBid()),
            0,
            abi.encodeCall(IOrderHandler.onFill, (holder, 0, bc, abi.encode(uint256(3), uint256(0), me)))
        );
        a[2] = Adversary.Attack(
            "counterfeit order announces a Sold", address(c.counterfeit), 0, abi.encodeCall(CounterfeitOrder.announce, (nftSale(), sc))
        );
        a[3] = Adversary.Attack(
            "closed rogue clone uses the holder's approval",
            address(c.tricks),
            0,
            abi.encodeCall(Tricks.closedRogueClone, (market(), nftBid(), bc, holder, 3))
        );
        a[4] = Adversary.Attack(
            "funded rogue clone filled for the holder's token",
            address(c.tricks),
            0.006 ether,
            abi.encodeCall(Tricks.fundedRogueClone, (market(), nftBid(), bc, 3))
        );
        a[5] = Adversary.Attack(
            "live bid filled naming the holder's token",
            address(bidOrder),
            0,
            abi.encodeCall(Order.fill, (bc, abi.encode(uint256(3), uint256(0), me)))
        );
        a[6] = Adversary.Attack(
            "execute on someone else's active sale",
            address(saleOrder),
            0,
            abi.encodeCall(
                Order.execute, (address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (address(saleOrder), me, 1)))
            )
        );
        a[7] = Adversary.Attack("close someone else's sale", address(saleOrder), 0, abi.encodeCall(Order.close, ()));
        a[8] = Adversary.Attack(
            "fill a sale with tampered config", address(saleOrder), 1, abi.encodeCall(Order.fill, (tampered, abi.encode(me, 1 ether)))
        );
        a[9] = Adversary.Attack(
            "underpay a live sale",
            address(saleOrder),
            1,
            abi.encodeCall(Order.fill, (sc, abi.encode(me, type(uint256).max)))
        );
        a[10] = Adversary.Attack(
            "hostile handler reaches the live bid",
            address(c.tricks),
            0,
            abi.encodeCall(Tricks.hostileHandler, (market(), c.drain, address(bidOrder)))
        );
        a[11] = Adversary.Attack(
            "execute on the Order implementation", market().implementation(), 0, abi.encodeCall(Order.execute, (me, 0, ""))
        );
        a[12] = Adversary.Attack("fill a closed order", address(closed), 0, abi.encodeCall(Order.fill, ("", "")));
        a[13] = Adversary.Attack(
            "execute a closed order as non-owner", address(closed), 0, abi.encodeCall(Order.execute, (me, 0, ""))
        );
        a[14] = Adversary.Attack(
            "pull the holder's token directly",
            address(c.nft),
            0,
            abi.encodeCall(IERC721.transferFrom, (holder, me, 3))
        );
    }

    function attack(uint256 id, uint256 start) external {
        Cast memory c = cast(id, msg.sender);
        (Order saleOrder,) = orders(id, c, start);
        Adversary.Attack[] memory list = attacks(id, c, start);
        vm.startBroadcast(msg.sender);
        c.adversary.run(list);
        vm.stopBroadcast();
        console.log("attempts", c.adversary.attempts());
        console.log("successes", c.adversary.successes());
        require(c.adversary.successes() == 0, "an attack succeeded");
        require(c.nft.ownerOf(1) == address(saleOrder) && c.nft.ownerOf(3) == address(c.holder), "assets moved");
    }

    function settle(uint256 id, uint256 start) external {
        Cast memory c = cast(id, msg.sender);
        (Order saleOrder, Order bidOrder) = orders(id, c, start);
        bytes memory sc = saleConfig(c, start);
        bytes memory bc = bidConfig(c, start);
        (uint256 ask,,) = nftSale().quote(abi.decode(sc, (NFTSale.Config)));
        (uint256 offer,, uint256 royalty) = nftBid().quote(address(bidOrder), abi.decode(bc, (NFTBid.Config)), 1);
        require(offer - royalty > ask, "prices have not crossed yet");
        vm.startBroadcast(msg.sender);
        c.matcher.matchSaleToBid{value: ask}(saleOrder, sc, ask, bidOrder, bc, c.nft, 1, offer - royalty, 0);
        c.holder.act(address(bidOrder), 0, abi.encodeCall(Order.fill, (bc, abi.encode(uint256(2), uint256(0), address(c.holder)))));
        vm.stopBroadcast();
        require(c.nft.ownerOf(1) == address(c.bidder) && c.nft.ownerOf(2) == address(c.bidder), "delivery");
        require(saleOrder.closed() && bidOrder.closed(), "orders closed");
        console.log("ask", ask);
        console.log("offer", offer);
        console.log("matcher spread", offer - royalty - ask);
    }

    function cleanup(uint256 id, uint256 start) external {
        address boss = msg.sender;
        Cast memory c = cast(id, boss);
        (, Order bidOrder) = orders(id, c, start);
        bytes memory bc = bidConfig(c, start);
        vm.startBroadcast(boss);
        // The bid is closed; its owner now holds `execute`. The holder's approval is to the
        // handler, so neither path can reach the holder's token 3.
        bool direct = c.bidder.attempt(
            address(bidOrder),
            0,
            abi.encodeCall(
                Order.execute,
                (address(c.nft), 0, abi.encodeCall(IERC721.transferFrom, (address(c.holder), address(c.bidder), 3)))
            )
        );
        bool viaHandler = c.bidder.attempt(
            address(bidOrder),
            0,
            abi.encodeCall(
                Order.execute,
                (
                    address(nftBid()),
                    0,
                    abi.encodeCall(IOrderHandler.onFill, (address(c.holder), 0, bc, abi.encode(uint256(3), uint256(0), address(c.bidder))))
                )
            )
        );
        uint256 left = address(bidOrder).balance;
        if (left != 0) c.bidder.act(address(bidOrder), 0, abi.encodeCall(Order.execute, (address(c.bidder), left, "")));
        c.holder.act(address(c.nft), 0, abi.encodeCall(IERC721.setApprovalForAll, (address(nftBid()), false)));
        Party[4] memory parties = [c.seller, c.bidder, c.holder, c.artist];
        for (uint256 i; i < 4; ++i) {
            uint256 b = address(parties[i]).balance;
            if (b != 0) parties[i].act(boss, b, "");
        }
        if (address(c.adversary).balance != 0) c.adversary.withdraw();
        vm.stopBroadcast();
        require(!direct && !viaHandler, "owner misused the holder's approval");
        require(c.nft.ownerOf(3) == address(c.holder), "holder kept token 3");
        require(address(bidOrder).balance == 0, "bid emptied");
    }
}
