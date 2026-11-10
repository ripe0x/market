// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {PaintAction} from "../examples/PaintAction.sol";

/// @notice CREATE2 addresses of the deployable contracts. They depend only on the bytecode, the
/// salt and the standard CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C), so they
/// are the same on every chain.
abstract contract Addresses is Script {
    bytes32 constant SALT = keccak256("market.v1");

    function _at(bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initCode));
    }

    function market() internal pure returns (Market) {
        return Market(_at(type(Market).creationCode));
    }

    function nftSale() internal pure returns (NFTSale) {
        return NFTSale(_at(abi.encodePacked(type(NFTSale).creationCode, abi.encode(market()))));
    }

    function nftBid() internal pure returns (NFTBid) {
        return NFTBid(_at(abi.encodePacked(type(NFTBid).creationCode, abi.encode(market()))));
    }

    function fillVerifier() internal pure returns (FillVerifier) {
        return FillVerifier(_at(type(FillVerifier).creationCode));
    }

    function paintAction() internal pure returns (PaintAction) {
        return PaintAction(_at(type(PaintAction).creationCode));
    }
}

/// @notice Deploys the supported release: Market (which deploys the one Order implementation),
/// NFTSale, NFTBid and the optional FillVerifier. None has an owner; the NFT handlers take the
/// Market address. A contract already at its address is skipped, so a partial run resumes and
/// a repeat run sends nothing.
///
///   forge script script/Deploy.s.sol --rpc-url <rpc>                      # simulate
///   forge script script/Deploy.s.sol --sig "examples()" --rpc-url <rpc>   # PaintAction example
///
/// Broadcasting adds `--broadcast --verify` and a signer; see docs/DEPLOYMENT.md. Mainnet needs
/// the owner's explicit approval.
contract Deploy is Addresses {
    function run() external {
        vm.startBroadcast();
        if (_absent(address(market()))) new Market{salt: SALT}();
        if (_absent(address(nftSale()))) new NFTSale{salt: SALT}(market());
        if (_absent(address(nftBid()))) new NFTBid{salt: SALT}(market());
        if (_absent(address(fillVerifier()))) new FillVerifier{salt: SALT}();
        vm.stopBroadcast();

        _log("Market", address(market()));
        _log("Order implementation", market().implementation());
        _log("NFTSale", address(nftSale()));
        _log("NFTBid", address(nftBid()));
        _log("FillVerifier", address(fillVerifier()));
    }

    /// @notice The non-trading example handler. Not part of the supported release.
    function examples() external {
        vm.startBroadcast();
        if (_absent(address(paintAction()))) new PaintAction{salt: SALT}();
        vm.stopBroadcast();
        _log("PaintAction (example)", address(paintAction()));
    }

    function _absent(address at) internal view returns (bool) {
        return at.code.length == 0;
    }

    function _log(string memory name, address at) internal view {
        require(at.code.length != 0, name);
        console.log(name, at);
    }
}
