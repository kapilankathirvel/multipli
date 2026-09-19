// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";

/// @notice Unit tests for SessionCalendar — no fork, pure EVM.
///
/// Week mask reference (Mon = h0):
///   Monday    h  0..23
///   Tuesday   h 24..47
///   Wednesday h 48..71
///   Thursday  h 72..95
///   Friday    h 96..119
///   Saturday  h 120..143
///   Sunday    h 144..167
///
/// Anchor timestamps (verified manually):
///   Monday    2024-01-08 00:00 UTC → Unix = 1704672000
///     hourOfWeek = (1704672000/3600 + 72) % 168 = (473520 + 72) % 168 = 473592 % 168 = 0  ✓
///   Friday    2024-01-12 20:59 UTC → Unix = 1705093140
///     hourOfWeek = (1705093140/3600 + 72) % 168 = (473636 + 72) % 168 = 473708 % 168 = 116 ✓ (Fri h=116 → bit 116 is open)
///   Friday    2024-01-12 21:00 UTC → Unix = 1705093200
///     hourOfWeek = (1705093200/3600 + 72) % 168 = 473637 % 168 = 117 ✗ (Fri h=117 = 21:00 is NOT in mask)
///   Saturday  2024-01-13 10:00 UTC → Unix = 1705139200 (approx)
///     hourOfWeek = 126 (Sat, h=6, bit 126)  ← Saturday → not in NYSE mask
///   Monday    2024-01-08 14:00 UTC → Unix = 1704722400
///     hourOfWeek = 14 (Mon 14:00) ← bit 14 is set in NYSE mask
contract SessionCalendarTest is Test {
    SessionCalendar public cal;

    // Pinned timestamps for determinism
    // Monday 2024-01-08 00:00 UTC
    uint256 constant MON_0000 = 1_704_672_000;
    // Monday 2024-01-08 14:00 UTC
    uint256 constant MON_1400 = MON_0000 + 14 * 3600;
    // Friday 2024-01-12 20:59 UTC  (last minute of the open session)
    uint256 constant FRI_2059 = MON_0000 + 4 * 24 * 3600 + 20 * 3600 + 59 * 60;
    // Friday 2024-01-12 21:00 UTC  (first minute that is CLOSED)
    uint256 constant FRI_2100 = MON_0000 + 4 * 24 * 3600 + 21 * 3600;
    // Saturday 2024-01-13 10:00 UTC
    uint256 constant SAT_1000 = MON_0000 + 5 * 24 * 3600 + 10 * 3600;
    // Sunday 2024-01-14 12:00 UTC
    uint256 constant SUN_1200 = MON_0000 + 6 * 24 * 3600 + 12 * 3600;

    bytes32 constant ASSET = "paxg";
    bytes32 constant ASSET2 = "tslax";  // second asset (isolation check)

    function setUp() public {
        cal = new SessionCalendar();
        // Configure ASSET with NYSE mask
        cal.setWeekMask(ASSET, cal.nyseMask());
    }

    // ---------------------------------------------------------------- nyseMask sanity

    function test_nyseMask_is_nonzero() public view {
        assertGt(cal.nyseMask(), 0);
    }

    function test_nyseMask_has_correct_bit_count() public view {
        // 5 days × 7 hours = 35 bits set
        uint256 mask = cal.nyseMask();
        uint256 count = 0;
        for (uint256 i = 0; i < 168; ++i) {
            if ((mask >> i) & 1 == 1) count++;
        }
        assertEq(count, 35, "expected 35 open hours (Mon-Fri 14:00-20:00)");
    }

    function test_nyseMask_saturday_bits_clear() public view {
        uint256 mask = cal.nyseMask();
        // Saturday bits: h120..h143
        for (uint256 h = 120; h < 144; ++h) {
            assertEq((mask >> h) & 1, 0, "Saturday bit should be 0");
        }
    }

    function test_nyseMask_sunday_bits_clear() public view {
        uint256 mask = cal.nyseMask();
        // Sunday bits: h144..h167
        for (uint256 h = 144; h < 168; ++h) {
            assertEq((mask >> h) & 1, 0, "Sunday bit should be 0");
        }
    }

    // ---------------------------------------------------------------- varun.md test cases

    /// "Fri 20:59 open"
    function test_friday_2059_open() public view {
        assertTrue(cal.isOpen(ASSET, FRI_2059), "Fri 20:59 should be open");
    }

    /// "Fri 21:00 closed"
    function test_friday_2100_closed() public view {
        assertFalse(cal.isOpen(ASSET, FRI_2100), "Fri 21:00 should be closed");
    }

    /// "Sat closed"
    function test_saturday_closed() public view {
        assertFalse(cal.isOpen(ASSET, SAT_1000), "Saturday should be closed");
    }

    /// "Mon 14:00 open"
    function test_monday_1400_open() public view {
        assertTrue(cal.isOpen(ASSET, MON_1400), "Mon 14:00 should be open");
    }

    /// Monday 00:00 is before the session → closed
    function test_monday_0000_closed() public view {
        assertFalse(cal.isOpen(ASSET, MON_0000), "Mon 00:00 should be closed (before session)");
    }

    /// Sunday should be fully closed
    function test_sunday_closed() public view {
        assertFalse(cal.isOpen(ASSET, SUN_1200), "Sunday should be closed");
    }

    /// "holiday closed"
    function test_holiday_closes_weekday() public {
        // Monday 14:00 is normally open, but mark it as a holiday
        uint256 dayIdx = MON_1400 / 1 days;
        cal.setHoliday(ASSET, dayIdx, true);
        assertFalse(cal.isOpen(ASSET, MON_1400), "holiday should override weekday open");
    }

    function test_holiday_can_be_removed() public {
        uint256 dayIdx = MON_1400 / 1 days;
        cal.setHoliday(ASSET, dayIdx, true);
        assertFalse(cal.isOpen(ASSET, MON_1400));
        // Unset the holiday
        cal.setHoliday(ASSET, dayIdx, false);
        assertTrue(cal.isOpen(ASSET, MON_1400), "un-setting holiday should restore open");
    }

    /// "alwaysOpen" — open even on Saturday
    function test_alwaysOpen_saturday() public {
        cal.setAlwaysOpen(ASSET, true);
        assertTrue(cal.isOpen(ASSET, SAT_1000), "alwaysOpen asset should be open on Saturday");
    }

    /// "alwaysOpen" — open even on a holiday
    function test_alwaysOpen_overrides_holiday() public {
        uint256 dayIdx = MON_1400 / 1 days;
        cal.setHoliday(ASSET, dayIdx, true);
        cal.setAlwaysOpen(ASSET, true);
        assertTrue(cal.isOpen(ASSET, MON_1400), "alwaysOpen should override holiday");
    }

    /// alwaysOpen can be revoked
    function test_alwaysOpen_can_be_revoked() public {
        cal.setAlwaysOpen(ASSET, true);
        assertTrue(cal.isOpen(ASSET, SAT_1000));
        cal.setAlwaysOpen(ASSET, false);
        assertFalse(cal.isOpen(ASSET, SAT_1000), "after revoking alwaysOpen, Saturday should be closed");
    }

    // ---------------------------------------------------------------- unconfigured asset

    /// An asset with no mask configured (weekMask == 0) is always closed
    function test_unconfigured_asset_always_closed() public view {
        assertFalse(cal.isOpen("notset", MON_1400), "unconfigured asset should be closed");
    }

    // ---------------------------------------------------------------- isolation between assets

    function test_asset_isolation() public {
        // ASSET2 has no mask; ASSET has NYSE mask
        assertFalse(cal.isOpen(ASSET2, MON_1400), "ASSET2 should be closed (no mask)");
        assertTrue(cal.isOpen(ASSET, MON_1400),   "ASSET should be open");
    }

    function test_holiday_isolation() public {
        uint256 dayIdx = MON_1400 / 1 days;
        // Set holiday only on ASSET
        cal.setHoliday(ASSET, dayIdx, true);
        // Give ASSET2 the same NYSE mask
        cal.setWeekMask(ASSET2, cal.nyseMask());
        // ASSET2 should not be affected by ASSET's holiday
        assertTrue(cal.isOpen(ASSET2, MON_1400), "ASSET2 should not inherit ASSET's holiday");
        assertFalse(cal.isOpen(ASSET, MON_1400),  "ASSET should be closed on holiday");
    }

    // ---------------------------------------------------------------- auth

    function test_only_ward_can_setWeekMask() public {
        address nobody = address(0xBEEF);
        vm.prank(nobody);
        vm.expectRevert();
        cal.setWeekMask(ASSET, 0);
    }

    function test_only_ward_can_setHoliday() public {
        address nobody = address(0xBEEF);
        vm.prank(nobody);
        vm.expectRevert();
        cal.setHoliday(ASSET, 1, true);
    }

    function test_only_ward_can_setAlwaysOpen() public {
        address nobody = address(0xBEEF);
        vm.prank(nobody);
        vm.expectRevert();
        cal.setAlwaysOpen(ASSET, true);
    }

    function test_rely_deny_transfers_access() public {
        address newWard = address(0xCAFE);
        cal.rely(newWard);
        // newWard should now be able to call auth functions
        vm.prank(newWard);
        cal.setAlwaysOpen(ASSET, true);  // should not revert
        assertTrue(cal.isOpen(ASSET, SAT_1000));

        // Deny newWard again
        cal.deny(newWard);
        vm.prank(newWard);
        vm.expectRevert();
        cal.setAlwaysOpen(ASSET, false);
    }

    // ---------------------------------------------------------------- events

    function test_setWeekMask_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit SessionCalendar.WeekMaskSet(ASSET, 42);
        cal.setWeekMask(ASSET, 42);
    }

    function test_setHoliday_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit SessionCalendar.HolidaySet(ASSET, 1, true);
        cal.setHoliday(ASSET, 1, true);
    }

    function test_setAlwaysOpen_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit SessionCalendar.AlwaysOpenSet(ASSET, true);
        cal.setAlwaysOpen(ASSET, true);
    }

    // ---------------------------------------------------------------- fuzz / edge cases

    /// weekMask = all-ones → always open (ignoring holidays)
    function test_allOnes_mask_always_open() public {
        cal.setWeekMask(ASSET, type(uint256).max);
        assertTrue(cal.isOpen(ASSET, SAT_1000), "all-ones mask: Saturday open");
        assertTrue(cal.isOpen(ASSET, SUN_1200), "all-ones mask: Sunday open");
        // Holiday still wins
        uint256 dayIdx = SAT_1000 / 1 days;
        cal.setHoliday(ASSET, dayIdx, true);
        assertFalse(cal.isOpen(ASSET, SAT_1000), "holiday overrides all-ones mask");
    }

    /// Fuzz: isOpen never reverts
    function testFuzz_isOpen_never_reverts(bytes32 asset, uint256 ts) public view {
        cal.isOpen(asset, ts);
    }

    /// Fuzz: hourOfWeek stays in [0, 167]
    function testFuzz_hourOfWeek_in_range(uint256 ts) public pure {
        uint256 h = ((ts / 3600) + 72) % 168;
        assertLt(h, 168);
    }
}
