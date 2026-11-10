// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";

/// @notice Deploys Market (which deploys the one Order implementation), the NFT handlers and
/// the optional FillVerifier through the standard CREATE2 deployer, so every chain gets the
/// same addresses and anyone can redeploy them. None of these contracts has an owner; the
/// handlers take the Market address.
///
/// Dry run (simulation only, nothing is sent):
///   forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co
/// A real deployment adds `--broadcast` and a signer, and needs the owner's explicit approval.
contract Deploy is Script {
    bytes32 constant SALT = keccak256("market.v1");

    function run() external {
        vm.startBroadcast();
        Market market = new Market{salt: SALT}();
        _log("Market", address(market));
        _log("Order implementation", market.implementation());
        _log("NFTSale", address(new NFTSale{salt: SALT}(market)));
        _log("NFTBid", address(new NFTBid{salt: SALT}(market)));
        _log("FillVerifier", address(new FillVerifier{salt: SALT}()));
        vm.stopBroadcast();
    }

    function _log(string memory name, address at) internal view {
        require(at.code.length != 0, "not deployed");
        console.log(name, at);
    }
}
