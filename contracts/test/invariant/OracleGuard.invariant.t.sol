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
import {MockSpotter} from "../mocks/MockSpotter.sol";
import {MockVatFrob, MockDog} from "../mocks/MockCore.sol";

/// @notice Random sequences of: price moves (incl. outliers, crashes, pumps), stale/broken sources, time jumps,
///         pokes, syncs, borrows and repays. The invariants below must hold after EVERY step.
contract Handler is Test {
    bytes32 constant ILK = "paxg";
    uint256 constant P = 4372e18;

    MockSource[4] public src;
    SmartOSM public osm;
    RiskController public ctl;
    MockVatFrob public vat;

    bool public repayBlocked; // set if a legitimate repay ever reverted
    uint256 public calls;

    constructor(MockSource[4] memory s, SmartOSM o, RiskController c, MockVatFrob v) {
        src = s;
        osm = o;
        ctl = c;
        vat = v;
    }

    function movePrice(uint8 which, uint256 bps) external {
        bps = bound(bps, 1_000, 100_000); // -90% .. +900%
        src[which % 4].setPrice(P * bps / 10_000);
        calls++;
    }

    function moveAll(uint256 bps) external {
        bps = bound(bps, 3_000, 30_000);
        for (uint256 i; i < 4; ++i) src[i].setPrice(P * bps / 10_000);
        calls++;
    }

    function breakSource(uint8 which, bool stale) external {
        MockSource s = src[which % 4];
        if (stale) s.set(P, 0, uint64(block.timestamp > 30 hours ? block.timestamp - 30 hours : 0), true);
        else s.setOk(false);
        calls++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 hours));
        calls++;
    }

    function poke() external {
        if (osm.pass()) osm.poke();
        calls++;
    }

    function sync() external {
        ctl.sync(ILK);
        calls++;
    }

    function borrow(uint256 wad) external {
        wad = bound(wad, 1e18, 300_000e18);
        try vat.borrow(ILK, wad) {} catch {} // may legitimately hit the ceiling
        calls++;
    }

    function repay(uint256 wad) external {
        (uint256 Art,,,,) = vat.ilks(ILK);
        if (Art == 0) return;
        wad = bound(wad, 1, Art);
        try vat.repay(ILK, wad) {}
        catch {
            repayBlocked = true;
        }
        calls++;
    }
}

contract OracleGuardInvariantTest is Test {
    bytes32 constant ILK = "paxg";
    uint256 constant RAY = 1e27;
    uint256 constant RAD = 1e45;
    uint256 constant P = 4372e18;
    uint256 constant LINE_CAP = 1_000_000 * RAD;
    uint256 constant HOLE_CAP = 400_000 * RAD;

    Handler handler;
    SmartOSM osm;
    RiskController ctl;
    MockVatFrob vat;
    MockDog dog;
    MockSpotter spotter;

    function setUp() public {
        vm.warp(1_800_000_000);
        OracleGuardAggregator agg = new OracleGuardAggregator();
        MockSource[4] memory s;
        uint16[4] memory w = [uint16(2), 2, 2, 1];
        uint32[4] memory maxAge = [uint32(25 hours), 1 hours, 1 hours, 1 hours];
        for (uint256 i; i < 4; ++i) {
            s[i] = new MockSource("s");
            s[i].setPrice(P);
            agg.addSource(IPriceSource(address(s[i])), w[i], maxAge[i]);
        }

        spotter = new MockSpotter();
        osm = new SmartOSM(address(agg), address(spotter), ILK);
        spotter.setPip(address(osm));
        osm.kiss(address(spotter));
        osm.kiss(address(this));
        osm.init(P);

        vat = new MockVatFrob();
        vat.setIlk(ILK, 43_000e18, RAY, LINE_CAP);
        dog = new MockDog();
        dog.file(ILK, "hole", HOLE_CAP);

        LineExecutor lineExec = new LineExecutor(address(vat));
        HoleExecutor holeExec = new HoleExecutor(address(dog));
        ctl = new RiskController(address(vat), address(lineExec), address(holeExec));
        lineExec.setCap(ILK, LINE_CAP);
        holeExec.setCap(ILK, HOLE_CAP);
        lineExec.rely(address(ctl));
        holeExec.rely(address(ctl));
        ctl.setIlk(
            ILK,
            RiskController.IlkCfg({
                agg: IOracleGuardAggregator(address(agg)),
                osm: ISmartOSM(address(osm)),
                sessionAsset: bytes32(0),
                lineCapRad: LINE_CAP,
                greenGapRad: 250_000 * RAD,
                yellowGapRad: 50_000 * RAD,
                holeCapRad: HOLE_CAP,
                greenScore: 80,
                yellowScore: 50,
                epsBps: 150,
                epsLiqBps: 300,
                upgradeInterval: 10 minutes,
                kUp: 3,
                guardMaxDuration: 6 hours,
                refillInterval: 1 hours
            })
        );

        handler = new Handler(s, osm, ctl, vat);
        for (uint256 i; i < 4; ++i) s[i].rely(address(handler));
        targetContract(address(handler));
    }

    /// Zero-price invariant: SmartOSM never reports an invalid or zero price (ADR-004).
    function invariant_peekAlwaysValid() public view {
        (bytes32 v, bool has) = osm.peek();
        assertTrue(has, "peek has=false");
        assertGt(uint256(v), 0, "peek returned 0");
    }

    /// The Vat never receives spot = 0 from SmartOSM (no mass-liquidation trap).
    function invariant_spotterNeverSeesZero() public view {
        if (spotter.pokes() > 0) assertGt(spotter.lastVal(), 0);
    }

    /// Repayments are never blocked by OracleGuard, in any state.
    function invariant_repayNeverBlocked() public view {
        assertFalse(handler.repayBlocked(), "a repay reverted");
    }

    /// Bounded authority: the debt ceiling never exceeds the governance cap; the hole is either normal or 0.
    function invariant_leversWithinCaps() public view {
        (,,, uint256 line,) = vat.ilks(ILK);
        assertLe(line, LINE_CAP, "line above cap");
        (,, uint256 hole,) = dog.ilks(ILK);
        assertTrue(hole == 0 || hole == HOLE_CAP, "hole outside {0, cap}");
    }

    /// Total debt never exceeds the debt ceiling (no state transition can leave the Vat over its ceiling).
    function invariant_debtWithinLine() public view {
        (uint256 Art, uint256 rate,, uint256 line,) = vat.ilks(ILK);
        assertLe(Art * rate, line, "debt above line");
    }

    /// The controller is always in a defined state (GREEN/YELLOW/RED).
    function invariant_stateIsValid() public view {
        (uint8 state,,,,) = ctl.status(ILK);
        assertLe(state, 2);
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0);
    }
}
