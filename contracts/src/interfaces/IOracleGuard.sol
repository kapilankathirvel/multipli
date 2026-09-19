// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Observation} from "./IPriceSource.sol";

// =====================================================================================
//  FROZEN INTERFACES: the contract between Kapilan (implements), Jeffrey (dashboard reads)
//  and Varun (scripts). Do NOT change without telling the whole team.
//  Kapilan's contracts MUST inherit these (e.g. `contract SmartOSM is ISmartOSM`).
//  ABIs are exported to /abi/*.json for the dashboard (no Foundry needed there).
// =====================================================================================

struct Reading {
    uint256 mid; // weighted median of inliers (WAD, USD per token)
    uint256 lo; // min inlier price (WAD)
    uint256 hi; // max inlier price (WAD)
    uint16 score; // 0..100
    uint8 nFresh; // sources ok && fresh
    uint8 nInliers; // sources that survived outlier rejection
    uint64 freshestAge; // seconds
    bool ok; // nInliers >= quorumMin
}

interface IOracleGuardAggregator {
    function read() external view returns (Reading memory);
    /// @dev Per-source detail for the UI, same order as `sourceCount`.
    function observations() external view returns (Observation[] memory obs, bool[] memory fresh, bool[] memory inlier);
    function sourceCount() external view returns (uint256);
    function sourceAt(uint256 i) external view returns (address src, uint16 weight, uint32 maxAge);
}

interface ISmartOSM {
    // SmartOSM.Status: 0 UNINIT, 1 LIVE, 2 STALE, 3 QUARANTINED, 4 STOPPED
    event Init(uint256 price);
    event Poke(bytes32 val, uint256 age);
    event PokeSkipped(uint8 reason, uint16 score);
    event Quarantined(uint256 candidate, uint256 nxt, uint16 score);

    // Maker OSM-compatible surface (subset used by the team)
    function poke() external;
    function pass() external view returns (bool);
    function hop() external view returns (uint16);
    function zzz() external view returns (uint64);
    function peek() external view returns (bytes32, bool); // toll-gated
    function kiss(address) external;
    function bud(address) external view returns (uint256);

    // OracleGuard extensions (NOT toll-gated, safe for the UI)
    function price() external view returns (uint256 curWad, uint256 nxtWad, uint64 lastGoodAt);
    function status() external view returns (uint8);
    function age() external view returns (uint256);
    function lastReading() external view returns (Reading memory);
}

interface IRiskController {
    // State: 0 GREEN, 1 YELLOW, 2 RED
    event StateChanged(bytes32 indexed ilk, uint8 from, uint8 to);
    event GuardOn(bytes32 indexed ilk);
    event GuardOff(bytes32 indexed ilk, bool expired);
    event Synced(bytes32 indexed ilk, uint8 state, uint16 score, uint256 mid, uint256 osmCur, uint256 lineRad, bool guard);

    function sync(bytes32 ilk) external;
    function status(bytes32 ilk)
        external
        view
        returns (uint8 state, uint16 score, bool guard, uint256 lineRad, uint256 debtRad);
}

/// @notice Scenario-controllable source used in the demo (Pyth / RedStone / DEX TWAP stand-ins).
interface IMockSource {
    event MockSet(uint256 price, uint256 conf, uint64 updatedAt, bool ok);

    function set(uint256 price, uint256 conf, uint64 updatedAt, bool ok) external;
    function setPrice(uint256 price) external; // updatedAt = now, ok = true
    function setOk(bool ok) external;
}
