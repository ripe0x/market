// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {AcquisitionBid} from "../examples/AcquisitionBid.sol";
import {CapitalShareStrategy, RisingStrategy} from "../examples/BidStrategies.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";

/// @notice Deploys Market (which deploys the one Order implementation), the optional
/// FillVerifier and the example policies through the standard CREATE2 deployer, so every chain
/// gets the same addresses and anyone can redeploy them. None of these contracts has an owner
/// or constructor arguments.
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
        _log("FillVerifier", address(new FillVerifier{salt: SALT}()));
        _log("DutchAuction", address(new DutchAuction{salt: SALT}()));
        _log("TokenExchange", address(new TokenExchange{salt: SALT}()));
        _log("PaintAction", address(new PaintAction{salt: SALT}()));
        _log("AcquisitionBid", address(new AcquisitionBid{salt: SALT}()));
        _log("RisingStrategy", address(new RisingStrategy{salt: SALT}()));
        _log("CapitalShareStrategy", address(new CapitalShareStrategy{salt: SALT}()));
        vm.stopBroadcast();
    }

    function _log(string memory name, address at) internal view {
        require(at.code.length != 0, "not deployed");
        console.log(name, at);
    }
}
