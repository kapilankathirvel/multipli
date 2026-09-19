// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice One price observation. `price` and `conf` are USD per token in WAD (1e18).
struct Observation {
    uint256 price;
    uint256 conf;
    uint64 updatedAt;
    bool ok;
}

/// @notice Shared boundary between price sources (Kapilan: Chainlink/Mock; Varun: Pyth) and the aggregator (Kapilan).
/// @dev RULE: `observe()` must NEVER revert. Wrap external calls in try/catch and return ok = false.
///      Staleness is decided by the aggregator (per-source maxAge), not by the source.
interface IPriceSource {
    function observe() external view returns (Observation memory);
    function sourceName() external view returns (string memory);
}

/// @notice Bounded executors called by the RiskController (both implemented by Kapilan).
interface ILineExecutor {
    function setLine(bytes32 ilk, uint256 lineRad) external;
    function cap(bytes32 ilk) external view returns (uint256);
}

interface IHoleExecutor {
    function setHole(bytes32 ilk, uint256 holeRad) external;
    function cap(bytes32 ilk) external view returns (uint256);
}

/// @notice Market-hours calendar implemented by Varun, read by the RiskController.
interface ISessionCalendar {
    function isOpen(bytes32 asset, uint256 ts) external view returns (bool);
}
