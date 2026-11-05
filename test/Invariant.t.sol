// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../src/Market.sol";
import {IOrderHandler, Order} from "../src/Order.sol";
import {HandlerBase} from "../examples/HandlerBase.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";
import {AcquisitionBid, ICapitalSource, IBidStrategy} from "../examples/AcquisitionBid.sol";
import {RisingStrategy} from "../examples/BidStrategies.sol";
import {CapitalPool} from "../examples/CapitalPool.sol";
import {TestNFT, TestToken} from "./utils/Mocks.sol";

/// Drives several unrelated orders, their counterparties and an attacker through random
/// sequences, and keeps ghost accounting of every legitimate movement.
contract Driver is Test {
    Market public market = new Market();
    DutchAuction public dutch = new DutchAuction();
    TokenExchange public exchange = new TokenExchange();
    AcquisitionBid public acquisition = new AcquisitionBid();
    TestNFT public nft = new TestNFT();
    TestToken public give = new TestToken("GIVE");
    TestToken public take = new TestToken("TAKE");
    CapitalPool public pool;

    address public attacker = makeAddr("attacker");
    address public taker = makeAddr("taker");
    address public payee = makeAddr("payee");
    address public holder = makeAddr("holder");
    address public vault = makeAddr("vault");
    address public funder = makeAddr("funder");
    address public operator = makeAddr("operator");

    // Two sales by different sellers.
    Order[2] public sales;
    bytes[2] public saleConfigs;
    address[2] public sellers = [makeAddr("seller0"), makeAddr("seller1")];
    address[2] public buyers = [makeAddr("buyer0"), makeAddr("buyer1")];
    uint8[2] public saleState; // 0 open, 1 sold, 2 recovered
    uint256[2] public salePrice;

    Order public ex;
    bytes public exConfig;
    uint256 public deposited;
    uint256 public given;
    uint256 public owedSum;

    Order public bid;
    bytes public bidConfig;
    uint256 public bidFunded;
    uint256 public poolFunded;
    uint256 public paidToHolder;
    uint256 public acquired;
    uint256 public nextToken = 100;

    bool public attackSucceeded;
    uint256 public attacks;
    bool public ownerBypassed;

    constructor() {
        vm.warp(1_000_000);
        for (uint256 i; i < 2; ++i) {
            nft.mint(sellers[i], i);
            HandlerBase.Payee[] memory p = new HandlerBase.Payee[](1);
            p[0] = HandlerBase.Payee(sellers[i], 10_000);
            saleConfigs[i] = abi.encode(
                DutchAuction.Config(nft, i, 5 ether, 1 ether, block.timestamp, block.timestamp + 10_000, p)
            );
            vm.prank(sellers[i]);
            sales[i] = market.create(dutch, saleConfigs[i], 0);
            vm.prank(sellers[i]);
            nft.transferFrom(sellers[i], address(sales[i]), i);
            vm.deal(buyers[i], 1000 ether);
        }

        exConfig = abi.encode(TokenExchange.Config(give, take, 1, 2, payee, type(uint256).max));
        vm.prank(operator);
        ex = market.create(exchange, exConfig, 0);
        deposited = 1000e18;
        give.mint(address(ex), deposited);
        take.mint(taker, type(uint128).max);
        vm.prank(taker);
        take.approve(address(ex), type(uint256).max);

        pool = new CapitalPool(funder);
        bidConfig = abi.encode(
            AcquisitionBid.Config(
                nft,
                vault,
                3 ether,
                new RisingStrategy(),
                abi.encode(RisingStrategy.Params(0.5 ether, block.timestamp, 0.0001 ether, 8000)),
                pool
            )
        );
        vm.deal(operator, 1 ether);
        vm.prank(operator);
        bid = market.create{value: 1 ether}(acquisition, bidConfig, 0);
        bidFunded = 1 ether;
        vm.deal(address(pool), 20 ether);
        poolFunded = 20 ether;
        vm.prank(funder);
        pool.setGrant(address(bid), 0.0005 ether, 2 ether);

        vm.deal(attacker, 100 ether);
    }

    function wait(uint32 dt) external {
        skip(bound(dt, 1, 2 days));
    }

    function buySale(uint256 i, uint96 extra) external {
        i = bound(i, 0, 1);
        if (saleState[i] != 0) return;
        uint256 p = dutch.price(abi.decode(saleConfigs[i], (DutchAuction.Config)), block.timestamp);
        uint256 sellerBefore = sellers[i].balance;
        vm.prank(buyers[i]);
        sales[i].fill{value: p + bound(extra, 0, 1 ether)}(saleConfigs[i], abi.encode(buyers[i]));
        assertEq(sellers[i].balance - sellerBefore, p);
        (saleState[i], salePrice[i]) = (1, p);
    }

    function recoverSale(uint256 i) external {
        i = bound(i, 0, 1);
        if (saleState[i] != 0) return;
        vm.startPrank(sellers[i]);
        sales[i].close();
        sales[i].execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(sales[i]), sellers[i], i)));
        vm.stopPrank();
        saleState[i] = 2;
    }

    function fillExchange(uint256 amount) external {
        uint256 left = give.balanceOf(address(ex));
        if (left == 0) return;
        amount = bound(amount, 1, left);
        vm.prank(taker);
        uint256 owed = abi.decode(ex.fill(exConfig, abi.encode(amount, taker)), (uint256));
        assertEq(owed, amount * 2);
        given += amount;
        owedSum += owed;
    }

    function topUpExchange(uint96 amount) external {
        give.mint(address(ex), amount);
        deposited += amount;
    }

    function sellToBid(uint256 fraction) external {
        uint256 current = acquisition.currentBid(address(bid), abi.decode(bidConfig, (AcquisitionBid.Config)));
        uint256 price = current * bound(fraction, 0, 10_000) / 10_000;
        if (price == 0) return; // the bid refuses gifts; see test_zeroPriceSaleRejected
        uint256 id = nextToken++;
        nft.mint(holder, id);
        uint256 before = holder.balance;
        vm.startPrank(holder);
        nft.approve(address(bid), id);
        bid.fill(bidConfig, abi.encode(id, price));
        vm.stopPrank();
        assertLe(price, 3 ether);
        assertEq(holder.balance - before, price);
        assertEq(nft.ownerOf(id), vault);
        paidToHolder += price;
        acquired += 1;
    }

    function fundBid(uint96 amount, bool viaPool) external {
        amount = uint96(bound(amount, 0, 5 ether));
        if (viaPool) {
            vm.deal(address(pool), address(pool).balance + amount);
            poolFunded += amount;
        } else {
            vm.deal(address(bid), address(bid).balance + amount);
            bidFunded += amount;
        }
    }

    /// An owner tries to take something its active order holds, without closing it. Any
    /// success is recorded.
    function ownerTakesFromActive(uint256 which) external {
        Order[4] memory orders = [sales[0], sales[1], ex, bid];
        address[4] memory owners = [sellers[0], sellers[1], operator, operator];
        uint256 w = bound(which, 0, 3);
        if (orders[w].closed()) return;
        (address target, uint256 value, bytes memory data) = w < 2
            ? (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(orders[w]), owners[w], w)))
            : w == 2 ? (address(give), 0, abi.encodeCall(IERC20.transfer, (owners[w], 1))) : (owners[w], 1, bytes(""));
        vm.prank(owners[w]);
        (bool ok,) = address(orders[w]).call(abi.encodeCall(Order.execute, (target, value, data)));
        if (ok) ownerBypassed = true;
    }

    /// The attacker tries every authority it does not have. Any success is recorded.
    function attack(uint256 kind, uint256 which, uint256 id, bytes calldata junk) external {
        Order[4] memory orders = [sales[0], sales[1], ex, bid];
        Order target = orders[bound(which, 0, 3)];
        attacks++;
        vm.startPrank(attacker);
        bool ok;
        uint256 k = bound(kind, 0, 6);
        if (k == 0) {
            (ok,) = address(target).call(abi.encodeCall(Order.execute, (attacker, address(target).balance, "")));
        } else if (k == 1) {
            (ok,) = address(target).call(
                abi.encodeCall(
                    Order.execute,
                    (address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(target), attacker, id % 2)))
                )
            );
        } else if (k == 2) {
            (ok,) = address(target).call(abi.encodeCall(Order.close, ()));
        } else if (k == 3) {
            (ok,) = address(target).call(abi.encodeCall(Order.fill, (junk, junk)));
        } else if (k == 4) {
            (ok,) = address(pool).call(abi.encodeCall(ICapitalSource.draw, (bound(id, 1, 1 ether))));
        } else if (k == 5) {
            // Call a handler directly, as if the attacker were the order.
            (ok,) = address(target.handler()).call(
                abi.encodeCall(IOrderHandler.onFill, (attacker, 0, target == ex ? exConfig : bidConfig, junk))
            );
        } else {
            // Spend someone else's approval through an order they approved.
            (ok,) = address(ex).call(abi.encodeCall(Order.fill, (exConfig, abi.encode(uint256(1), attacker))));
        }
        vm.stopPrank();
        if (ok) attackSucceeded = true;
    }
}

contract InvariantTest is Test {
    Driver h;

    function setUp() public {
        h = new Driver();
        targetContract(address(h));
    }

    function invariant_attackerGainsNothing() public view {
        assertFalse(h.attackSucceeded());
        assertEq(h.attacker().balance, 100 ether);
        assertEq(h.nft().balanceOf(h.attacker()), 0);
        assertEq(h.give().balanceOf(h.attacker()), 0);
    }

    /// No owner moved anything out of an active order: only fills can.
    function invariant_activeOrdersStayCommitted() public view {
        assertFalse(h.ownerBypassed());
    }

    /// Each sale's NFT is where its history says: in the order, with its buyer (who paid at
    /// least the floor), or back with its seller. Sold and recovered orders are closed.
    function invariant_saleCustody() public view {
        for (uint256 i; i < 2; ++i) {
            address holderNow = h.nft().ownerOf(i);
            uint8 s = h.saleState(i);
            Order sale = h.sales(i);
            if (s == 0) {
                assertEq(holderNow, address(sale));
                assertFalse(sale.closed());
            } else if (s == 1) {
                assertEq(holderNow, h.buyers(i));
                assertGe(h.salePrice(i), 1 ether);
                assertTrue(sale.closed());
            } else {
                assertEq(holderNow, h.sellers(i));
                assertTrue(sale.closed());
            }
            assertEq(address(sale).balance, 0);
        }
    }

    /// Every GIVE the exchange released was paid for at its rate, to its payee, by its taker.
    function invariant_exchangeConservation() public view {
        IERC20 give = h.give();
        assertEq(give.balanceOf(address(h.ex())) + h.given(), h.deposited());
        assertEq(give.balanceOf(h.taker()), h.given());
        assertEq(h.take().balanceOf(h.payee()), h.owedSum());
        assertEq(h.owedSum(), h.given() * 2);
    }

    /// Every wei the bid paid came from its own funds or its pool grant, and it holds one NFT
    /// for every acquisition.
    function invariant_bidAccounting() public view {
        Order bid = h.bid();
        CapitalPool pool = h.pool();
        uint256 spentFromOrder = h.bidFunded() - address(bid).balance;
        uint256 drawn = h.poolFunded() - address(pool).balance;
        assertEq(spentFromOrder + drawn, h.paidToHolder());
        (,, uint64 count) = h.acquisition().state(address(bid));
        assertEq(count, h.acquired());
        assertEq(h.nft().balanceOf(h.vault()), h.acquired());
        assertFalse(bid.closed());
    }
}
