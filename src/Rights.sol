// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Right} from "./Right.sol";

interface IRightsMarket {
    function isRight(address account) external view returns (bool);
}

/// @notice Canonical ownership of Market-created execution rights. There is no public burn.
contract Rights is ERC721 {
    IRightsMarket public immutable market;
    mapping(uint256 tokenId => bool) public everMinted;

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

    function mint(address issuer, uint256 id) external {
        Right account = accountOf(id);
        if (msg.sender != address(account) || account.state() != Right.State.Active || everMinted[id]) {
            revert NotBackingAccount();
        }
        everMinted[id] = true;
        _mint(issuer, id);
    }

    function burn(uint256 id) external {
        Right account = accountOf(id);
        if (msg.sender != address(account) || account.state() == Right.State.Active || !everMinted[id]) {
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
