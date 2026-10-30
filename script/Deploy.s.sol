// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../contracts/Market.sol";

/// Dry run (no --broadcast) simulates against the given RPC:
///   PROTOCOL_FEE_RECIPIENT=0x... MARKET_OWNER=0x... forge script script/Deploy.s.sol --rpc-url mainnet
/// Broadcasting to mainnet requires explicit owner authorization; see docs/OPERATIONS.md.
contract Deploy is Script {
    /// OpenSea SignedZone used by OpenSea offers on Seaport 1.6.
    address constant OPENSEA_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;

    function run() external returns (Market market) {
        address recipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address owner = vm.envAddress("MARKET_OWNER");
        require(recipient != address(0), "recipient");
        require(block.chainid == 1 || block.chainid == 31337, "mainnet or local fork only");
        require(OPENSEA_ZONE.code.length > 0, "OpenSea zone missing");

        vm.startBroadcast();
        market = new Market(recipient, owner, OPENSEA_ZONE);
        vm.stopBroadcast();

        require(address(market.SEAPORT()).code.length > 0, "Seaport 1.6 missing");
        require(market.PROTOCOL_FEE_RECIPIENT() == recipient, "recipient mismatch");
        require(market.owner() == owner && market.zones(OPENSEA_ZONE), "config mismatch");
        console.log("Market", address(market));
        console.log("protocol fee recipient", recipient);
        console.log("owner (currencies and zones only)", owner);
    }
}
