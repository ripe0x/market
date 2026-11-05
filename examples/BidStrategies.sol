// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBidStrategy} from "./AcquisitionBid.sol";

/// @notice Rises linearly with time. Before the first acquisition it starts at `startPrice` at
/// `startTime`. After each one it restarts at `resetBps` of the clearing price.
contract RisingStrategy is IBidStrategy {
    struct Params {
        uint256 startPrice;
        uint256 startTime;
        uint256 perSecond;
        uint256 resetBps;
    }

    function quote(uint256 lastPrice, uint256 lastTime, uint256 count, uint256, bytes calldata params)
        external
        view
        returns (uint256)
    {
        Params memory p = abi.decode(params, (Params));
        (uint256 base, uint256 from) =
            count == 0 ? (p.startPrice, p.startTime) : (lastPrice * p.resetBps / 10_000, lastTime);
        return block.timestamp <= from ? base : base + p.perSecond * (block.timestamp - from);
    }
}

/// @notice Bids a fixed share of whatever capital is available, independent of time and history.
/// Params: `abi.encode(uint256 shareBps)`.
contract CapitalShareStrategy is IBidStrategy {
    function quote(uint256, uint256, uint256, uint256 capital, bytes calldata params)
        external
        pure
        returns (uint256)
    {
        return capital * abi.decode(params, (uint256)) / 10_000;
    }
}
