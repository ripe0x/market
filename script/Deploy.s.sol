// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../contracts/Market.sol";

/// Dry run (no --broadcast) simulates against the given RPC:
///   PROTOCOL_FEE_RECIPIENT=0x... forge script script/Deploy.s.sol --rpc-url mainnet
/// Broadcasting to mainnet requires explicit owner authorization; see docs/OPERATIONS.md.
contract Deploy is Script {
    function run() external returns (Market market) {
        address recipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        require(recipient != address(0), "recipient");
        require(block.chainid == 1 || block.chainid == 31337, "mainnet or local fork only");

        vm.startBroadcast();
        market = new Market(recipient);
        vm.stopBroadcast();

        require(address(market.SEAPORT()).code.length > 0, "Seaport 1.6 missing");
        require(market.PROTOCOL_FEE_RECIPIENT() == recipient, "recipient mismatch");
        console.log("Market", address(market));
        console.log("protocol fee recipient", recipient);
    }
}
