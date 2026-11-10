// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../../src/Market.sol";
import {Order} from "../../src/Order.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {FillVerifier} from "../../periphery/FillVerifier.sol";
import {PaintAction} from "../../examples/PaintAction.sol";
import {Arena, Adversary, ArenaNFT} from "../../script/Arena.s.sol";
import {Reenterer, RoyaltyNFT} from "../utils/Mocks.sol";
import {WalletBatch} from "../Eip7702Filler.t.sol";

/// The release as deployed on Sepolia, on a fork pinned at `BLOCK`: every call goes to the
/// live contracts. Covers the arena exercise (`script/Arena.s.sol`) end to end with time
/// advanced past the price crossing, and attacks that need cheatcodes (impersonation,
/// EIP-7702 delegation) the live run cannot use.
/// RPC: `SEPOLIA_RPC_URL`, default https://sepolia.gateway.tenderly.co.
contract SepoliaLiveTest is Test {
    uint256 constant BLOCK = 12_107_304;
    Market constant MARKET = Market(0x8210144750E6237740bf71b819f87A834905445d);
    NFTSale constant SALE = NFTSale(0x72649226f648d8a33f8eee78B71e5D9d9e18D9C7);
    NFTBid constant BID = NFTBid(0x0FeE65df72d3194b07235D275b60269E15FC1445);
    FillVerifier constant VERIFIER = FillVerifier(0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0);
    PaintAction constant PAINT = PaintAction(0x2e8341791F5c1c44313dd2c3e43dF6476756B237);

    address buyer = makeAddr("buyer");
    address bidder = makeAddr("bidder");
    address royaltyTo = makeAddr("royaltyTo");

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://sepolia.gateway.tenderly.co")), BLOCK);
        vm.deal(buyer, 100 ether);
        vm.deal(bidder, 100 ether);
    }

    receive() external payable {}

    /// The handlers on chain are exactly this repository's code built against the live Market.
    function test_liveBytecodeMatchesBuild() public {
        assertEq(address(SALE).codehash, address(new NFTSale(MARKET)).codehash, "NFTSale");
        assertEq(address(BID).codehash, address(new NFTBid(MARKET)).codehash, "NFTBid");
        assertEq(address(VERIFIER).codehash, address(new FillVerifier()).codehash, "FillVerifier");
        assertEq(address(PAINT).codehash, address(new PaintAction()).codehash, "PaintAction");
        assertEq(MARKET.implementation(), 0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87);
    }

    /// The whole arena, as `script/Arena.s.sol` will run it on Sepolia, from this contract.
    function test_arena() public {
        Arena arena = new Arena();
        vm.deal(address(this), 1 ether);
        uint256 before = address(this).balance;
        // `vm.getBlockTimestamp` returns a value; `block.timestamp` would be re-read after `vm.warp` under via-IR.
        uint256 start = vm.getBlockTimestamp();
        arena.setup(7);
        vm.recordLogs();
        arena.attack(7, start);
        Arena.Cast memory c = arena.cast(7, address(this));
        assertEq(c.adversary.attempts(), 15);
        assertEq(c.adversary.successes(), 0);
        _assertRefusedForTheRightReason(vm.getRecordedLogs());

        vm.expectRevert("prices have not crossed yet");
        arena.settle(7, start);
        vm.warp(start + 1200); // ask 0.004, bid 0.00466666
        arena.settle(7, start);
        arena.cleanup(7, start);

        assertEq(c.nft.ownerOf(1), address(c.bidder));
        assertEq(c.nft.ownerOf(2), address(c.bidder));
        assertEq(c.nft.ownerOf(3), address(c.holder));
        assertEq(address(this).balance, before, "every wei returns to the sender");
    }

    /// A royalty receiver that tries to sell into the same live bid again while being paid.
    function test_royaltyReceiverCannotRefillLiveBid() public {
        Reenterer r = new Reenterer();
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.setRoyalty(address(r), 500);
        nft.mint(address(r), 1);
        address holder = makeAddr("holder");
        nft.mint(holder, 2);
        bytes memory config = abi.encode(NFTBid.Config(nft, true, 0, _fixed(0.01 ether), bidder, 3));
        vm.prank(bidder);
        Order bid = MARKET.create{value: 0.03 ether}(BID, config, 0);
        r.call(address(nft), 0, abi.encodeCall(IERC721.setApprovalForAll, (address(BID), true)));
        r.arm(address(bid), abi.encodeCall(Order.fill, (config, abi.encode(uint256(1), uint256(0), address(r)))));
        vm.startPrank(holder);
        nft.setApprovalForAll(address(BID), true);
        bid.fill(config, abi.encode(uint256(2), uint256(0), holder));
        vm.stopPrank();
        assertTrue(r.attempted());
        assertFalse(r.succeeded(), "reentrant fill of the same order refused");
        assertEq(BID.fills(address(bid)), 1);
        assertEq(nft.ownerOf(1), address(r));
    }

    /// An EIP-7702 delegated EOA buys from the live NFTSale and proves its receipt with the
    /// live FillVerifier, in one atomic batch.
    function test_delegatedEoaBuysWithLiveVerifier() public {
        (address eoa, uint256 key) = makeAddrAndKey("eoa");
        vm.deal(eoa, 1 ether);
        address seller = makeAddr("seller");
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.setRoyalty(royaltyTo, 500);
        nft.mint(seller, 1);
        bytes memory config = abi.encode(NFTSale.Config(nft, 1, _fixed(0.1 ether), seller, 1000));
        vm.prank(seller);
        Order sale = MARKET.create(SALE, config, 0);
        vm.prank(seller);
        nft.transferFrom(seller, address(sale), 1);

        bytes memory mine = abi.encodeCall(IERC721.ownerOf, (1));
        WalletBatch.Call[] memory calls = new WalletBatch.Call[](2);
        calls[0] = WalletBatch.Call(address(sale), 0.1 ether, abi.encodeCall(Order.fill, (config, abi.encode(eoa, 0.1 ether))));
        calls[1] = WalletBatch.Call(
            address(VERIFIER), 0, abi.encodeCall(FillVerifier.requireEqual, (address(nft), mine, abi.encode(eoa)))
        );
        WalletBatch wallet = new WalletBatch();
        vm.signAndAttachDelegation(address(wallet), key);
        vm.prank(eoa);
        WalletBatch(payable(eoa)).execute(calls);
        assertEq(nft.ownerOf(1), eoa);
        assertEq(seller.balance, 0.095 ether);
        assertEq(royaltyTo.balance, 0.005 ether);
    }

    /// Settlement on the live sale conserves ETH for any schedule, time and overpayment.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_liveSaleConserves(uint96 startPrice, uint96 endPrice, uint32 wait, uint96 extra) public {
        address seller = makeAddr("seller");
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.setRoyalty(royaltyTo, 250);
        nft.mint(seller, 1);
        NFTTrade.Schedule memory s =
            NFTTrade.Schedule(startPrice, endPrice, block.timestamp, block.timestamp + 1 days, 0);
        bytes memory config = abi.encode(NFTSale.Config(nft, 1, s, seller, 250));
        vm.prank(seller);
        Order sale = MARKET.create(SALE, config, 0);
        vm.prank(seller);
        nft.transferFrom(seller, address(sale), 1);
        vm.warp(block.timestamp + wait);
        (uint256 price,, uint256 royalty) = SALE.quote(abi.decode(config, (NFTSale.Config)));
        uint256 value = price + uint256(extra);
        vm.deal(buyer, value);
        vm.prank(buyer);
        sale.fill{value: value}(config, abi.encode(buyer, price));
        assertEq(buyer.balance, extra);
        assertEq(seller.balance + royaltyTo.balance, price);
        assertEq(royaltyTo.balance, royalty);
        assertEq(address(sale).balance, 0);
        assertEq(nft.ownerOf(1), buyer);
    }

    /// The orders the lifecycle run left on Sepolia stay inert to outsiders.
    function test_lifecycleOrdersStayInert() public {
        address[4] memory closed = [
            0xEB454891C38a45DD08379c41fe1e16AA3D82ba04,
            0xC605656E66d536b91aDed9dE72F37F6b93Ae5A8a,
            0x4AfaaB884C903A220d8BD7aBB2af20a5F33fD118,
            0x79b774A5DEEBC99EcE38d30D204A1d473e38dA8a
        ];
        for (uint256 i; i < 4; ++i) {
            Order o = Order(payable(closed[i]));
            assertTrue(o.closed());
            vm.startPrank(buyer);
            vm.expectRevert(Order.OrderClosed.selector);
            o.fill("", "");
            vm.expectRevert(Order.Unauthorized.selector);
            o.execute(buyer, 0, "");
            vm.stopPrank();
        }
    }

    /// Each attack must fail with the error that names the defence, not an unrelated revert.
    function _assertRefusedForTheRightReason(Vm.Log[] memory logs) internal pure {
        bytes4[15] memory expected = [
            NFTTrade.NotAFill.selector, // sale onFill called directly
            NFTTrade.NotAFill.selector, // bid onFill called directly
            NFTTrade.NotAFill.selector, // counterfeit order
            NFTTrade.NotAFill.selector, // closed rogue clone
            IERC721Errors.ERC721IncorrectOwner.selector, // funded rogue clone: it may fill, but only pulls from itself
            IERC721Errors.ERC721IncorrectOwner.selector, // live bid filled for the holder's token: pulls from the filler
            Order.Unauthorized.selector, // execute on an active sale
            Order.Unauthorized.selector, // close someone else's sale
            Order.WrongConfig.selector, // tampered config
            NFTSale.Underpaid.selector, // underpay
            Order.Unauthorized.selector, // hostile handler reaches another order
            Order.Unauthorized.selector, // execute on the implementation
            Order.OrderClosed.selector, // fill a closed order
            Order.Unauthorized.selector, // execute a closed order as non-owner
            IERC721Errors.ERC721InsufficientApproval.selector // pull the holder's token directly
        ];
        bytes32 topic = keccak256("Attempt(string,bool,bytes)");
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            (string memory name, bool succeeded, bytes memory result) = abi.decode(logs[i].data, (string, bool, bytes));
            assertFalse(succeeded, name);
            assertEq(bytes4(result), expected[n], name);
            n += 1;
        }
        assertEq(n, 15);
    }

    function _fixed(uint256 price) internal view returns (NFTTrade.Schedule memory) {
        return NFTTrade.Schedule(price, price, block.timestamp, block.timestamp, 0);
    }
}
