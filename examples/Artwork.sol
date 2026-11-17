// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Right} from "../src/Right.sol";

/// @title Artwork
/// @notice Example 3's artwork, independent of Market. Each token has a color. Its owner may
/// paint it, and may name one painter who can paint it too. A painter can resign, and any
/// transfer of the token removes its painter. A separately reserved one-use repaint survives
/// transfer and can be consumed only through its live Market right.
contract Artwork is ERC721 {
    struct Reservation {
        address right;
        uint256 allowedColors;
    }

    address public immutable artist;
    mapping(uint256 tokenId => uint8) public colorOf;
    mapping(uint256 tokenId => address) public painterOf;
    mapping(uint256 tokenId => Reservation) public reservation;

    event Painted(uint256 indexed tokenId, uint8 color, address indexed by);
    event PainterSet(uint256 indexed tokenId, address indexed painter);
    event Reserved(uint256 indexed tokenId, address indexed right, uint256 allowedColors);

    error NotAllowed();
    error ReservationLive();

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

    /// @notice Reserve one allowed repaint for a genuine pending right. A live reservation
    /// survives ownership transfer and cannot be replaced by the artwork owner.
    function reserve(uint256 tokenId, Right right, uint256 allowedColors) external {
        if (msg.sender != ownerOf(tokenId) || allowedColors == 0) revert NotAllowed();
        Reservation memory old = reservation[tokenId];
        if (_live(old.right)) revert ReservationLive();
        if (!right.market().isRight(address(right)) || right.state() != Right.State.Pending) revert NotAllowed();
        reservation[tokenId] = Reservation(address(right), allowedColors);
        emit Reserved(tokenId, address(right), allowedColors);
    }

    /// @notice Only the executing right can use its reservation. It is consumed before the
    /// color changes. The owner can still paint normally; no permanent visual state is promised.
    function paintReserved(uint256 tokenId, uint8 color) external {
        Reservation memory r = reservation[tokenId];
        if (msg.sender != r.right || !_live(r.right) || !Right(payable(r.right)).exercising()) revert NotAllowed();
        if ((r.allowedColors >> color) & 1 == 0) revert NotAllowed();
        delete reservation[tokenId];
        colorOf[tokenId] = color;
        emit Painted(tokenId, color, msg.sender);
    }

    function _live(address account) private view returns (bool) {
        if (account == address(0)) return false;
        Right right = Right(payable(account));
        uint256 deadline = right.deadline();
        return right.state() == Right.State.Active && (deadline == 0 || block.timestamp < deadline);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        delete painterOf[tokenId];
        return super._update(to, tokenId, auth);
    }
}
