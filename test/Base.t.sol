// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Market, IERC721} from "../contracts/Market.sol";
import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IERC721Safe is IERC721 {
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external;
}

/// Shared fork harness. Every bid used here is a real signed OpenSea offer taken
/// from the calldata of a real mainnet `matchAdvancedOrders` fill, replayed on a
/// fork pinned one block before that fill.
abstract contract Base is Test {
    ConsiderationInterface constant SEAPORT = ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant OS_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    bytes32 constant OS_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address constant OS_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    Market market;
    address protocol = makeAddr("protocol");
    address keeper = makeAddr("keeper");
    address admin = makeAddr("admin");
    Vm.Wallet seller = vm.createWallet("seller");

    // Loaded from a fixture.
    bytes bidBlob;
    bytes resolversBlob;
    address fulfiller; // address OpenSea's zone signature names as fulfiller
    address nft;
    uint256 tokenId;
    uint256 txTimestamp;

    function cut4(bytes calldata b) external pure returns (bytes memory) {
        return b[4:];
    }

    /// Fork one block before the original fill and decode its real bid.
    function loadFixture(string memory name) internal {
        string memory json = vm.readFile(string.concat("test/fixtures/", name, ".json"));
        uint256 blockNumber = vm.parseJsonUint(json, ".block");
        txTimestamp = vm.parseJsonUint(json, ".timestamp");
        fulfiller = vm.parseJsonAddress(json, ".from");
        vm.createSelectFork("mainnet", blockNumber - 1);
        vm.warp(txTimestamp);

        (AdvancedOrder[] memory orders, CriteriaResolver[] memory res,,) = abi.decode(
            this.cut4(vm.parseJsonBytes(json, ".input")), (AdvancedOrder[], CriteriaResolver[], Fulfillment[], address)
        );
        bidBlob = abi.encode(orders[0]);
        nft = orders[0].parameters.consideration[0].token;
        tokenId = orders[0].parameters.consideration[0].identifierOrCriteria;
        for (uint256 i; i < res.length; i++) {
            res[i].orderIndex = 0; // fillOffer passes the offer alone
            tokenId = res[i].identifier;
        }
        resolversBlob = abi.encode(res);
        // extraData bytes 1..21 are the fulfiller OpenSea signed for.
        assertEq(address(bytes20(this.slice(orders[0].extraData, 1, 21))), fulfiller, "zone fulfiller");
    }

    function bid() internal view returns (AdvancedOrder memory) {
        return abi.decode(bidBlob, (AdvancedOrder));
    }

    function resolvers() internal view returns (CriteriaResolver[] memory) {
        return abi.decode(resolversBlob, (CriteriaResolver[]));
    }

    function slice(bytes calldata b, uint256 from, uint256 to) external pure returns (bytes memory) {
        return b[from:to];
    }

    /// Place Market at the address OpenSea's real zone signature names, so the
    /// zone runs unmodified with OpenSea's real signer. The original fulfiller is
    /// an EOA; its WETH is swept out first so Market starts empty.
    function deployMarketAtSignedFulfiller() internal {
        uint256 stray = IERC20(address(WETH)).balanceOf(fulfiller);
        if (stray != 0) {
            vm.prank(fulfiller);
            IERC20(address(WETH)).transfer(makeAddr("sink"), stray);
        }
        deployCodeTo("Market.sol:Market", abi.encode(protocol, admin, OS_ZONE), fulfiller);
        market = Market(fulfiller);
        giveNftToSeller();
    }

    /// Fresh Market at a new address, which OpenSea's zone signature does not name.
    function deployMarket() internal {
        deployCodeTo("Market.sol:Market", abi.encode(protocol, admin, OS_ZONE), makeAddr("market"));
        market = Market(makeAddr("market"));
        giveNftToSeller();
    }

    function giveNftToSeller() internal {
        address owner = IERC721(nft).ownerOf(tokenId);
        vm.prank(owner);
        IERC721(nft).transferFrom(owner, seller.addr, tokenId);
    }

    /// A synthetic open WETH offer signed by a test wallet. Not OpenSea data; used
    /// only to drive adversarial shapes through real Seaport.
    function syntheticBid(Vm.Wallet memory bidder, uint256 amount, ConsiderationItem[] memory consideration)
        internal
        returns (AdvancedOrder memory order)
    {
        deal(address(WETH), bidder.addr, amount);
        vm.prank(bidder.addr);
        WETH.approve(OS_CONDUIT, type(uint256).max);
        OrderComponents memory c;
        c.offerer = bidder.addr;
        c.offer = new OfferItem[](1);
        c.offer[0] = OfferItem(ItemType.ERC20, address(WETH), 0, amount, amount);
        c.consideration = consideration;
        c.orderType = OrderType.FULL_OPEN;
        c.startTime = block.timestamp - 1;
        c.endTime = block.timestamp + 1 days;
        c.conduitKey = OS_CONDUIT_KEY;
        c.counter = SEAPORT.getCounter(bidder.addr);
        order = signed(bidder, c);
    }

    function sign(Vm.Wallet memory w, bytes32 orderHash) internal view returns (bytes memory) {
        (, bytes32 domainSeparator,) = SEAPORT.information();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w, keccak256(abi.encodePacked(hex"1901", domainSeparator, orderHash)));
        return abi.encodePacked(r, s, v);
    }

    /// WETH the bid releases after its own mandatory consideration (OpenSea fee,
    /// royalties). Fixture bids are full, fixed-price orders.
    function bidAvailable() internal view returns (uint256 available) {
        AdvancedOrder memory b = bid();
        assertEq(b.numerator, b.denominator, "full bid");
        available = b.parameters.offer[0].endAmount;
        ConsiderationItem[] memory c = b.parameters.consideration;
        for (uint256 i = 1; i < c.length; i++) {
            assertEq(c[i].token, address(WETH), "weth consideration");
            available -= c[i].endAmount;
        }
    }

    function signed(Vm.Wallet memory w, OrderComponents memory c) internal view returns (AdvancedOrder memory order) {
        order.parameters = OrderParameters(
            c.offerer,
            c.zone,
            c.offer,
            c.consideration,
            c.orderType,
            c.startTime,
            c.endTime,
            c.zoneHash,
            c.salt,
            c.conduitKey,
            c.consideration.length
        );
        order.numerator = 1;
        order.denominator = 1;
        order.signature = sign(w, SEAPORT.getOrderHash(c));
    }

    /// Fixed-price WETH listing terms; seller, nft and tokenId come from the transfer.
    function terms(uint256 floor) internal view returns (Market.Listing memory l) {
        l.currency = address(WETH);
        l.recipient = seller.addr;
        l.floor = uint128(floor);
        l.expiry = uint40(block.timestamp + 1 days);
        l.price = Market.Price(uint128(floor), uint128(floor), 0, 0, address(0), 0);
    }

    function list(Market.Listing memory l) internal returns (uint256 id) {
        vm.prank(seller.addr);
        IERC721Safe(nft)
            .safeTransferFrom(seller.addr, address(market), tokenId, abi.encodePacked(bytes1(0x00), abi.encode(l)));
        id = market.lastId();
        (l.seller, l.nft, l.tokenId) = (seller.addr, nft, tokenId);
    }
}
