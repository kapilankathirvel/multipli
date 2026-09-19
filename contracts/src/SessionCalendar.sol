// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISessionCalendar} from "./interfaces/IPriceSource.sol";
import {Auth} from "./utils/Auth.sol";

/// @title SessionCalendar
/// @notice On-chain market-hours calendar for real-world assets (gold, equities).
///         Used by the RiskController to stay in YELLOW (not RED) when oracles are
///         legitimately quiet because the underlying market is closed.
///
/// @dev Week mask encoding:
///   - The week has 168 hours (7 days × 24 h).
///   - Bit h (0-indexed, LSB = h0) is SET when the market is OPEN during hour h.
///   - Hour-of-week alignment:  h = ((ts / 3600) + 72) % 168
///     +72 shifts the Unix epoch (Thursday 00:00 UTC, 1970-01-01) so that
///     h = 0 corresponds to Monday 00:00 UTC.
///     Example: Monday 00:00 UTC  → h = 0  (bit 0)
///              Monday 14:00 UTC  → h = 14 (bit 14)
///              Friday  21:00 UTC → h = 4*24+21 = 117 → bit 117 set means 21:00 is open
///     NYSE sessions run Mon–Fri 09:30–16:00 EST = 14:30–21:00 UTC.
///     For simplicity `nyseMask()` uses 14:00–21:00 UTC (rounded hours).
///
/// @dev holiday encoding:
///   - `holiday[asset][ts / 1 days]` = true means that calendar day is closed
///     regardless of the weekMask.
///
/// @dev alwaysOpen:
///   - When set, `isOpen` returns true for every timestamp (crypto assets, early MVP).
contract SessionCalendar is ISessionCalendar, Auth {
    // ---------------------------------------------------------------- state

    /// @notice 168-bit week mask per asset. Bit h = 1 → market open at hour h of the week.
    mapping(bytes32 => uint256) public weekMask;

    /// @notice Day-level holiday overrides.  dayIdx = ts / 1 days.
    mapping(bytes32 => mapping(uint256 => bool)) public holiday;

    /// @notice If true, isOpen always returns true (e.g. PAXG in the MVP).
    mapping(bytes32 => bool) public alwaysOpen;

    // ---------------------------------------------------------------- events

    event WeekMaskSet(bytes32 indexed asset, uint256 mask);
    event HolidaySet(bytes32 indexed asset, uint256 dayIdx, bool closed);
    event AlwaysOpenSet(bytes32 indexed asset, bool value);

    // ---------------------------------------------------------------- admin

    /// @notice Set the 168-bit weekly open-hours mask for an asset.
    function setWeekMask(bytes32 asset, uint256 mask) external auth {
        weekMask[asset] = mask;
        emit WeekMaskSet(asset, mask);
    }

    /// @notice Mark or unmark a specific calendar day as a holiday (closed).
    /// @param dayIdx  Unix timestamp divided by 1 days (i.e. ts / 86400).
    function setHoliday(bytes32 asset, uint256 dayIdx, bool closed) external auth {
        holiday[asset][dayIdx] = closed;
        emit HolidaySet(asset, dayIdx, closed);
    }

    /// @notice When true, the asset is treated as always open (crypto behaviour).
    function setAlwaysOpen(bytes32 asset, bool value) external auth {
        alwaysOpen[asset] = value;
        emit AlwaysOpenSet(asset, value);
    }

    // ---------------------------------------------------------------- view

    /// @inheritdoc ISessionCalendar
    /// @notice Returns true if the market for `asset` is open at timestamp `ts`.
    ///
    ///   Decision order:
    ///   1. alwaysOpen → true
    ///   2. holiday closed → false
    ///   3. weekMask bit check → open iff the bit for hourOfWeek(ts) is set
    ///      (if weekMask is 0 — never configured — also returns false)
    function isOpen(bytes32 asset, uint256 ts) public view returns (bool) {
        // 1. Always-open assets (e.g. PAXG treated as 24/7 in MVP)
        if (alwaysOpen[asset]) return true;

        // 2. Holiday override (closed regardless of session)
        uint256 dayIdx = ts / 1 days;
        if (holiday[asset][dayIdx]) return false;

        // 3. Weekly session mask
        //    hourOfWeek = ((ts / 3600) + 72) % 168
        //    Unix epoch is Thursday 00:00 UTC; +72 hours shifts it to Monday 00:00 UTC.
        uint256 hourOfWeek = ((ts / 3600) + 72) % 168;
        return (weekMask[asset] >> hourOfWeek) & 1 == 1;
    }

    // ---------------------------------------------------------------- pure helper

    /// @notice Returns the 168-bit mask for NYSE-like hours: Mon–Fri 14:00–20:59 UTC.
    ///         (NYSE opens 09:30 EST = 14:30 UTC; closes 16:00 EST = 21:00 UTC.
    ///          We use rounded hours: open bit h means the HOUR starting at h:00 is open.
    ///          So bits 14–20 on Mon–Fri are set = hours 14:00, 15:00 ... 20:00 start open.)
    /// @dev Purely computational; does not read storage.
    function nyseMask() public pure returns (uint256 mask) {
        // Monday=0, Tuesday=1, ... Friday=4  (Saturday=5, Sunday=6 excluded)
        for (uint256 day = 0; day < 5; ++day) {
            // Hours 14:00 through 20:00 inclusive (7 hours open per day)
            for (uint256 hour = 14; hour <= 20; ++hour) {
                uint256 h = day * 24 + hour; // h in [0, 167]
                mask |= 1 << h;
            }
        }
    }
}
