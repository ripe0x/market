// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";
import {Rights} from "../src/Rights.sol";
import {CoveredNFTPurchase} from "../handlers/CoveredNFTPurchase.sol";
import {RoyaltyNFT} from "./utils/Mocks.sol";

contract MetadataCallbackNFT is RoyaltyNFT {
    Rights public rights;
    uint256 public rightId;
    string public observed;

    function arm(Rights collection, uint256 id) external {
        rights = collection;
        rightId = id;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        super.transferFrom(from, to, id);
        if (address(rights) != address(0)) observed = rights.tokenURI(rightId);
    }
}

contract RightsMetadataTest is Test {
    Market market;
    Rights rights;
    CoveredNFTPurchase purchase;
    RoyaltyNFT nft;
    address issuer = makeAddr("issuer");
    address buyer = makeAddr("buyer");
    address royalty = makeAddr("royalty");
    uint256 nextId;

    function setUp() public {
        vm.warp(1_000_000);
        market = new Market();
        rights = market.rights();
        purchase = new CoveredNFTPurchase(market);
        nft = new RoyaltyNFT();
        nft.setRoyalty(royalty, 500);
        vm.deal(buyer, 2 ether);
    }

    function _create(uint256 deadline) private returns (Right right, bytes memory config) {
        uint256 id = ++nextId;
        nft.mint(issuer, id);
        config = abi.encode(CoveredNFTPurchase.Config(nft, id, 1 ether, issuer, 500));
        vm.prank(issuer);
        right = market.createRight(purchase, config, deadline, issuer, bytes32(id));
    }

    function _activate(Right right, bytes memory config) private {
        vm.prank(issuer);
        nft.transferFrom(issuer, address(right), nextId);
        vm.prank(issuer);
        right.activate(config);
    }

    function _json(uint256 id) private view returns (string memory) {
        return _decode(rights.tokenURI(id));
    }

    function _decode(string memory uri) private pure returns (string memory) {
        bytes memory full = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(full.length, prefix.length);
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(full[i], prefix[i]);
        }
        bytes memory payload = new bytes(full.length - prefix.length);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = full[i + prefix.length];
        }
        return string(Base64.decode(string(payload)));
    }

    function _string(string memory json, string memory key) private pure returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    function _bool(string memory json, string memory key) private pure returns (bool) {
        return vm.parseJsonBool(json, key);
    }

    function test_finiteMetadataAndExpiryBeforeFinalization() public {
        uint256 deadline = block.timestamp + 7 days;
        (Right right, bytes memory config) = _create(deadline);
        uint256 id = right.tokenId();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        rights.tokenURI(id);
        _activate(right, config);

        string memory json = _json(id); // parseJson also checks JSON syntax.
        assertEq(_string(json, ".account"), Strings.toHexString(address(right)));
        assertEq(_string(json, ".issuer"), Strings.toHexString(issuer));
        assertEq(_string(json, ".exerciseHandler"), Strings.toHexString(address(purchase)));
        assertEq(_string(json, ".handlerCodehash"), Strings.toHexString(uint256(right.handlerCodehash()), 32));
        assertEq(_string(json, ".configHash"), Strings.toHexString(uint256(keccak256(config)), 32));
        assertEq(_string(json, ".activationTerms"), Strings.toHexString(abi.encode(royalty, 0.05 ether)));
        assertEq(_string(json, ".residualBeneficiary"), Strings.toHexString(issuer));
        assertEq(_string(json, ".deadlinePolicy"), "finite-exclusive");
        assertEq(vm.parseJsonString(json, ".deadline"), Strings.toString(deadline));
        assertEq(_string(json, ".state"), "active");
        assertEq(_string(json, ".effectiveStatus"), "active");
        assertTrue(_bool(json, ".live"));

        vm.warp(deadline);
        assertEq(rights.ownerOf(id), issuer); // token still exists until anyone finalizes.
        json = _json(id);
        assertEq(_string(json, ".state"), "active");
        assertEq(_string(json, ".effectiveStatus"), "expired");
        assertFalse(_bool(json, ".live"));
        right.finalizeExpiry();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        rights.tokenURI(id);
    }

    function test_perpetualMetadataAndTransferThenExercise() public {
        (Right right, bytes memory config) = _create(0);
        _activate(right, config);
        uint256 id = right.tokenId();
        string memory json = _json(id);
        assertEq(_string(json, ".deadlinePolicy"), "perpetual");
        assertEq(vm.parseJsonString(json, ".deadline"), "0");
        vm.warp(365 days * 100);
        assertTrue(_bool(_json(id), ".live"));

        string memory beforeTransfer = rights.tokenURI(id);
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        assertEq(rights.tokenURI(id), beforeTransfer);
        vm.prank(issuer);
        vm.expectRevert(Right.Unauthorized.selector);
        right.exercise(config, abi.encode(issuer));
        vm.prank(buyer);
        right.exercise{value: 1 ether}(config, abi.encode(buyer));
        assertEq(nft.ownerOf(nextId), buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        rights.tokenURI(id);
    }

    function test_uint256DeadlineIsExactAndCallbackShowsExecutionLock() public {
        uint256 deadline = 9_007_199_254_740_993;
        MetadataCallbackNFT target = new MetadataCallbackNFT();
        target.mint(issuer, 1);
        bytes memory config = abi.encode(CoveredNFTPurchase.Config(target, 1, 1 ether, issuer, 0));
        vm.prank(issuer);
        Right account = market.createRight(purchase, config, deadline, issuer, bytes32(uint256(99)));
        vm.prank(issuer);
        target.transferFrom(issuer, address(account), 1);
        vm.prank(issuer);
        account.activate(config);
        uint256 id = account.tokenId();
        assertEq(vm.parseJsonString(_json(id), ".deadline"), "9007199254740993");
        target.arm(rights, id);
        vm.prank(issuer);
        rights.transferFrom(issuer, buyer, id);
        vm.prank(buyer);
        account.exercise{value: 1 ether}(config, abi.encode(buyer));
        string memory observed = _decode(target.observed());
        assertEq(vm.parseJsonString(observed, ".effectiveStatus"), "executing");
        assertFalse(vm.parseJsonBool(observed, ".live"));
    }
}

/// @notice Direct CREATE avoids Foundry's vm.deployCode shortcut for `new` in test functions.
contract RightsMetadataGasTest is Test {
    function test_marketDeploymentGas() public {
        bytes memory code = vm.getCode("src/Market.sol:Market");
        uint256 beforeGas = gasleft();
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 0x20), mload(code)) }
        uint256 used = beforeGas - gasleft();
        require(deployed != address(0), "Market deployment failed");
        Market deployedMarket = Market(deployed);
        assertTrue(address(deployedMarket.rights()).code.length != 0);
        emit log_named_uint("Market deployment gas", used);
    }

    function test_rightsDeploymentGas() public {
        bytes memory code = abi.encodePacked(vm.getCode("src/Rights.sol:Rights"), abi.encode(address(this)));
        uint256 beforeGas = gasleft();
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 0x20), mload(code)) }
        uint256 used = beforeGas - gasleft();
        require(deployed != address(0), "Rights deployment failed");
        Rights deployedRights = Rights(deployed);
        assertTrue(address(deployedRights).code.length != 0);
        emit log_named_uint("Rights deployment gas", used);
    }
}
