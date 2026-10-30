// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Market, IWETH, IERC721} from "../contracts/Market.sol";
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

interface IERC721Full is IERC721 {
    function transferFrom(address from, address to, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
}

/// Shared fork harness. Every bid used here is a real signed OpenSea offer taken
/// from the calldata of a real mainnet `matchAdvancedOrders` fill, replayed on a
/// fork pinned one block before that fill.
abstract contract Base is Test {
    ConsiderationInterface constant SEAPORT = ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    bytes32 constant OS_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address constant OS_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    Market market;
    address protocol = makeAddr("protocol");
    address keeper = makeAddr("keeper");
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
            this.cut4(vm.parseJsonBytes(json, ".input")),
            (AdvancedOrder[], CriteriaResolver[], Fulfillment[], address)
        );
        bidBlob = abi.encode(orders[0]);
        nft = orders[0].parameters.consideration[0].token;
        tokenId = orders[0].parameters.consideration[0].identifierOrCriteria;
        for (uint256 i; i < res.length; i++) {
            res[i].orderIndex = 1; // bid sits at index 1 in [listing, bid]
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
    /// an EOA; its NFT moves to our seller and its WETH is swept out first.
    function deployMarketAtSignedFulfiller() internal {
        giveNftToSeller();
        uint256 stray = WETH.balanceOf(fulfiller);
        if (stray != 0) {
            vm.prank(fulfiller);
            WETH.transfer(makeAddr("sink"), stray);
        }
        deployCodeTo("Market.sol:Market", abi.encode(protocol), fulfiller);
        market = Market(fulfiller);
    }

    /// Fresh Market at a new address, for tests that do not need OpenSea's zone.
    function deployMarket() internal {
        giveNftToSeller();
        // A fixed fresh address: CREATE addresses from the default test deployer
        // hold stray mainnet WETH on the fork.
        deployCodeTo("Market.sol:Market", abi.encode(protocol), makeAddr("market"));
        market = Market(makeAddr("market"));
    }

    function giveNftToSeller() internal {
        address owner = IERC721(nft).ownerOf(tokenId);
        vm.prank(owner);
        IERC721Full(nft).transferFrom(owner, seller.addr, tokenId);
        vm.prank(seller.addr);
        IERC721Full(nft).setApprovalForAll(OS_CONDUIT, true);
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

    function listing(uint256 startAmount, uint256 endAmount, uint256 startTime, uint256 endTime, uint256 salt)
        internal
        returns (AdvancedOrder memory)
    {
        return signed(seller, components(startAmount, endAmount, startTime, endTime, salt));
    }

    function signed(Vm.Wallet memory w, OrderComponents memory c) internal returns (AdvancedOrder memory order) {
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

    function components(uint256 startAmount, uint256 endAmount, uint256 startTime, uint256 endTime, uint256 salt)
        internal
        view
        returns (OrderComponents memory c)
    {
        c.offerer = seller.addr;
        c.zone = address(market);
        c.offer = new OfferItem[](1);
        c.offer[0] = OfferItem(ItemType.ERC721, nft, tokenId, 1, 1);
        c.consideration = new ConsiderationItem[](1);
        c.consideration[0] =
            ConsiderationItem(ItemType.ERC20, address(WETH), 0, startAmount, endAmount, payable(seller.addr));
        c.orderType = OrderType.FULL_RESTRICTED;
        c.startTime = startTime;
        c.endTime = endTime;
        c.salt = salt;
        c.conduitKey = OS_CONDUIT_KEY;
        c.counter = SEAPORT.getCounter(seller.addr);
    }

    /// [listing NFT -> bid NFT], [bid WETH -> seller], [bid WETH -> each bid fee].
    function fulfillments() internal view returns (Fulfillment[] memory f) {
        uint256 n = bid().parameters.consideration.length;
        f = new Fulfillment[](n + 1);
        f[0] = pair(0, 0, 1, 0);
        f[1] = pair(1, 0, 0, 0);
        for (uint256 i = 1; i < n; i++) {
            f[i + 1] = pair(1, 0, 1, i);
        }
    }

    function pair(uint256 offerOrder, uint256 offerItem, uint256 considerationOrder, uint256 considerationItem)
        internal
        pure
        returns (Fulfillment memory f)
    {
        f.offerComponents = new FulfillmentComponent[](1);
        f.offerComponents[0] = FulfillmentComponent(offerOrder, offerItem);
        f.considerationComponents = new FulfillmentComponent[](1);
        f.considerationComponents[0] = FulfillmentComponent(considerationOrder, considerationItem);
    }
}
