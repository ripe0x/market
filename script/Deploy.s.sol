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
        // `new X{salt: SALT}` goes through the CREATE2 deployer and lets `--verify` find each
        // contract. Each is skipped if its address already has code.
        if (_absent(address(market()))) new Market{salt: SALT}();
        if (_absent(address(nftSale()))) new NFTSale{salt: SALT}();
        if (_absent(address(nftBid()))) new NFTBid{salt: SALT}(market());
        if (_absent(_at(type(FillVerifier).creationCode))) new FillVerifier{salt: SALT}();
        if (_absent(address(paintAction()))) new PaintAction{salt: SALT}();
        if (_absent(_at(type(DutchAuction).creationCode))) new DutchAuction{salt: SALT}();
        if (_absent(_at(type(TokenExchange).creationCode))) new TokenExchange{salt: SALT}();
        if (_absent(_at(type(AcquisitionBid).creationCode))) new AcquisitionBid{salt: SALT}();
        if (_absent(_at(type(RisingStrategy).creationCode))) new RisingStrategy{salt: SALT}();
        if (_absent(_at(type(CapitalShareStrategy).creationCode))) new CapitalShareStrategy{salt: SALT}();
        vm.stopBroadcast();

        _log("Market", address(market()));
        _log("Order implementation", market().implementation());
        _log("NFTSale", address(nftSale()));
        _log("NFTBid", address(nftBid()));
        _log("FillVerifier", _at(type(FillVerifier).creationCode));
        _log("PaintAction", address(paintAction()));
        _log("DutchAuction", _at(type(DutchAuction).creationCode));
        _log("TokenExchange", _at(type(TokenExchange).creationCode));
        _log("AcquisitionBid", _at(type(AcquisitionBid).creationCode));
        _log("RisingStrategy", _at(type(RisingStrategy).creationCode));
        _log("CapitalShareStrategy", _at(type(CapitalShareStrategy).creationCode));
    }

    function _absent(address at) internal view returns (bool) {
        return at.code.length == 0;
    }

    function _log(string memory name, address at) internal view {
        require(at.code.length != 0, name);
        console.log(name, at);
    }
}
