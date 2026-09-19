// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {SmartOSM} from "../../src/SmartOSM.sol";
import {Auth} from "../../src/utils/Auth.sol";
import {MockSpotter} from "../mocks/MockSpotter.sol";

contract SmartOSMTest is Test {
    OracleGuardAggregator agg;
    MockSource cl;
    MockSource pyth;
    MockSource red;
    MockSource dex;
    MockSpotter spotter;
    SmartOSM osm;
    uint256 constant P = 4372e18;

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
        _all(P);

        spotter = new MockSpotter();
        osm = new SmartOSM(address(agg), address(spotter), "paxg");
        spotter.setPip(address(osm));
        osm.kiss(address(spotter));
        osm.kiss(address(this));
        osm.init(P);
    }

    // ---------------------------------------------------------------- helpers

    function _all(uint256 p) internal {
        cl.setPrice(p);
        pyth.setPrice(p);
        red.setPrice(p);
        dex.setPrice(p);
    }

    function _nextHop() internal {
        vm.warp(uint256(osm.zzz()) + osm.hop());
    }

    function _cur() internal view returns (uint256 c) {
        (c,,) = osm.price();
    }

    function _nxt() internal view returns (uint256 n) {
        (, n,) = osm.price();
    }

    function _peek() internal view returns (uint256 v, bool has) {
        (bytes32 b, bool h) = osm.peek();
        return (uint256(b), h);
    }

    // ---------------------------------------------------------------- lifecycle

    function test_init_primesWithoutDiscontinuity() public view {
        (uint256 v, bool has) = _peek();
        assertTrue(has);
        assertEq(v, P);
        assertEq(_nxt(), P);
        assertEq(osm.status(), osm.LIVE());
        assertEq(osm.age(), 0);
    }

    function test_init_onlyOnce_andNonZero() public {
        vm.expectRevert(SmartOSM.AlreadyInitialized.selector);
        osm.init(P);
        SmartOSM fresh = new SmartOSM(address(agg), address(spotter), "paxg");
        vm.expectRevert(SmartOSM.BadPrice.selector);
        fresh.init(0);
        assertEq(fresh.status(), fresh.UNINIT());
    }

    function test_pokeBeforeInit_reverts() public {
        SmartOSM fresh = new SmartOSM(address(agg), address(spotter), "paxg");
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(SmartOSM.NotInitialized.selector);
        fresh.poke();
    }

    function test_pokeBeforeHop_reverts() public {
        vm.expectRevert("OSM/not-passed");
        osm.poke();
    }

    // ---------------------------------------------------------------- normal flow (Maker semantics)

    function test_poke_shiftsNxtIntoCur_andPokesSpotter() public {
        _nextHop();
        _all(P * 101 / 100); // +1%, full agreement
        osm.poke();
        assertEq(_cur(), P, "cur = old nxt (1h delay preserved)");
        assertEq(_nxt(), P * 101 / 100);
        assertEq(spotter.pokes(), 1, "atomic Spotter.poke");
        assertEq(spotter.lastVal(), P);

        _nextHop();
        osm.poke();
        assertEq(_cur(), P * 101 / 100);
    }

    // ---------------------------------------------------------------- V1: staleness is observable, price never 0

    function test_allSourcesStale_skips_keepsValidPrice_becomesStale() public {
        vm.warp(block.timestamp + 26 hours); // every source (incl. Chainlink's 25h) is stale
        osm.poke(); // must not revert
        (uint256 v, bool has) = _peek();
        assertTrue(has, "zero-price invariant: still valid");
        assertEq(v, P);
        assertEq(osm.status(), osm.STALE(), "but visibly STALE");
        assertGt(osm.age(), osm.staleLimit());
        assertEq(spotter.pokes(), 0);
    }

    function test_skip_doesNotConsumeHop_retryWhenSourcesRecover() public {
        vm.warp(block.timestamp + 26 hours);
        osm.poke(); // skipped
        _all(P);
        osm.poke(); // same timestamp, retry allowed because zzz was not advanced
        assertEq(osm.status(), osm.LIVE());
        assertEq(osm.age(), 0);
    }

    // ---------------------------------------------------------------- V5/V6: jump quarantine

    function test_lowAgreementJump_isQuarantined_thenConfirmed() public {
        _nextHop();
        // Two majors say +10%, Chainlink + DEX say P: score 0 (dispersion), so a 10% jump without agreement.
        pyth.setPrice(P * 11 / 10);
        red.setPrice(P * 11 / 10);
        osm.poke();
        assertEq(osm.status(), osm.QUARANTINED());
        assertEq(_nxt(), P, "not promoted");
        assertEq(osm.pending(), P * 11 / 10);

        vm.expectRevert("OSM/not-passed"); // re-confirmation must come from a LATER hop
        osm.poke();

        _nextHop();
        pyth.setPrice(P * 11 / 10);
        red.setPrice(P * 11 / 10);
        cl.setPrice(P);
        dex.setPrice(P);
        osm.poke(); // sustained for a full hop: accepted
        assertEq(_nxt(), P * 11 / 10);
        assertEq(osm.pending(), 0);
    }

    function test_transientManipulation_neverPromoted() public {
        _nextHop();
        pyth.setPrice(P * 11 / 10);
        red.setPrice(P * 11 / 10);
        osm.poke(); // quarantined
        _nextHop();
        _all(P); // manipulation over
        osm.poke();
        assertEq(_nxt(), P);
        assertEq(osm.pending(), 0);
        assertEq(osm.status(), osm.LIVE());
    }

    function test_realCrash_withFullAgreement_passesImmediately() public {
        _nextHop();
        _all(P * 85 / 100); // -15%, every source agrees -> score 100
        osm.poke();
        assertEq(_nxt(), P * 85 / 100, "real crashes must not be delayed by quarantine");
    }

    // ---------------------------------------------------------------- ADR-011: asymmetric quarantine

    function test_lowAgreementDrop_isNotQuarantined() public {
        _nextHop();
        // Real crash while Chainlink lags (outlier): score 71 < 80, -15% jump. Must pass so liquidations stay timely.
        pyth.setPrice(P * 85 / 100);
        red.setPrice(P * 85 / 100);
        dex.setPrice(P * 85 / 100);
        osm.poke();
        assertEq(_nxt(), P * 85 / 100);
        assertEq(osm.pending(), 0);
        assertEq(osm.status(), osm.LIVE());
    }

    function test_sustainedRise_confirmedEvenIfStillMoving() public {
        _nextHop();
        pyth.setPrice(P * 11 / 10);
        red.setPrice(P * 11 / 10);
        osm.poke(); // +10%, low agreement -> held back
        assertEq(osm.pending(), P * 11 / 10);
        _nextHop();
        pyth.setPrice(P * 125 / 100);
        red.setPrice(P * 125 / 100);
        cl.setPrice(P);
        dex.setPrice(P);
        osm.poke(); // still rising on a later hop -> confirmed and accepted
        assertGt(_nxt(), P);
        assertEq(osm.pending(), 0);
    }

    // ---------------------------------------------------------------- V4: zero-price trap removed

    function test_void_disabled() public {
        vm.expectRevert(SmartOSM.VoidDisabled.selector);
        osm.void();
    }

    // ---------------------------------------------------------------- Maker surface

    function test_toll_and_kissDiss() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("OSM/contract-not-whitelisted");
        osm.peek();

        address[] memory a = new address[](2);
        a[0] = stranger;
        a[1] = makeAddr("other");
        osm.kiss(a);
        assertEq(osm.bud(stranger), 1);
        osm.diss(a);
        assertEq(osm.bud(stranger), 0);
    }

    function test_stop_blocksPoke_andStatus() public {
        osm.stop();
        assertEq(osm.status(), osm.STOPPED());
        _nextHop();
        vm.expectRevert("OSM/is-stopped");
        osm.poke();
        osm.start();
        osm.poke();
    }

    function test_admin_onlyWards() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(Auth.NotAuthorized.selector);
        osm.change(address(1));
        vm.expectRevert(Auth.NotAuthorized.selector);
        osm.stop();
        vm.expectRevert(Auth.NotAuthorized.selector);
        osm.kiss(address(1));
        vm.stopPrank();
    }

    function test_step_and_file() public {
        osm.step(1800);
        assertEq(osm.hop(), 1800);
        osm.file("jumpLimitBps", 300);
        assertEq(osm.jumpLimitBps(), 300);
        vm.expectRevert(SmartOSM.UnknownParam.selector);
        osm.file("nope", 1);
    }

    // ---------------------------------------------------------------- fuzz: zero-price invariant

    function testFuzz_peekAlwaysValid(uint256[6] memory moves, bool[6] memory stale) public {
        for (uint256 k; k < 6; ++k) {
            _nextHop();
            uint256 p = bound(moves[k], 1e15, 1e30);
            if (stale[k]) vm.warp(block.timestamp + 26 hours);
            else _all(p);
            osm.poke();
            (uint256 v, bool has) = _peek();
            assertTrue(has);
            assertGt(v, 0);
            assertEq(spotter.lastVal() == 0 && spotter.pokes() > 0, false, "Spotter never sees 0");
        }
    }
}
