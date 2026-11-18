// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Right} from "./Right.sol";

interface IRightsMarket {
    function isRight(address account) external view returns (bool);
}

/// @notice Canonical ownership of Market-created execution rights. There is no public burn.
contract Rights is ERC721 {
    using Strings for uint256;
    using Strings for address;

    IRightsMarket public immutable market;

    error NotBackingAccount();
    error InvalidTransfer();

    constructor(address market_) ERC721("Market Execution Right", "MRIGHT") {
        market = IRightsMarket(market_);
    }

    function accountOf(uint256 id) public view returns (Right account) {
        if (id > type(uint160).max || !market.isRight(address(uint160(id)))) revert NotBackingAccount();
        return Right(payable(address(uint160(id))));
    }

    function isLive(uint256 id) external view returns (bool) {
        return accountOf(id).isLive();
    }

    /// @notice Generic onchain metadata for a token that still exists. Handler-specific config
    /// is published in Market.RightCreated; this URI never calls a handler or target contract.
    function tokenURI(uint256 id) public view override returns (string memory) {
        ownerOf(id);
        Right account = accountOf(id);
        uint256 end = account.deadline();
        bool expired = end != 0 && block.timestamp >= end;
        // A token exists only in account state Active; passing the deadline does not burn it.
        bytes memory json = abi.encodePacked(
            '{"name":"Market Execution Right #',
            id.toString(),
            '","description":"One-use entitlement to a committed onchain operation through an isolated backing account.",',
            '"account":"',
            address(account).toHexString(),
            '","issuer":"',
            account.issuer().toHexString(),
            '","exerciseHandler":"',
            address(account.handler()).toHexString(),
            '","handlerCodehash":"',
            uint256(account.handlerCodehash()).toHexString(32),
            '","configHash":"',
            uint256(account.configHash()).toHexString(32),
            '","activationTerms":"',
            Strings.toHexString(account.activationTerms()),
            '","deadlinePolicy":"',
            end == 0 ? "perpetual" : "finite-exclusive",
            '","deadline":"',
            end.toString(),
            '","state":"active","effectiveStatus":"',
            expired ? "expired" : account.exercising() ? "executing" : "active",
            '","live":',
            account.isLive() ? "true" : "false",
            ',"residualBeneficiary":"',
            account.residual().toHexString(),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function mint(address issuer, uint256 id) external {
        Right account = accountOf(id);
        if (msg.sender != address(account) || account.state() != Right.State.Active) {
            revert NotBackingAccount();
        }
        _mint(issuer, id);
    }

    function burn(uint256 id) external {
        Right account = accountOf(id);
        if (msg.sender != address(account) || account.state() == Right.State.Active) {
            revert NotBackingAccount();
        }
        _burn(id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        if (from != address(0) && to != address(0)) {
            Right account = accountOf(id);
            if (to == address(account) || !account.isLive()) revert InvalidTransfer();
        }
        return super._update(to, id, auth);
    }
}
