// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "../src/Market.sol";
import {IExerciseHandler, Right} from "../src/Right.sol";
import {Artwork} from "./Artwork.sol";

/// @notice Exercises a target-enforced reservation for one allowed artwork modification.
/// The artwork owner still owns the artwork and may repaint it later.
contract ReservedPaint is IExerciseHandler {
    struct Config {
        Artwork art;
        uint256 tokenId;
        uint256 allowedColors;
    }

    Market public immutable market;

    error NotRight();
    error NotExercising();
    error NoReservation();
    error ColorNotAllowed(uint8 color);
    error UnexpectedETH();
    error NotPainted();

    constructor(Market market_) {
        market = market_;
    }

    function validate(address account, bytes calldata config) external view returns (bytes memory) {
        if (
            !market.isRight(account) || msg.sender != account
                || address(Right(payable(account)).handler()) != address(this)
        ) {
            revert NotRight();
        }
        Config memory c = abi.decode(config, (Config));
        (address reservedRight, uint256 colors) = c.art.reservation(c.tokenId);
        if (c.allowedColors == 0 || reservedRight != account || colors != c.allowedColors) revert NoReservation();
        c.art.ownerOf(c.tokenId);
        return "";
    }

    function onExercise(address, uint256 value, bytes calldata config, bytes calldata, bytes calldata input)
        external
        returns (bytes memory)
    {
        Right right = Right(payable(msg.sender));
        if (!market.isRight(msg.sender) || address(right.handler()) != address(this)) revert NotRight();
        if (!right.exercising()) revert NotExercising();
        if (value != 0) revert UnexpectedETH();
        Config memory c = abi.decode(config, (Config));
        uint8 color = abi.decode(input, (uint8));
        if ((c.allowedColors >> color) & 1 == 0) revert ColorNotAllowed(color);
        right.execute(address(c.art), 0, abi.encodeCall(Artwork.paintReserved, (c.tokenId, color)));
        (address reservedRight,) = c.art.reservation(c.tokenId);
        if (reservedRight != address(0) || c.art.colorOf(c.tokenId) != color) revert NotPainted();
        return "";
    }
}
