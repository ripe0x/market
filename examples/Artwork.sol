// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title Artwork
/// @notice Example 3's artwork, independent of Market. Each token has a color. Its owner may
/// paint it, and may name one painter who can paint it too. A painter can resign, and any
/// transfer of the token removes its painter.
contract Artwork is ERC721 {
    address public immutable artist;
    mapping(uint256 tokenId => uint8) public colorOf;
    mapping(uint256 tokenId => address) public painterOf;

    event Painted(uint256 indexed tokenId, uint8 color, address indexed by);
    event PainterSet(uint256 indexed tokenId, address indexed painter);

    error NotAllowed();

    constructor() ERC721("Artwork", "ART") {
        artist = msg.sender;
    }

    function mint(address to, uint256 tokenId) external {
        if (msg.sender != artist) revert NotAllowed();
        _mint(to, tokenId);
    }

    function setPainter(uint256 tokenId, address painter) external {
        if (msg.sender != ownerOf(tokenId)) revert NotAllowed();
        painterOf[tokenId] = painter;
        emit PainterSet(tokenId, painter);
    }

    function resign(uint256 tokenId) external {
        if (msg.sender != painterOf[tokenId]) revert NotAllowed();
        delete painterOf[tokenId];
        emit PainterSet(tokenId, address(0));
    }

    function paint(uint256 tokenId, uint8 color) external {
        if (msg.sender != ownerOf(tokenId) && msg.sender != painterOf[tokenId]) revert NotAllowed();
        colorOf[tokenId] = color;
        emit Painted(tokenId, color, msg.sender);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        delete painterOf[tokenId];
        return super._update(to, tokenId, auth);
    }
}
