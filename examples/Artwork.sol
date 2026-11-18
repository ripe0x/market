// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Market} from "../src/Market.sol";
import {Right} from "../src/Right.sol";

/// @title Artwork
/// @notice Each token has a color. Its owner may paint it or assign a revocable painter.
/// Transfer clears the painter. A one-use repaint reservation survives transfer and can be
/// consumed during its right's exercise. The configured immutable Market authenticates a
/// candidate reservation account before any account getters are called.
contract Artwork is ERC721 {
    struct Reservation {
        address right;
        uint256 allowedColors;
    }

    address public immutable artist;
    Market public immutable market;
    mapping(uint256 tokenId => uint8) public colorOf;
    mapping(uint256 tokenId => address) public painterOf;
    mapping(uint256 tokenId => Reservation) public reservation;

    event Painted(uint256 indexed tokenId, uint8 color, address indexed by);
    event PainterSet(uint256 indexed tokenId, address indexed painter);
    event Reserved(uint256 indexed tokenId, address indexed right, uint256 allowedColors);

    error NotAllowed();
    error ReservationLive();

    constructor(Market market_) ERC721("Artwork", "ART") {
        artist = msg.sender;
        market = market_;
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
        if (!market.isRight(address(right)) || right.state() != Right.State.Pending) revert NotAllowed();
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

    /// @dev An active, unexpired reservation remains live during exercise, when Right.isLive
    /// returns false. This permits paintReserved to consume the reservation under its lock.
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
