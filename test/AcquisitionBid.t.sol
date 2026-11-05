// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../src/Order.sol";
import {AcquisitionBid, ICapitalSource} from "../examples/AcquisitionBid.sol";
import {CapitalPool} from "../examples/CapitalPool.sol";
import {PolicyBase} from "../examples/PolicyBase.sol";
import {Base} from "./utils/Base.sol";
import {Reenterer, TestNFT} from "./utils/Mocks.sol";

/// Pretends to be an order in the middle of a fill.
contract FakeFilling {
    bool public constant filling = true;

    function draw(CapitalPool pool, uint256 amount) external {
        pool.draw(amount);
    }

    receive() external payable {}
}

contract AcquisitionBidTest is Base {
    CapitalPool pool;
    address funder = makeAddr("funder");
    address operator = makeAddr("operator");
    address vault = makeAddr("vault");
    address holder = makeAddr("holder");

    Order bid;
    bytes config;

    function setUp() public override {
        super.setUp();
        vm.deal(funder, 100 ether);
        vm.prank(funder);
        pool = new CapitalPool{value: 10 ether}(funder);
        for (uint256 i = 1; i <= 5; ++i) {
            nft.mint(holder, i);
        }
        // Starts at 1 ETH, rises 0.001 ETH per second, resets to half the clearing price but
        // not below 1 ETH,
        // never above 5 ETH. Funded by 0.5 ETH in the order plus a pool grant of up to
        // 3 ETH that accrues at 0.002 ETH per second.
        config = _bidConfig(vault, 5 ether, rising, _risingParams(1 ether, 0.001 ether, 5000), address(pool));
        vm.deal(operator, 1 ether);
        vm.prank(operator);
        bid = market.create{value: 0.5 ether}(acquisition, config, 0);
        vm.prank(funder);
        pool.setGrant(address(bid), 0.002 ether, 3 ether);
    }

    function _current() internal view returns (uint256) {
        return acquisition.currentBid(address(bid), abi.decode(config, (AcquisitionBid.Config)));
    }

    function test_bidRisesWithTimeAndCapital() public {
        // At start: quote 1 ETH, but capital is only the order's 0.5 ETH.
        assertEq(_current(), 0.5 ether);
        skip(500); // quote 1.5, capital 0.5 + 1.0 accrued
        assertEq(_current(), 1.5 ether);
        skip(1500); // quote 3.0, capital 0.5 + 3 (cap)
        assertEq(_current(), 3 ether);
        skip(10_000); // quote 13.0, capital 3.5
        assertEq(_current(), 3.5 ether);
        vm.deal(address(bid), 10 ether); // more capital: now limited by maxPrice
        assertEq(_current(), 5 ether);
    }

    function test_sellIntoBidRecordsClearingPriceAndResets() public {
        skip(500);
        assertEq(_current(), 1.5 ether);

        vm.prank(holder);
        nft.approve(address(bid), 1);
        vm.expectEmit(address(acquisition));
        emit AcquisitionBid.Acquired(address(bid), 1, holder, 1.4 ether);
        vm.prank(holder);
        bytes memory ret = bid.fill(config, abi.encode(1, 1.4 ether));

        assertEq(abi.decode(ret, (uint256)), 1.4 ether);
        assertEq(nft.ownerOf(1), vault);
        assertEq(holder.balance, 1.4 ether); // exactly what the holder asked
        assertEq(address(bid).balance, 0); // order ETH used first
        assertEq(pool.allowance(address(bid)), 0.1 ether); // 1.0 accrued - 0.9 drawn
        assertEq(address(pool).balance, 9.1 ether);
        (uint128 lastPrice, uint64 lastTime, uint64 count) = acquisition.state(address(bid));
        assertEq(lastPrice, 1.4 ether);
        assertEq(lastTime, block.timestamp);
        assertEq(count, 1);

        // Next quote restarts at half the clearing price (0.7), floored at the 1 ETH start, and
        // rises again; capital is what binds here.
        assertEq(_current(), 0.1 ether); // limited by capital: 0.1 accrued
        skip(100);
        assertEq(_current(), 0.3 ether); // quote 0.8; capital 0.1 + 0.2 = 0.3
        assertFalse(bid.closed());
    }

    function test_cannotSellAboveBid() public {
        skip(500);
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        vm.expectRevert(abi.encodeWithSelector(AcquisitionBid.AboveBid.selector, 1.6 ether, 1.5 ether));
        bid.fill(config, abi.encode(1, 1.6 ether));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), holder);
    }

    /// The same order keeps acquiring as capital arrives through either route.
    function test_persistsAcrossReplenishment() public {
        skip(2000);
        _sellInto(holder, bid, config, 1, 3 ether); // quote 3.0 within capital 3.5
        // Resets to 1.5 ETH; capital left: the grant's remaining 0.5 ETH.
        assertEq(_current(), 0.5 ether);

        skip(10_000);
        uint256 limitedByGrant = _current();
        assertEq(limitedByGrant, 3 ether); // grant refilled to its cap

        _sellInto(holder, bid, config, 2, 3 ether);
        assertEq(_current(), 0);

        // The pool runs dry; anyone can top up the order itself.
        vm.prank(funder);
        pool.withdraw(funder, address(pool).balance);
        skip(10_000);
        assertEq(_current(), 0);
        vm.prank(funder);
        (bool ok,) = address(bid).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(_current(), 2 ether);
        _sellInto(holder, bid, config, 3, 2 ether);

        (,, uint64 count) = acquisition.state(address(bid));
        assertEq(count, 3);
        assertEq(nft.balanceOf(vault), 3);
    }

    /// Conditional funding is not escrow: a quote can vanish before the fill lands.
    function test_fundingWithdrawnBeforeFillReverts() public {
        skip(1000);
        uint256 quoted = _current();
        vm.prank(funder);
        pool.withdraw(funder, address(pool).balance);
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        vm.expectRevert();
        bid.fill(config, abi.encode(1, quoted));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), holder);
    }

    function test_revokedGrantStopsDraws() public {
        skip(1000);
        vm.prank(funder);
        pool.setGrant(address(bid), 0, 0);
        assertEq(_current(), 0.5 ether);
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        vm.expectRevert(abi.encodeWithSelector(AcquisitionBid.AboveBid.selector, 0.6 ether, 0.5 ether));
        bid.fill(config, abi.encode(1, 0.6 ether));
        vm.stopPrank();
    }

    /// The pool releases capital only to the order's policy during a fill. The order's owner,
    /// and contracts pretending to be filling orders, get nothing.
    function test_poolPaysOnlyThroughAFill() public {
        skip(1000);
        vm.prank(operator);
        vm.expectRevert(CapitalPool.NotFilling.selector);
        bid.execute(address(pool), 0, abi.encodeCall(ICapitalSource.draw, (1 ether)));

        vm.prank(attacker);
        vm.expectRevert();
        pool.draw(1 ether);

        FakeFilling fake = new FakeFilling();
        vm.expectRevert(abi.encodeWithSelector(CapitalPool.OverAllowance.selector, 1 ether, 0));
        fake.draw(pool, 1 ether);
        assertEq(address(pool).balance, 10 ether);
    }

    function test_poolGrantAccruesToCap() public {
        assertEq(pool.allowance(address(bid)), 0);
        skip(100);
        assertEq(pool.allowance(address(bid)), 0.2 ether);
        skip(100_000);
        assertEq(pool.allowance(address(bid)), 3 ether);
        // Lowering the cap keeps what accrued, up to the new cap.
        vm.prank(funder);
        pool.setGrant(address(bid), 0.002 ether, 1 ether);
        assertEq(pool.allowance(address(bid)), 1 ether);
        vm.prank(attacker);
        vm.expectRevert(CapitalPool.NotOwner.selector);
        pool.setGrant(attacker, 1 ether, 100 ether);
    }

    function test_onlyTheHolderCanSellItsToken() public {
        skip(500);
        vm.prank(holder);
        nft.approve(address(bid), 1);
        // The policy takes delivery only from the caller.
        vm.prank(attacker);
        vm.expectRevert();
        bid.fill(config, abi.encode(1, 1 ether));
        assertEq(nft.ownerOf(1), holder);
    }

    /// A token from another collection is not what the bid committed to buy.
    function test_counterfeitCollectionCannotSell() public {
        skip(500);
        TestNFT fake = new TestNFT();
        fake.mint(attacker, 9);
        vm.startPrank(attacker);
        fake.approve(address(bid), 9);
        vm.expectRevert();
        bid.fill(config, abi.encode(9, 1 ether));
        vm.stopPrank();
        assertEq(attacker.balance, 100 ether);
    }

    /// Delivering to yourself, or "delivering" a token the recipient already has, is not delivery.
    function test_selfDeliveryRejected() public {
        vm.deal(address(this), 0);
        bytes memory toSelf = _bidConfig(holder, 5 ether, rising, _risingParams(1 ether, 0, 5000), address(0));
        vm.prank(operator);
        Order selfBid = market.create{value: 0.5 ether}(acquisition, toSelf, 0);
        vm.startPrank(holder);
        nft.approve(address(selfBid), 1);
        vm.expectRevert(AcquisitionBid.NotDelivered.selector);
        selfBid.fill(toSelf, abi.encode(1, 0.5 ether));
        vm.stopPrank();
    }

    function test_rejectsEth() public {
        vm.prank(holder);
        vm.deal(holder, 1);
        vm.expectRevert(PolicyBase.UnexpectedETH.selector);
        bid.fill{value: 1}(config, abi.encode(1, 0));
    }

    /// A seller contract paid by the bid cannot sell again inside its payment.
    function test_sellerCannotReenter() public {
        skip(2000);
        Reenterer seller_ = new Reenterer();
        vm.prank(holder);
        nft.transferFrom(holder, address(seller_), 1);
        vm.prank(holder);
        nft.transferFrom(holder, address(seller_), 2);
        seller_.call(address(nft), 0, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(bid), true));
        seller_.arm(address(bid), abi.encodeCall(Order.fill, (config, abi.encode(2, 0.1 ether))));
        seller_.call(address(bid), 0, abi.encodeCall(Order.fill, (config, abi.encode(1, 1 ether))));
        assertTrue(seller_.attempted());
        assertFalse(seller_.succeeded());
        assertEq(nft.ownerOf(2), address(seller_));
        (,, uint64 count) = acquisition.state(address(bid));
        assertEq(count, 1);
    }

    /// The operator controls the order's own ETH and can stop the bid, but never the pool.
    function test_operatorStopsBidAndRecoversOrderFunds() public {
        vm.startPrank(operator);
        bid.close();
        bid.execute(operator, 0.5 ether, "");
        vm.stopPrank();
        assertEq(operator.balance, 1 ether);
        assertEq(address(pool).balance, 10 ether);
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        vm.expectRevert(Order.OrderClosed.selector);
        bid.fill(config, abi.encode(1, 0));
        vm.stopPrank();
    }

    /// A gift at price zero is not a clearing price: it is refused and nothing is recorded.
    function test_zeroPriceSaleRejected() public {
        vm.deal(address(bid), 10 ether);
        skip(1000);
        assertEq(_current(), 2 ether);
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        vm.expectRevert(AcquisitionBid.ZeroPrice.selector);
        bid.fill(config, abi.encode(1, 0));
        vm.stopPrank();
        (uint128 lastPrice, uint64 lastTime, uint64 count) = acquisition.state(address(bid));
        assertEq(lastPrice, 0);
        assertEq(lastTime, 0);
        assertEq(count, 0);
        assertEq(nft.ownerOf(1), holder);
        skip(500);
        assertEq(_current(), 2.5 ether); // the climb was not interrupted
    }

    /// Any paid sale, however cheap, is a clearing price. The rising strategy restarts at its
    /// start price and climbs again; whoever forces a restart gives the bid a token each time.
    function test_cheapSaleRestartsAtStartPrice() public {
        vm.deal(address(bid), 10 ether);
        skip(1000);
        _sellInto(holder, bid, config, 1, 1);
        (uint128 lastPrice,, uint64 count) = acquisition.state(address(bid));
        assertEq(lastPrice, 1);
        assertEq(count, 1);
        assertEq(nft.ownerOf(1), vault);
        assertEq(_current(), 1 ether);
        skip(500);
        assertEq(_current(), 1.5 ether);
    }

    /// The operator can make the bid order fill itself, but the policy's rules still apply: the
    /// pool pays only the strategy's price, and only for a token actually delivered to the vault.
    function test_operatorSelfFillFollowsPolicyRules() public {
        skip(1000); // bid 2 ETH: quote 2.0, capital 0.5 + 2.0
        vm.prank(holder);
        nft.transferFrom(holder, operator, 1);
        vm.prank(operator);
        nft.transferFrom(operator, address(bid), 1);

        bytes memory selfFill = abi.encodeCall(Order.fill, (config, abi.encode(1, 2.1 ether)));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AcquisitionBid.AboveBid.selector, 2.1 ether, 2 ether));
        bid.execute(address(bid), 0, selfFill);

        vm.prank(operator);
        bid.execute(address(bid), 0, abi.encodeCall(Order.fill, (config, abi.encode(1, 2 ether))));
        assertEq(nft.ownerOf(1), vault);
        assertEq(address(bid).balance, 2 ether); // paid to the caller, here the order itself
        assertEq(address(pool).balance, 8.5 ether);
    }

    /// Example 4b: another application swaps in different pricing and funding without any
    /// change to Market or to the bid policy. It always bids 25% of whatever capital the order
    /// holds, and is replenished only by deposits to the order.
    function test_substituteStrategyAndFunding() public {
        bytes memory cfg = _bidConfig(vault, 100 ether, share, abi.encode(uint256(2500)), address(0));
        vm.deal(operator, 1 ether);
        vm.prank(operator);
        Order other = market.create{value: 1 ether}(acquisition, cfg, bytes32(uint256(1)));
        AcquisitionBid.Config memory c = abi.decode(cfg, (AcquisitionBid.Config));

        assertEq(acquisition.currentBid(address(other), c), 0.25 ether);
        _sellInto(holder, other, cfg, 1, 0.25 ether);
        assertEq(acquisition.currentBid(address(other), c), 0.1875 ether); // 25% of 0.75

        vm.deal(address(other), 8 ether); // capital arrives
        assertEq(acquisition.currentBid(address(other), c), 2 ether);
        _sellInto(holder, other, cfg, 2, 2 ether);
        assertEq(nft.balanceOf(vault), 2);
        assertEq(holder.balance, 2.25 ether);
    }

    function testFuzz_payoutNeverExceedsBid(uint32 elapsed, uint96 price) public {
        skip(elapsed);
        uint256 current = _current();
        uint256 poolBefore = address(pool).balance;
        uint256 orderBefore = address(bid).balance;
        vm.startPrank(holder);
        nft.approve(address(bid), 1);
        if (price == 0) {
            vm.expectRevert(AcquisitionBid.ZeroPrice.selector);
            bid.fill(config, abi.encode(1, uint256(0)));
            vm.stopPrank();
            return;
        }
        if (price > current) {
            vm.expectRevert(abi.encodeWithSelector(AcquisitionBid.AboveBid.selector, price, current));
            bid.fill(config, abi.encode(1, uint256(price)));
            vm.stopPrank();
            return;
        }
        bid.fill(config, abi.encode(1, uint256(price)));
        vm.stopPrank();
        assertEq(holder.balance, price);
        assertLe(price, 5 ether);
        // Every wei paid came from the order or the pool.
        assertEq(poolBefore - address(pool).balance + orderBefore - address(bid).balance, price);
    }
}
