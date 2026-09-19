// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "../fork/ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IChainlinkFeed} from "../../src/interfaces/IMaker.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {SmartOSM} from "../../src/SmartOSM.sol";
import {RiskController} from "../../src/RiskController.sol";
import {DeployLib} from "../../script/DeployLib.sol";

/// @notice Mentor review R2 (review.md §R2): replay the SHAPE of historical oracle incidents through the REAL
///         OracleGuard contracts installed on the REAL rwaUSD fork, and through the legacy OSM side by side.
///
/// Honesty notes:
///  - Incidents happened on other assets (DAI, BTC, LUNA, ETH, USDC, MNGO). We replay their relative price paths and
///    which sources were wrong, reconstructed from public post-mortems, scaled onto the PAXG ilk. Values are
///    approximations of the shape, not tick data (Varun's research/ study uses real data at scale).
///  - In single-source incidents the fault is placed on Chainlink, i.e. on the legacy protocol's ONLY feed.
///    That is the fair comparison: legacy rwaUSD is exactly as good as that one feed.
///  - One step = one OSM hop (1h). Prices are in bps of the fork price P (10_000 = P); 0 = source stale/down.
///
/// Classification per step (review.md §R2.4), tol = 2% for gold; "used" = the delayed price the Vat actually uses:
///  mint side:  danger = used > truth*(1+tol) (over-borrowing possible)
///              FN = danger && GREEN ; TP = danger && !GREEN ; FP = !danger && RED  (YELLOW-while-fine = "cautious")
///  liq side:   danger = used < truth*(1-tol) (healthy vaults liquidatable)
///              FN = danger && !guard ; FP = guard && !danger (guard delaying needed liquidations)
///  lag:        used > truth_of_previous_hop*(1+tol): the Vat's price trails the market by MORE than the designed
///              1h delay, so liquidations fire late in a crash (bad-debt risk). Added after the first replay run
///              exposed this in I4/I8 (fixed by ADR-011, asymmetric quarantine).
///  legacy:     no states and no guard, so every danger step is a FN.
contract IncidentReplayTest is ForkBase {
    struct Step {
        uint32 truth;
        uint32 cl;
        uint32 py;
        uint32 rs;
        uint32 dx;
    }

    struct Result {
        uint256 steps;
        uint256 mintFN;
        uint256 mintTP;
        uint256 mintFP;
        uint256 cautious;
        uint256 liqFN;
        uint256 liqTP;
        uint256 liqFP;
        uint256 legacyMintFN;
        uint256 legacyLiqFN;
        uint256 lag;
        uint256 legacyLag;
        uint256 maxHeadroomAtFN; // rwaUSD: worst-case new debt that could be minted during a mint-side FN
        uint256 legacyMaxHeadroomAtFN;
    }

    uint256 constant TOL_BPS = 200;
    DeployLib.Deployment d;
    SmartOSM osm;
    RiskController ctl;
    uint256 P;
    uint256 lastCl;

    function setUp() public override {
        super.setUp();
        (P,) = legacyCur();
        d = DeployLib.deploy(P);
        vm.startPrank(C.ADMIN_SAFE);
        DeployLib.spell(d);
        vm.stopPrank();
        osm = SmartOSM(d.smartOsm);
        ctl = RiskController(d.controller);
        lastCl = P;
    }

    // ================================================================= incident traces

    function _s(uint32 truth, uint32 cl, uint32 py, uint32 rs, uint32 dx) internal pure returns (Step memory) {
        return Step(truth, cl, py, rs, dx);
    }

    function _all(uint32 v) internal pure returns (Step memory) {
        return Step(v, v, v, v, v);
    }

    /// I1 Synthetix sKRW (Jun 2019): one feed reported ~1000x for about an hour.
    function _I1() internal pure returns (Step[] memory t) {
        t = new Step[](6);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(10_000, 10_000_000, 10_000, 10_000, 10_000);
        t[3] = _s(10_000, 10_000_000, 10_000, 10_000, 10_000);
        t[4] = _all(10_000);
        t[5] = _all(10_000);
    }

    /// I2 Compound DAI (Nov 2020): one reporter priced DAI at $1.30 for ~1h -> collateral looked 23% cheaper -> $89M liquidated.
    function _I2() internal pure returns (Step[] memory t) {
        t = new Step[](6);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(10_000, 7_700, 10_000, 10_000, 10_000);
        t[3] = _all(10_000);
        t[4] = _all(10_000);
        t[5] = _all(10_000);
    }

    /// I3 Pyth BTC publisher error (Sep 2021): one feed briefly ~90% low.
    function _I3() internal pure returns (Step[] memory t) {
        t = new Step[](5);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(10_000, 1_000, 10_000, 10_000, 10_000);
        t[3] = _all(10_000);
        t[4] = _all(10_000);
    }

    /// I4 LUNA (May 2022): real crash; Chainlink pinned at its circuit-breaker floor while the market kept falling.
    function _I4() internal pure returns (Step[] memory t) {
        t = new Step[](8);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _all(8_000);
        t[3] = _s(6_000, 6_000, 6_000, 6_000, 6_000);
        t[4] = _s(4_000, 6_000, 4_000, 4_000, 4_000); // Chainlink clamped at the floor
        t[5] = _s(2_500, 6_000, 2_500, 2_500, 2_500);
        t[6] = _s(1_500, 6_000, 1_500, 1_500, 1_500);
        t[7] = _s(1_500, 6_000, 1_500, 1_500, 1_500);
    }

    /// I5 Stale-feed outage (synthetic on gold): Chainlink stops, later every source stops, market drifts -4%.
    function _I5() internal pure returns (Step[] memory t) {
        t = new Step[](8);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(9_950, 0, 9_950, 9_950, 9_950);
        t[3] = _s(9_900, 0, 9_900, 9_900, 9_900);
        t[4] = _s(9_800, 0, 0, 0, 0);
        t[5] = _s(9_700, 0, 0, 0, 0);
        t[6] = _s(9_600, 0, 0, 0, 0);
        t[7] = _s(9_600, 0, 0, 0, 0);
    }

    /// I6 Mango Markets (Oct 2022): CORRELATED manipulation, every oracle tracked a manipulated spot market (~+100..+300%).
    function _I6() internal pure returns (Step[] memory t) {
        t = new Step[](6);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(10_000, 20_000, 20_000, 20_000, 20_000);
        t[3] = _s(10_000, 30_000, 30_000, 30_000, 30_000);
        t[4] = _s(10_000, 30_000, 30_000, 30_000, 30_000);
        t[5] = _all(10_000);
    }

    /// I7 USDC/SVB (Mar 2023): CORRELATED but TRUE move -12% and recovery. Every source is right.
    function _I7() internal pure returns (Step[] memory t) {
        t = new Step[](8);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _all(9_200);
        t[3] = _all(8_800);
        t[4] = _all(9_500);
        t[5] = _all(9_900);
        t[6] = _all(10_000);
        t[7] = _all(10_000);
    }

    /// I8 Black Thursday (Mar 2020): real -43% crash; one push oracle lags an hour behind (network congestion).
    function _I8() internal pure returns (Step[] memory t) {
        t = new Step[](8);
        t[0] = _all(10_000);
        t[1] = _all(10_000);
        t[2] = _s(8_500, 10_000, 8_500, 8_500, 8_500);
        t[3] = _s(7_000, 8_500, 7_000, 7_000, 7_000);
        t[4] = _s(5_700, 7_000, 5_700, 5_700, 5_700);
        t[5] = _s(6_000, 5_700, 6_000, 6_000, 6_000);
        t[6] = _all(6_000);
        t[7] = _all(6_000);
    }

    // ================================================================= replay engine

    function _px(uint32 bps) internal view returns (uint256) {
        return P * bps / 10_000;
    }

    function _setMock(address m, uint32 bps) internal {
        if (bps == 0) MockSource(m).set(P, 0, uint64(block.timestamp - 2 hours), true); // stale
        else MockSource(m).setPrice(_px(bps));
    }

    function _setChainlink(uint32 bps) internal {
        uint256 p = bps == 0 ? lastCl : _px(bps);
        uint256 t = bps == 0 ? block.timestamp - 26 hours : block.timestamp;
        vm.mockCall(
            C.CL_PAXG_USD,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(p / 1e10), t, t, uint80(1))
        );
        if (bps != 0) lastCl = p;
    }

    function _run(Step[] memory t) internal returns (Result memory res) {
        res.steps = t.length;
        for (uint256 k; k < t.length; ++k) {
            uint256 next = uint256(osm.zzz()) + osm.hop();
            if (block.timestamp < next) vm.warp(next);
            else vm.warp(block.timestamp + 1 hours);

            _setChainlink(t[k].cl);
            _setMock(d.pyth, t[k].py);
            _setMock(d.redstone, t[k].rs);
            _setMock(d.dexTwap, t[k].dx);

            if (osm.pass()) osm.poke();
            ctl.sync(C.ILK);
            if (legacyOsm.pass()) legacyOsm.poke();

            _classify(res, _px(t[k].truth), _px(k == 0 ? t[k].truth : t[k - 1].truth));
            if (vm.envOr("REPLAY_TRACE", false)) {
                (uint256 used,,) = osm.price();
                (uint8 st,,,,) = ctl.status(C.ILK);
                console2.log(string.concat("   t", _u(k), " truth ", _u(t[k].truth), " used ", _u(used * 10_000 / P), " state ", _u(st), " osmStatus ", _u(osm.status())));
            }
        }
    }

    function _classify(Result memory res, uint256 truth, uint256 prevTruth) internal view {
        (uint256 used,,) = osm.price();
        (uint8 state,, bool guard, uint256 line, uint256 debt) = ctl.status(C.ILK);
        (uint256 legacyUsed,) = legacyCur();

        uint256 hiBand = truth * (10_000 + TOL_BPS) / 10_000;
        uint256 loBand = truth * (10_000 - TOL_BPS) / 10_000;

        // --- OracleGuard, mint side
        bool mintDanger = used > hiBand;
        if (mintDanger && state == ctl.GREEN()) {
            res.mintFN++;
            uint256 headroom = line > debt ? (line - debt) / C.RAD : 0;
            if (headroom > res.maxHeadroomAtFN) res.maxHeadroomAtFN = headroom;
        } else if (mintDanger) {
            res.mintTP++;
        } else if (state == ctl.RED()) {
            res.mintFP++;
        } else if (state == ctl.YELLOW()) {
            res.cautious++;
        }

        // --- OracleGuard, liquidation side
        bool liqDanger = used < loBand;
        if (liqDanger && !guard) res.liqFN++;
        else if (liqDanger) res.liqTP++;
        else if (guard) res.liqFP++;

        // --- Legacy (single feed, no states, no guard)
        if (legacyUsed > hiBand) {
            res.legacyMintFN++;
            uint256 legacyHeadroom = (1_000_000 * C.RAD - debt) / C.RAD;
            if (legacyHeadroom > res.legacyMaxHeadroomAtFN) res.legacyMaxHeadroomAtFN = legacyHeadroom;
        }
        if (legacyUsed < loBand) res.legacyLiqFN++;

        // --- Liquidation lag beyond the designed 1h delay
        uint256 lagBand = prevTruth * (10_000 + TOL_BPS) / 10_000;
        if (used > lagBand) res.lag++;
        if (legacyUsed > lagBand) res.legacyLag++;
    }

    function _log(string memory name, Result memory r) internal pure {
        console2.log(name);
        console2.log("   steps", r.steps);
        console2.log("   OracleGuard mint  FN/TP/FP/cautious", _fmt4(r.mintFN, r.mintTP, r.mintFP, r.cautious));
        console2.log("   OracleGuard liq   FN/TP/FP        ", _fmt4(r.liqFN, r.liqTP, r.liqFP, 0));
        console2.log("   Legacy      mintFN/liqFN           ", _fmt4(r.legacyMintFN, r.legacyLiqFN, 0, 0));
        console2.log("   liquidation-lag hours: OG / legacy  ", _fmt4(r.lag, r.legacyLag, 0, 0));
        console2.log("   max new debt at a wrong price: OG / legacy ($)", r.maxHeadroomAtFN, r.legacyMaxHeadroomAtFN);
    }

    function _fmt4(uint256 a, uint256 b, uint256 c, uint256 e) internal pure returns (string memory) {
        return string.concat(_u(a), " / ", _u(b), " / ", _u(c), " / ", _u(e));
    }

    function _u(uint256 x) internal pure returns (string memory) {
        if (x == 0) return "0";
        bytes memory b;
        while (x > 0) {
            b = abi.encodePacked(bytes1(uint8(48 + x % 10)), b);
            x /= 10;
        }
        return string(b);
    }

    // ================================================================= incidents (assertions = review.md §R2.3)

    function test_I1_singleSourceSpike_sKRW() public {
        Result memory r = _run(_I1());
        _log("I1 Synthetix sKRW: one feed 1000x", r);
        assertEq(r.mintFN + r.liqFN, 0, "single-source spike must never pass");
        assertGt(r.legacyMintFN, 0, "legacy is exposed");
    }

    function test_I2_singleSourceLow_CompoundDAI() public {
        Result memory r = _run(_I2());
        _log("I2 Compound DAI: one feed 23% off (liquidation side)", r);
        assertEq(r.mintFN + r.liqFN, 0);
        assertGt(r.legacyLiqFN, 0, "legacy would liquidate healthy vaults");
    }

    function test_I3_singleSourceCrash_PythBTC() public {
        Result memory r = _run(_I3());
        _log("I3 Pyth BTC publisher error: one feed -90%", r);
        assertEq(r.mintFN + r.liqFN, 0);
        assertGt(r.legacyLiqFN, 0);
    }

    function test_I4_clampDuringRealCrash_LUNA() public {
        Result memory r = _run(_I4());
        _log("I4 LUNA: real crash, Chainlink stuck at its floor", r);
        assertEq(r.mintFN, 0, "never GREEN while the used price is too high");
        assertEq(r.liqFP, 0, "guard never delays liquidations in a real crash");
        assertEq(r.lag, 0, "follows the crash with only the designed 1h delay");
        assertGt(r.legacyLag, 0, "legacy stays pinned to the clamped feed");
    }

    function test_I5_staleOutage() public {
        Result memory r = _run(_I5());
        _log("I5 stale-feed outage: 1 then all sources stop", r);
        assertEq(r.mintFN, 0, "stale price never lends in GREEN");
    }

    function test_I6_correlatedManipulation_Mango_isBoundedNotDetected() public {
        Result memory r = _run(_I6());
        _log("I6 Mango: ALL oracles manipulated together (known limit)", r);
        // Honest: consensus cannot detect a majority lying together. The claim is a BOUND, not detection.
        assertLe(r.maxHeadroomAtFN, DeployLib.GREEN_GAP / C.RAD, "worst case capped by the hourly greenGap");
        assertLt(r.maxHeadroomAtFN, r.legacyMaxHeadroomAtFN, "strictly less exposure than legacy");
    }

    function test_I7_correlatedTrueMove_USDC() public {
        Result memory r = _run(_I7());
        _log("I7 USDC/SVB: every source correct, -12% and back", r);
        assertEq(r.liqFP, 0, "must NOT block needed liquidations on a true move");
        assertEq(r.mintFN, 0);
    }

    function test_I8_realCrashWithLaggingOracle_BlackThursday() public {
        Result memory r = _run(_I8());
        _log("I8 Black Thursday: real -43%, one oracle lags", r);
        assertEq(r.mintFN, 0, "no lending at the stale-high price");
        assertEq(r.liqFP, 0, "liquidations keep running in a real crash");
        assertEq(r.lag, 0, "no extra lag: liquidations stay timely (ADR-011 regression test)");
    }
}
