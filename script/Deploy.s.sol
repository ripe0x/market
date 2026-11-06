// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {NFTBid} from "../handlers/NFTBid.sol";
import {NFTSale} from "../handlers/NFTSale.sol";
import {AcquisitionBid} from "../examples/AcquisitionBid.sol";
import {CapitalShareStrategy, RisingStrategy} from "../examples/BidStrategies.sol";
import {DutchAuction} from "../examples/DutchAuction.sol";
import {PaintAction} from "../examples/PaintAction.sol";
import {TokenExchange} from "../examples/TokenExchange.sol";

/// @notice CREATE2 addresses of every deployed contract. They depend only on the code, the
/// salt and the standard CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C), so
/// they are the same on every chain.
abstract contract Addresses is Script {
    bytes32 constant SALT = keccak256("market.v1");

    function _at(bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initCode));
    }

    function market() internal pure returns (Market) {
        return Market(_at(type(Market).creationCode));
    }

    function nftSale() internal pure returns (NFTSale) {
        return NFTSale(payable(_at(type(NFTSale).creationCode)));
    }

    function nftBid() internal pure returns (NFTBid) {
        return NFTBid(payable(_at(abi.encodePacked(type(NFTBid).creationCode, abi.encode(market())))));
    }

    function paintAction() internal pure returns (PaintAction) {
        return PaintAction(_at(type(PaintAction).creationCode));
    }
}

/// @notice Deploys Market (which deploys the one Order implementation), the reference NFT
/// handlers, the optional FillVerifier and the example handlers. None has an owner; only
/// NFTBid takes a constructor argument, the Market address. Contracts already at their
/// address are skipped, so a partial run can be resumed.
///
/// Simulation (nothing is sent):
///   forge script script/Deploy.s.sol --rpc-url <rpc>
/// Deployment adds `--broadcast --verify` and a signer; see docs/DEPLOYMENT.md. Mainnet needs
/// the owner's explicit approval.
contract Deploy is Addresses {
    function run() external {
        vm.startBroadcast();
        _deploy("Market", type(Market).creationCode);
        console.log("Order implementation", market().implementation());
        _deploy("NFTSale", type(NFTSale).creationCode);
        _deploy("NFTBid", abi.encodePacked(type(NFTBid).creationCode, abi.encode(market())));
        _deploy("FillVerifier", type(FillVerifier).creationCode);
        _deploy("PaintAction", type(PaintAction).creationCode);
        _deploy("DutchAuction", type(DutchAuction).creationCode);
        _deploy("TokenExchange", type(TokenExchange).creationCode);
        _deploy("AcquisitionBid", type(AcquisitionBid).creationCode);
        _deploy("RisingStrategy", type(RisingStrategy).creationCode);
        _deploy("CapitalShareStrategy", type(CapitalShareStrategy).creationCode);
        vm.stopBroadcast();
        require(market().implementation().code.length != 0, "no implementation");
    }

    function _deploy(string memory name, bytes memory initCode) internal {
        address at = _at(initCode);
        if (at.code.length == 0) {
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(SALT, initCode));
            require(ok && at.code.length != 0, name);
        }
        console.log(name, at);
    }
}
