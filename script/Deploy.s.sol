// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {FeeConfig} from "../actions/FeeConfig.sol";
import {ExchangeAction} from "../actions/ExchangeAction.sol";
import {CoveredNFTPurchase} from "../actions/CoveredNFTPurchase.sol";
import {ReservedAction} from "../actions/ReservedAction.sol";
import {AcquireAndExecute} from "../periphery/AcquireAndExecute.sol";
import {FillVerifier} from "../periphery/FillVerifier.sol";
import {Artwork} from "../examples/Artwork.sol";

/// @notice CREATE2 addresses of the deployable contracts. They depend only on the bytecode, the
/// salt and the standard CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C), so they
/// are the same on every chain.
abstract contract Addresses is Script {
    bytes32 constant SALT = keccak256("market.actions.v1");
    /// @notice First FeeConfig admin: sets the fee rate (at most 1%) and recipient, and can hand
    /// the role on.
    address constant FEE_ADMIN = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    /// @notice First fee recipient; the admin can change it.
    address constant FEE_TO = 0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72;
    /// @notice Artist of the example Artwork.
    address constant ARTIST = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    function _at(bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initCode));
    }

    function market() internal pure returns (Market) {
        return Market(_at(type(Market).creationCode));
    }

    function feeConfig() internal pure returns (FeeConfig) {
        return FeeConfig(_at(abi.encodePacked(type(FeeConfig).creationCode, abi.encode(FEE_ADMIN, FEE_TO))));
    }

    function exchange() internal pure returns (ExchangeAction) {
        return ExchangeAction(
            _at(abi.encodePacked(type(ExchangeAction).creationCode, abi.encode(market(), feeConfig())))
        );
    }

    function covered() internal pure returns (CoveredNFTPurchase) {
        return CoveredNFTPurchase(_at(abi.encodePacked(type(CoveredNFTPurchase).creationCode, abi.encode(market()))));
    }

    function reserved() internal pure returns (ReservedAction) {
        return ReservedAction(_at(abi.encodePacked(type(ReservedAction).creationCode, abi.encode(market()))));
    }

    function acquire() internal pure returns (AcquireAndExecute) {
        return AcquireAndExecute(
            _at(abi.encodePacked(type(AcquireAndExecute).creationCode, abi.encode(market(), exchange(), covered())))
        );
    }

    function fillVerifier() internal pure returns (FillVerifier) {
        return FillVerifier(_at(type(FillVerifier).creationCode));
    }

    function artwork() internal pure returns (Artwork) {
        return Artwork(_at(abi.encodePacked(type(Artwork).creationCode, abi.encode(ARTIST))));
    }
}

/// @notice Deploys Market (which deploys Actions and the Order implementation), FeeConfig,
/// ExchangeAction, CoveredNFTPurchase, ReservedAction, AcquireAndExecute and FillVerifier. Only
/// FeeConfig has an admin. A contract already at its address is skipped, so a partial run
/// resumes and a repeat run sends nothing.
///
///   forge script script/Deploy.s.sol --rpc-url <rpc>                      # simulate
///   forge script script/Deploy.s.sol --sig "examples()" --rpc-url <rpc>   # Artwork example
///
/// Broadcasting adds `--broadcast --verify` and a signer; see docs/DEPLOYMENT.md. Any public
/// broadcast needs the owner's explicit approval.
contract Deploy is Addresses {
    function run() external {
        vm.startBroadcast();
        if (_absent(address(market()))) new Market{salt: SALT}();
        if (_absent(address(feeConfig()))) new FeeConfig{salt: SALT}(FEE_ADMIN, FEE_TO);
        if (_absent(address(exchange()))) new ExchangeAction{salt: SALT}(market(), feeConfig());
        if (_absent(address(covered()))) new CoveredNFTPurchase{salt: SALT}(market());
        if (_absent(address(reserved()))) new ReservedAction{salt: SALT}(market());
        if (_absent(address(acquire()))) new AcquireAndExecute{salt: SALT}(market(), exchange(), covered());
        if (_absent(address(fillVerifier()))) new FillVerifier{salt: SALT}();
        vm.stopBroadcast();

        _log("Market", address(market()));
        _log("Order implementation", market().implementation());
        _log("Actions ERC721", address(market().actions()));
        _log("FeeConfig", address(feeConfig()));
        _log("ExchangeAction", address(exchange()));
        _log("CoveredNFTPurchase", address(covered()));
        _log("ReservedAction", address(reserved()));
        _log("AcquireAndExecute", address(acquire()));
        _log("FillVerifier", address(fillVerifier()));
    }

    function examples() external {
        vm.startBroadcast();
        if (_absent(address(artwork()))) new Artwork{salt: SALT}(ARTIST);
        vm.stopBroadcast();
        _log("Artwork (example)", address(artwork()));
    }

    function _absent(address at) internal view returns (bool) {
        return at.code.length == 0;
    }

    function _log(string memory name, address at) internal view {
        require(at.code.length != 0, name);
        console.log(name, at);
    }
}
