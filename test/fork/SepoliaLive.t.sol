// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Market} from "../../src/Market.sol";
import {Order} from "../../src/Order.sol";
import {FeeConfig} from "../../handlers/FeeConfig.sol";
import {NFTBid} from "../../handlers/NFTBid.sol";
import {NFTSale} from "../../handlers/NFTSale.sol";
import {NFTTrade} from "../../handlers/NFTTrade.sol";
import {FillVerifier} from "../../periphery/FillVerifier.sol";
import {PaintAction} from "../../examples/PaintAction.sol";
import {Arena, Adversary, ArenaNFT} from "../../script/Arena.s.sol";
import {Reenterer, RoyaltyNFT} from "../utils/Mocks.sol";
import {WalletBatch} from "../Eip7702Filler.t.sol";

/// Run the historical arena against the historical Sepolia addresses even though the current
/// deployment script now computes different addresses for the right-enabled candidate.
contract LegacyArena is Arena {
    function market() internal pure override returns (Market) {
        return Market(0x7c91e34703ae3E32812bad1f7251CD0976A31FD4);
    }

    function nftSale() internal pure override returns (NFTSale) {
        return NFTSale(0xfEf3a72600a453F82650343525751811120da2c8);
    }

    function nftBid() internal pure override returns (NFTBid) {
        return NFTBid(0x8dbB30441bB0ca607bC17A3ea763C8f66B30017E);
    }
}

/// The release as deployed on Sepolia, on a fork pinned at `BLOCK`: every call goes to the
/// live contracts. Covers the arena exercise (`script/Arena.s.sol`) end to end with time
/// advanced past the price crossing, and attacks that need cheatcodes (impersonation,
/// EIP-7702 delegation) the live run cannot use.
/// RPC: `SEPOLIA_RPC_URL`, default https://sepolia.gateway.tenderly.co.
contract SepoliaLiveTest is Test {
    uint256 constant BLOCK = 12_150_234;
    Market constant MARKET = Market(0x7c91e34703ae3E32812bad1f7251CD0976A31FD4);
    FeeConfig constant FEES = FeeConfig(0x9A181B2129540Df9502a30e08a4E4e34Cd7406fF);
    NFTSale constant SALE = NFTSale(0xfEf3a72600a453F82650343525751811120da2c8);
    NFTBid constant BID = NFTBid(0x8dbB30441bB0ca607bC17A3ea763C8f66B30017E);
    address constant FEE_ADMIN = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    address constant FEE_TO = 0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72;
    FillVerifier constant VERIFIER = FillVerifier(0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0);
    PaintAction constant PAINT = PaintAction(0x2e8341791F5c1c44313dd2c3e43dF6476756B237);

    address buyer = makeAddr("buyer");
    address bidder = makeAddr("bidder");
    address royaltyTo = makeAddr("royaltyTo");
    uint256 _feeToBefore;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://sepolia.gateway.tenderly.co")), BLOCK);
        vm.deal(buyer, 100 ether);
        vm.deal(bidder, 100 ether);
        _feeToBefore = FEE_TO.balance;
    }

    receive() external payable {}

    /// Historical Sepolia deployments predate native rights. Their order paths remain testable
    /// on this fork, but their bytecode must not be presented as the redesigned build.
    function test_legacyBytecodeIsDistinctFromRightEnabledBuild() public {
        Market candidate = new Market();
        FeeConfig candidateFees = new FeeConfig(candidate, FEE_ADMIN, FEE_TO);
        assertNotEq(address(MARKET).codehash, address(candidate).codehash, "Market is legacy");
        assertNotEq(address(SALE).codehash, address(new NFTSale(candidateFees)).codehash, "NFTSale is legacy");
        assertNotEq(address(BID).codehash, address(new NFTBid(candidateFees)).codehash, "NFTBid is legacy");
        // Pin the historical deployed runtime independently of current-source metadata.
        assertEq(
            address(VERIFIER).codehash,
            0xbb49051cebc22b73e345ad3e65c789467b1a0f7e77d240ca4a3b3167749c607e,
            "historical FillVerifier"
        );
        assertNotEq(address(VERIFIER).codehash, address(new FillVerifier()).codehash, "updated metadata");
        assertEq(MARKET.implementation(), 0x1c8Af1349Fa2b41903291675DCf5e9dfc2A8fB83);
    }

    /// The live fee terms are the deployment's: the owner's admin and recipient, 1%, this Market.
    function test_liveFeeTerms() public view {
        assertEq(FEES.admin(), FEE_ADMIN);
        assertEq(FEES.pendingAdmin(), address(0));
        assertEq(FEES.recipient(), FEE_TO);
        assertEq(FEES.feeBps(), 100);
        assertEq(FEES.MAX_FEE_BPS(), 100);
        assertEq(address(FEES.market()), address(MARKET));
        assertEq(address(SALE.fees()), address(FEES));
        assertEq(address(BID.fees()), address(FEES));
    }

    /// The live admin's changes: a rate cut binds only later orders, a new recipient every fill.
    function test_liveAdminChangesApplyAsSpecified() public {
        address seller = makeAddr("seller");
        RoyaltyNFT nft = new RoyaltyNFT();
        nft.setRoyalty(royaltyTo, 500);
        nft.mint(seller, 1);
        nft.mint(seller, 2);
        bytes memory c1 = abi.encode(NFTSale.Config(nft, 1, _fixed(1 ether), seller, 1000));
        bytes memory c2 = abi.encode(NFTSale.Config(nft, 2, _fixed(1 ether), seller, 1000));
        vm.startPrank(seller);
        Order early = MARKET.create(SALE, c1, 0);
        nft.transferFrom(seller, address(early), 1);
        vm.stopPrank();

        address next = makeAddr("next recipient");
        vm.startPrank(FEE_ADMIN);
        FEES.setFee(50);
        FEES.setRecipient(next);
        vm.stopPrank();
        skip(1);
        vm.startPrank(seller);
        Order late = MARKET.create(SALE, c2, 0);
        nft.transferFrom(seller, address(late), 2);
        vm.stopPrank();

        vm.startPrank(buyer);
        early.fill{value: 1 ether}(c1, abi.encode(buyer, 1 ether));
        late.fill{value: 1 ether}(c2, abi.encode(buyer, 1 ether));
        vm.stopPrank();
        assertEq(next.balance, 0.015 ether, "1% from the early order, 0.5% from the late one");
        assertEq(FEE_TO.balance - _feeToBefore, 0, "old recipient gets nothing after the change");
        assertEq(seller.balance, 0.94 ether + 0.945 ether);
        assertEq(royaltyTo.balance, 0.1 ether);
    }

    /// The whole arena, as `script/Arena.s.sol` will run it on Sepolia, from this contract.
    function test_arena() public {
        Arena arena = new LegacyArena();
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
        uint256 fees = FEE_TO.balance - _feeToBefore;
        assertGt(fees, 0, "the arena's trades paid the fee");
        assertEq(address(this).balance + fees, before, "every wei returns to the sender but the fee");
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
        calls[0] = WalletBatch.Call(
            address(sale), 0.1 ether, abi.encodeCall(Order.fill, (config, abi.encode(eoa, 0.1 ether)))
        );
        calls[1] = WalletBatch.Call(
            address(VERIFIER), 0, abi.encodeCall(FillVerifier.requireEqual, (address(nft), mine, abi.encode(eoa)))
        );
        WalletBatch wallet = new WalletBatch();
        vm.signAndAttachDelegation(address(wallet), key);
        vm.prank(eoa);
        WalletBatch(payable(eoa)).execute(calls);
        assertEq(nft.ownerOf(1), eoa);
        assertEq(seller.balance, 0.094 ether, "less 5% royalty and 1% fee");
        assertEq(royaltyTo.balance, 0.005 ether);
        assertEq(FEE_TO.balance - _feeToBefore, 0.001 ether);
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
        (uint256 price,, uint256 royalty, uint256 fee, address feeTo) =
            SALE.quote(address(sale), abi.decode(config, (NFTSale.Config)));
        assertEq(feeTo, FEE_TO);
        assertEq(fee, price / 100);
        uint256 value = price + uint256(extra);
        vm.deal(buyer, value);
        vm.prank(buyer);
        sale.fill{value: value}(config, abi.encode(buyer, price));
        assertEq(buyer.balance, extra);
        assertEq(seller.balance + royaltyTo.balance + FEE_TO.balance - _feeToBefore, price);
        assertEq(royaltyTo.balance, royalty);
        assertEq(FEE_TO.balance - _feeToBefore, fee);
        assertEq(address(sale).balance, 0);
        assertEq(nft.ownerOf(1), buyer);
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
