// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReservedActionTarget} from "../reservations/ReservedActionTarget.sol";

/// @title Artwork
/// @notice Example reservation target. Each token has a palette color and a renderer, each
/// chosen from 256 options. The token owner may change either directly, and may reserve one
/// future change of either for an executor address: the operation fixes the allowed options as
/// a bitmask, and the executor picks one when it performs. Reservations survive transfer. A
/// token with a live reservation cannot be burned. Reservations do not stop the owner's own
/// later changes. ETH paid with a reserved change accrues to the artist.
contract Artwork is ERC721, ReservedActionTarget {
    uint8 public constant PALETTE = 0;
    uint8 public constant RENDERER = 1;

    address public immutable artist;
    mapping(uint256 tokenId => uint8) public colorOf;
    mapping(uint256 tokenId => uint8) public rendererOf;

    event Changed(uint256 indexed tokenId, uint8 indexed kind, uint8 choice, address indexed by);

    error NotAllowed();
    error ChoiceNotAllowed(uint8 choice);

    constructor(address artist_) ERC721("Artwork", "ART") {
        artist = artist_;
    }

    function mint(address to, uint256 tokenId) external {
        if (msg.sender != artist) revert NotAllowed();
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external {
        if (msg.sender != ownerOf(tokenId)) revert NotAllowed();
        if (isScopeReserved(scopeOf(tokenId, PALETTE)) || isScopeReserved(scopeOf(tokenId, RENDERER))) {
            revert ScopeReserved();
        }
        _burn(tokenId);
    }

    function change(uint256 tokenId, uint8 kind, uint8 choice) external {
        if (msg.sender != ownerOf(tokenId)) revert NotAllowed();
        _set(tokenId, kind, choice);
    }

    /// @notice The token owner grants `executor` one change of `kind` among `allowed` options.
    function reserve(address executor, uint256 tokenId, uint8 kind, uint256 allowed, uint64 deadline, uint256 value)
        external
    {
        if (msg.sender != ownerOf(tokenId) || kind > RENDERER || allowed == 0) revert NotAllowed();
        _reserve(executor, scopeOf(tokenId, kind), operation(tokenId, kind, allowed), deadline, value);
    }

    function operation(uint256 tokenId, uint8 kind, uint256 allowed) public pure returns (bytes memory) {
        return abi.encode(tokenId, kind, allowed);
    }

    function scopeOf(uint256 tokenId, uint8 kind) public pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, kind));
    }

    function withdraw() external {
        (bool ok,) = artist.call{value: address(this).balance}("");
        if (!ok) revert NotAllowed();
    }

    /// @param input abi.encode(uint8 choice)
    function _perform(bytes calldata op, bytes calldata input) internal override returns (bytes memory) {
        (uint256 tokenId, uint8 kind, uint256 allowed) = abi.decode(op, (uint256, uint8, uint256));
        uint8 choice = abi.decode(input, (uint8));
        if ((allowed >> choice) & 1 == 0) revert ChoiceNotAllowed(choice);
        _requireOwned(tokenId);
        _set(tokenId, kind, choice);
        return abi.encode(choice);
    }

    function _set(uint256 tokenId, uint8 kind, uint8 choice) private {
        if (kind == PALETTE) colorOf[tokenId] = choice;
        else if (kind == RENDERER) rendererOf[tokenId] = choice;
        else revert NotAllowed();
        emit Changed(tokenId, kind, choice, msg.sender);
    }
}
