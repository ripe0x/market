// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/// Ordinary ERC721 anyone can mint, for tests.
contract TestNFT is ERC721 {
    constructor() ERC721("Test", "TEST") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// ERC721 with a settable ERC2981 royalty.
contract RoyaltyNFT is ERC721, ERC2981 {
    constructor() ERC721("Royalty", "ROY") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRoyalty(address to, uint96 bps) external {
        _setDefaultRoyalty(to, bps);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}

/// Reports ERC2981 but its royaltyInfo reverts.
contract BrokenRoyaltyNFT is TestNFT {
    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0x2a55205a || super.supportsInterface(id);
    }

    function royaltyInfo(uint256, uint256) external pure returns (address, uint256) {
        revert("royalty broken");
    }
}

/// Refuses ETH.
contract Rejecter {}
