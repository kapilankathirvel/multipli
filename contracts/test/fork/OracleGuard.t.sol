// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IChainlinkFeed} from "../../src/interfaces/IMaker.sol";
import {Reading} from "../../src/interfaces/IOracleGuard.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {SmartOSM} from "../../src/SmartOSM.sol";
import {RiskController} from "../../src/RiskController.sol";
import {DeployLib} from "../../script/DeployLib.sol";
import {EvilFeed} from "../mocks/EvilFeed.sol";

/// @notice THE PROOF: the same attacks as Baseline.t.sol, on the same real rwaUSD contracts, after the spell.
contract OracleGuardTest is ForkBase {
    DeployLib.Deployment d;
    SmartOSM osm;
    RiskController ctl;
    OracleGuardAggregator agg;
    uint256 P; // true market price at the fork block (legacy OSM cur)

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        (P,) = legacyCur();
        d = DeployLib.deploy(P); // same library the live demo uses
        vm.startPrank(C.ADMIN_SAFE);
        DeployLib.spell(d);
        vm.stopPrank();
        osm = SmartOSM(d.smartOsm);
        ctl = RiskController(d.controller);
        agg = OracleGuardAggregator(d.aggregator);
    }

    // ---------------------------------------------------------------- helpers

    function _mocks(uint256 p) internal {
        MockSource(d.pyth).setPrice(p);
        MockSource(d.redstone).setPrice(p);
        MockSource(d.dexTwap).setPrice(p);
    }

    /// @dev Make the real Chainlink feed report `p` with a fresh timestamp (it's a deviation feed; in a real move it updates).
    function _chainlink(uint256 p) internal {
        vm.mockCall(
            C.CL_PAXG_USD,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(p / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev One keeper tick: wait for the hop, refresh the fast sources, poke SmartOSM, sync the controller.
    function _tick(uint256 market) internal {
        uint256 next = uint256(osm.zzz()) + osm.hop();
        if (block.timestamp < next) vm.warp(next);
        _mocks(market);
        osm.poke();
        ctl.sync(C.ILK);
    }

    function _state() internal view returns (uint8 s) {
        (s,,,,) = ctl.status(C.ILK);
    }

    function _line() internal view returns (uint256 l) {
        (,,, l,) = ilkParams();
    }

    function _debtRad() internal view returns (uint256) {
        (uint256 Art, uint256 rate,,,) = ilkParams();
        return Art * rate;
    }

    // ---------------------------------------------------------------- install

    function test_spell_installsOracleGuard() public view {
        (address pip,) = spotter.ilks(C.ILK);
        assertEq(pip, d.smartOsm, "Spotter reads SmartOSM");
        assertEq(_state(), ctl.GREEN());
        assertEq(_line(), _debtRad() + DeployLib.GREEN_GAP, "GREEN = rate-limited headroom");
        (,, uint256 hole,) = dog.ilks(C.ILK);
        assertEq(hole, 400_000 * C.RAD);
        assertEq(agg.read().score, 100);
    }

    // ---------------------------------------------------------------- S1: stale feed

    /// S1a: Chainlink silent for 7 days, the other sources alive and agreeing -> YELLOW, lending continues (bounded).
    function test_OracleGuard_S1a_oneStaleSource_yellow_boundedBorrowing() public {
        vm.warp(block.timestamp + 7 days);
        _tick(P);
        assertEq(agg.read().score, 71);
        assertEq(_state(), ctl.YELLOW());

        openVault(attacker, 20 ether, 0); // ~$62k of borrowing power at 140%
        vm.expectRevert("Vat/ceiling-exceeded");
        this.frobExt(attacker, 0, int256(60_000 ether)); // more than yellowGap (50k)
        frobAs(attacker, 0, int256(40_000 ether)); // within the YELLOW budget: still works
        console2.log("S1a: Chainlink 7d stale -> score 71 YELLOW; new debt capped at $50,000 (legacy: ~$957k)");
    }

    /// S1b: every source stale -> RED: no new debt, repayments still work.
    function test_OracleGuard_S1b_allStale_red_mintBlocked_repayWorks() public {
        openVault(victim, 10 ether, 20_000 ether); // an existing borrower

        vm.warp(block.timestamp + 7 days); // nothing updates for a week (the hop has long passed)
        osm.poke(); // skipped: no quorum
        ctl.sync(C.ILK);
        assertEq(osm.status(), osm.STALE());
        assertEq(_state(), ctl.RED());

        (, bool has) = legacyPeek();
        (bytes32 v, bool ok) = _smartPeek();
        assertTrue(has && ok && uint256(v) > 0, "price never zeroed (no liquidation cascade)");

        openVault(attacker, 10 ether, 0);
        vm.expectRevert("Vat/ceiling-exceeded");
        this.frobExt(attacker, 0, int256(1_000 ether));

        frobAs(victim, 0, -int256(5_000 ether)); // repay works in RED
        console2.log("S1b: all sources 7d stale -> RED; mint reverts, repay works (legacy minted 31,231 on a 186h-old price)");
    }

    // ---------------------------------------------------------------- S2: market drop while the OSM lags

    function test_OracleGuard_S2_marketDrop_red_liquidationsStayOn() public {
        _mocks(P * 92 / 100);
        ctl.sync(C.ILK); // no need to wait for the hop: the live band is read directly
        assertEq(_state(), ctl.RED(), "live market 8% below the delayed price");
        (,, uint256 hole,) = dog.ilks(C.ILK);
        assertEq(hole, 400_000 * C.RAD, "liquidations NOT paused");

        openVault(attacker, 10 ether, 0);
        vm.expectRevert("Vat/ceiling-exceeded");
        this.frobExt(attacker, 0, int256(1_000 ether));
    }

    // ---------------------------------------------------------------- S3: feed compromise

    /// S3a: the exact baseline attack (Safe swaps the legacy adapter's feed) no longer reaches the Vat.
    function test_OracleGuard_S3a_legacyFeedSwap_hasNoEffect() public {
        (, int256 clAnswer,,,) = IChainlinkFeed(C.CL_PAXG_USD).latestRoundData();
        EvilFeed evil = new EvilFeed(clAnswer * 10);
        vm.prank(C.ADMIN_SAFE);
        adapter.setPriceFeed(address(evil));
        pokeLegacy();
        pokeLegacy(); // the legacy OSM now says 10x...

        _tick(P);
        (,, uint256 spot,,) = ilkParams();
        assertApproxEqRel(spot * mat() / C.RAY, P * 1e9, 0.01e18, "...but the Vat still prices PAXG at the real price");
    }

    /// S3b: one oracle network itself is compromised (Chainlink reports 10x): outlier, no over-mint.
    function test_OracleGuard_S3b_compromisedSource_noBadDebt() public {
        _chainlink(P * 10);
        _tick(P);
        _chainlink(P * 10);
        _tick(P);
        Reading memory r = agg.read();
        assertApproxEqRel(r.mid, P, 0.001e18, "median ignores the 10x source");
        assertEq(r.score, 71, "one major lost -> YELLOW");
        assertEq(_state(), ctl.YELLOW());

        openVault(attacker, 10 ether, 0);
        uint256 draw = maxDrawWad(attacker);
        frobAs(attacker, 0, int256(draw));
        (uint256 ink,) = vat.urns(C.ILK, attacker);
        uint256 collateralUsd = ink * P / C.WAD / C.WAD;
        assertLt(toUsd(draw), collateralUsd, "minted less than the real collateral value: no bad debt");
        console2.log("S3b OracleGuard: minted ($)", toUsd(draw));
        console2.log("        against collateral ($)", collateralUsd);
        console2.log("        bad debt: $0   (legacy: $268,595)");
    }

    // ---------------------------------------------------------------- S4: captured wick / stale-low

    function test_OracleGuard_S4_capturedWick_guardBlocksUnfairLiquidation() public {
        openVault(victim, 10 ether, 0);
        (uint256 ink,) = vat.urns(C.ILK, victim);
        frobAs(victim, 0, int256(ink * P / 145e16)); // 145% at the true price

        // -15% wick seen by every source at the poke...
        _chainlink(P * 85 / 100);
        _tick(P * 85 / 100);
        // ...market recovers, but the delayed price now serves the wick for an hour
        _chainlink(P);
        _tick(P);
        (uint256 cur,,) = osm.price();
        assertLt(cur, P * 90 / 100, "SmartOSM cur = wick (1h delay preserved)");

        (,, bool guard,,) = ctl.status(C.ILK);
        assertTrue(guard, "guard ON: live market well above the delayed price");
        vm.prank(keeper);
        vm.expectRevert("Dog/liquidation-limit-hit");
        dog.bark(C.ILK, victim, keeper);

        // Next hop: the delayed price catches up, guard releases, and the vault is (correctly) safe.
        _chainlink(P);
        _tick(P);
        (,, guard,,) = ctl.status(C.ILK);
        assertFalse(guard);
        vm.prank(keeper);
        vm.expectRevert("Dog/not-unsafe");
        dog.bark(C.ILK, victim, keeper);
        console2.log("S4: healthy 145% vault NOT liquidated (legacy: 10 PAXG seized)");
    }

    // ---------------------------------------------------------------- rollback

    function test_spell_rollback() public {
        vm.startPrank(C.ADMIN_SAFE);
        DeployLib.rollback(d);
        vm.stopPrank();
        (address pip,) = spotter.ilks(C.ILK);
        assertEq(pip, C.LEGACY_OSM);
        assertEq(vat.wards(d.lineExecutor), 0);
        assertEq(dog.wards(d.holeExecutor), 0);
        assertEq(_line(), 1_000_000 * C.RAD, "ceiling restored");
    }

    // ---------------------------------------------------------------- external wrappers for expectRevert

    function frobExt(address who, int256 dink, int256 daiWad) external {
        frobAs(who, dink, daiWad);
    }

    function _smartPeek() internal returns (bytes32, bool) {
        vm.prank(C.SPOTTER);
        return osm.peek();
    }
}
