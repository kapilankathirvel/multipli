// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {IOracleGuardAggregator, ISmartOSM} from "../../src/interfaces/IOracleGuard.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {SmartOSM} from "../../src/SmartOSM.sol";
import {RiskController} from "../../src/RiskController.sol";
import {LineExecutor} from "../../src/executors/LineExecutor.sol";
import {HoleExecutor} from "../../src/executors/HoleExecutor.sol";
import {Auth} from "../../src/utils/Auth.sol";
import {MockSpotter} from "../mocks/MockSpotter.sol";
import {MockVat, MockDog, MockCalendar} from "../mocks/MockCore.sol";

contract RiskControllerTest is Test {
    bytes32 constant ILK = "paxg";
    uint256 constant RAY = 1e27;
    uint256 constant RAD = 1e45;
    uint256 constant P = 4372e18;
    uint256 constant DEBT = 43_000; // rwaUSD
    uint256 constant LINE_CAP = 1_000_000 * RAD;
    uint256 constant GREEN_GAP = 250_000 * RAD;
    uint256 constant YELLOW_GAP = 50_000 * RAD;
    uint256 constant HOLE_CAP = 400_000 * RAD;

    OracleGuardAggregator agg;
    MockSource cl;
    MockSource pyth;
    MockSource red;
    MockSource dex;
    SmartOSM osm;
    MockVat vat;
    MockDog dog;
    LineExecutor lineExec;
    HoleExecutor holeExec;
    RiskController ctl;

    function setUp() public {
        vm.warp(1_800_000_000);

        agg = new OracleGuardAggregator();
        cl = new MockSource("chainlink");
        pyth = new MockSource("pyth");
        red = new MockSource("redstone");
        dex = new MockSource("dex");
        agg.addSource(IPriceSource(address(cl)), 2, 25 hours);
        agg.addSource(IPriceSource(address(pyth)), 2, 1 hours);
        agg.addSource(IPriceSource(address(red)), 2, 1 hours);
        agg.addSource(IPriceSource(address(dex)), 1, 1 hours);
        _market(P);

        MockSpotter spotter = new MockSpotter();
        osm = new SmartOSM(address(agg), address(spotter), ILK);
        spotter.setPip(address(osm));
        osm.kiss(address(spotter));
        osm.init(P);

        vat = new MockVat();
        vat.setIlk(ILK, DEBT * 1e18, RAY, LINE_CAP);
        dog = new MockDog();
        dog.file(ILK, "hole", HOLE_CAP);

        lineExec = new LineExecutor(address(vat));
        holeExec = new HoleExecutor(address(dog));
        ctl = new RiskController(address(vat), address(lineExec), address(holeExec));
        lineExec.setCap(ILK, LINE_CAP);
        holeExec.setCap(ILK, HOLE_CAP);
        lineExec.rely(address(ctl));
        holeExec.rely(address(ctl));
        ctl.setIlk(ILK, _cfg(bytes32(0)));
    }

    function _cfg(bytes32 sessionAsset) internal view returns (RiskController.IlkCfg memory) {
        return RiskController.IlkCfg({
            agg: IOracleGuardAggregator(address(agg)),
            osm: ISmartOSM(address(osm)),
            sessionAsset: sessionAsset,
            lineCapRad: LINE_CAP,
            greenGapRad: GREEN_GAP,
            yellowGapRad: YELLOW_GAP,
            holeCapRad: HOLE_CAP,
            greenScore: 80,
            yellowScore: 50,
            epsBps: 150,
            epsLiqBps: 300,
            upgradeInterval: 10 minutes,
            kUp: 3,
            guardMaxDuration: 6 hours,
            refillInterval: 1 hours
        });
    }

    // ---------------------------------------------------------------- helpers

    function _market(uint256 p) internal {
        cl.setPrice(p);
        pyth.setPrice(p);
        red.setPrice(p);
        dex.setPrice(p);
    }

    function _line() internal view returns (uint256 l) {
        (,,, l,) = vat.ilks(ILK);
    }

    function _debt() internal view returns (uint256) {
        (uint256 Art, uint256 rate,,,) = vat.ilks(ILK);
        return Art * rate;
    }

    function _hole() internal view returns (uint256 h) {
        (,, h,) = dog.ilks(ILK);
    }

    function _state() internal view returns (uint8 s) {
        (s,,,,) = ctl.status(ILK);
    }

    function _mint(uint256 wad) internal {
        (uint256 Art,,,,) = vat.ilks(ILK);
        vat.setArt(ILK, Art + wad * 1e18);
    }

    /// @dev Keeper-style healthy sync `n` times, spaced by the upgrade interval, refreshing sources each time.
    function _healthySyncs(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            _market(P);
            ctl.sync(ILK);
        }
    }

    // ---------------------------------------------------------------- GREEN + rate limit (review R3/R4)

    function test_green_rateLimitedHeadroom() public {
        ctl.sync(ILK);
        assertEq(_state(), ctl.GREEN());
        assertEq(_line(), DEBT * RAD + GREEN_GAP, "line = debt + greenGap, not the whole 1M ceiling");

        _mint(200_000); // borrow within this hour's budget
        vm.warp(block.timestamp + 30 minutes);
        _market(P);
        ctl.sync(ILK);
        assertEq(_line(), DEBT * RAD + GREEN_GAP, "no refill inside the window");

        vm.warp(block.timestamp + 31 minutes);
        _market(P);
        ctl.sync(ILK);
        assertEq(_line(), _debt() + GREEN_GAP, "refilled after the window");
    }

    function test_green_neverAboveLineCap() public {
        vat.setArt(ILK, 900_000e18);
        ctl.sync(ILK);
        assertEq(_line(), LINE_CAP);
    }

    // ---------------------------------------------------------------- YELLOW

    function test_yellow_oneMajorStale_limitedHeadroom_neverRaised() public {
        pyth.set(P, 0, uint64(block.timestamp - 2 hours), true); // one major stale -> score 71
        ctl.sync(ILK);
        assertEq(_state(), ctl.YELLOW());
        uint256 anchored = DEBT * RAD + YELLOW_GAP;
        assertEq(_line(), anchored);

        _mint(40_000);
        vm.warp(block.timestamp + 2 hours);
        cl.setPrice(P);
        red.setPrice(P);
        dex.setPrice(P);
        ctl.sync(ILK); // still YELLOW
        assertEq(_state(), ctl.YELLOW());
        assertEq(_line(), anchored, "YELLOW never raises the line: total leak <= yellowGap");
    }

    function test_yellow_marketClosed() public {
        MockCalendar cal = new MockCalendar();
        ctl.setCalendar(address(cal));
        ctl.setIlk(ILK, _cfg("tslax"));
        cal.setOpen(false);
        ctl.sync(ILK);
        assertEq(_state(), ctl.YELLOW());
    }

    // ---------------------------------------------------------------- RED

    function test_red_allStale_lineEqualsDebt_repayLowersIt() public {
        vm.warp(block.timestamp + 26 hours);
        ctl.sync(ILK);
        assertEq(_state(), ctl.RED());
        assertEq(_line(), _debt(), "no new debt possible");

        vat.setArt(ILK, 10_000e18); // users repay
        ctl.sync(ILK);
        assertEq(_line(), _debt(), "line follows debt down, never up");
    }

    function test_red_marketBelowDelayedPrice() public {
        _market(P * 92 / 100); // S2: live market -8%, OSM still at P
        ctl.sync(ILK);
        assertEq(_state(), ctl.RED());
        assertEq(_hole(), HOLE_CAP, "liquidations stay ON in RED");
    }

    function test_red_whenOsmQuarantined() public {
        vm.warp(uint256(osm.zzz()) + osm.hop());
        pyth.setPrice(P * 11 / 10);
        red.setPrice(P * 11 / 10); // low-agreement +10% jump -> quarantine
        osm.poke();
        cl.setPrice(P);
        dex.setPrice(P);
        ctl.sync(ILK);
        assertEq(_state(), ctl.RED());
    }

    // ---------------------------------------------------------------- hysteresis

    function test_downgradeInstant_upgradeNeedsSpacedHealthySyncs() public {
        vm.warp(block.timestamp + 26 hours);
        ctl.sync(ILK);
        assertEq(_state(), ctl.RED());

        _market(P);
        osm.poke(); // oracle healthy again
        for (uint256 i; i < 10; ++i) ctl.sync(ILK); // same-block spam
        assertEq(_state(), ctl.RED(), "spam cannot upgrade");

        _healthySyncs(3);
        assertEq(_state(), ctl.YELLOW(), "one level per kUp spaced syncs");
        _healthySyncs(3);
        assertEq(_state(), ctl.GREEN());
    }

    // ---------------------------------------------------------------- liquidation guard (stale-low, S4)

    function _captureWick() internal {
        vm.warp(uint256(osm.zzz()) + osm.hop());
        _market(P * 85 / 100); // all sources dip together -> accepted as nxt
        osm.poke();
        vm.warp(uint256(osm.zzz()) + osm.hop());
        _market(P); // market recovered; cur = wick for the next hour
        osm.poke();
    }

    function test_guard_pausesNewLiquidations_onCapturedWick() public {
        _captureWick();
        ctl.sync(ILK);
        (, , bool guard,,) = ctl.status(ILK);
        assertTrue(guard);
        assertEq(_hole(), 0, "Dog.hole = 0: no new barks");
        assertEq(_state(), ctl.GREEN(), "live market is healthy: borrowing not frozen by the guard");
    }

    function test_guard_releasesWhenOsmCatchesUp() public {
        _captureWick();
        ctl.sync(ILK);
        vm.warp(uint256(osm.zzz()) + osm.hop());
        _market(P);
        osm.poke(); // cur = recovered price
        ctl.sync(ILK);
        (, , bool guard,,) = ctl.status(ILK);
        assertFalse(guard);
        assertEq(_hole(), HOLE_CAP);
    }

    function test_guard_expires_andLatches() public {
        _captureWick();
        ctl.sync(ILK);
        osm.stop(); // freeze the OSM at the low price so the condition persists
        vm.warp(block.timestamp + 6 hours + 1);
        _market(P);
        ctl.sync(ILK);
        (, , bool guard,,) = ctl.status(ILK);
        assertFalse(guard, "auto-expired: liquidations can't be paused forever");
        assertEq(_hole(), HOLE_CAP);

        vm.warp(block.timestamp + 10 minutes);
        _market(P);
        ctl.sync(ILK);
        (, , guard,,) = ctl.status(ILK);
        assertFalse(guard, "latched: doesn't re-arm until the condition clears once");
    }

    function test_guard_notOnRealCrash() public {
        vm.warp(uint256(osm.zzz()) + osm.hop());
        _market(P * 85 / 100); // real crash, everyone agrees, market stays down
        osm.poke();
        vm.warp(uint256(osm.zzz()) + osm.hop());
        _market(P * 85 / 100);
        osm.poke();
        ctl.sync(ILK);
        (, , bool guard,,) = ctl.status(ILK);
        assertFalse(guard, "real crash: liquidations must proceed");
        assertEq(_hole(), HOLE_CAP);
    }

    // ---------------------------------------------------------------- admin / events

    function test_admin() public {
        vm.expectRevert(RiskController.NotConfigured.selector);
        ctl.sync("unknown");

        RiskController.IlkCfg memory bad = _cfg(bytes32(0));
        bad.kUp = 0;
        vm.expectRevert(RiskController.BadConfig.selector);
        ctl.setIlk(ILK, bad);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Auth.NotAuthorized.selector);
        ctl.setIlk(ILK, _cfg(bytes32(0)));
    }

    function test_executorsOnlyCallableByController() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(Auth.NotAuthorized.selector);
        lineExec.setLine(ILK, LINE_CAP);
    }

    function test_emitsStateChanged() public {
        vm.warp(block.timestamp + 26 hours);
        vm.expectEmit(true, false, false, true);
        emit StateChanged(ILK, 0, 2);
        ctl.sync(ILK);
    }

    event StateChanged(bytes32 indexed ilk, uint8 from, uint8 to);
}
