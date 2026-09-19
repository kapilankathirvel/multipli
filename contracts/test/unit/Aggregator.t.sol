// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceSource, Observation} from "../../src/interfaces/IPriceSource.sol";
import {Reading} from "../../src/interfaces/IOracleGuard.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {Auth} from "../../src/utils/Auth.sol";
import {RevertingSource} from "../mocks/BadSources.sol";

contract AggregatorTest is Test {
    OracleGuardAggregator agg;
    MockSource[4] src;
    uint256 constant P = 4372e18;
    uint32 constant MAX_AGE = 1 hours;

    function setUp() public {
        vm.warp(10_000_000);
        agg = new OracleGuardAggregator();
        for (uint256 i; i < 4; ++i) {
            src[i] = new MockSource(string(abi.encodePacked("S", vm.toString(i))));
            agg.addSource(IPriceSource(address(src[i])), 1, MAX_AGE);
            src[i].setPrice(P);
        }
    }

    function _prices(uint256 a, uint256 b, uint256 c, uint256 d) internal {
        src[0].setPrice(a);
        src[1].setPrice(b);
        src[2].setPrice(c);
        src[3].setPrice(d);
    }

    // ---------------------------------------------------------------- happy path

    function test_allAgree_fullScore() public view {
        Reading memory r = agg.read();
        assertTrue(r.ok);
        assertEq(r.mid, P);
        assertEq(r.lo, P);
        assertEq(r.hi, P);
        assertEq(r.nFresh, 4);
        assertEq(r.nInliers, 4);
        assertEq(r.score, 100);
    }

    function test_smallNoise_stillGreen() public {
        _prices(P, P * 10005 / 10000, P * 9998 / 10000, P * 10002 / 10000); // ±0.05%
        Reading memory r = agg.read();
        assertEq(r.nInliers, 4);
        assertGe(r.score, 80);
    }

    // ---------------------------------------------------------------- manipulation (S3)

    function test_singleManipulatedSource_isRejected() public {
        src[3].setPrice(P * 10); // compromised source reports 10x
        Reading memory r = agg.read();
        assertEq(r.mid, P, "median unaffected");
        assertEq(r.hi, P, "outlier not in band");
        assertEq(r.nInliers, 3);
        assertEq(r.score, 75, "Wq = 3/4 -> YELLOW, not a halt");
        (, bool[] memory fresh, bool[] memory inlier) = agg.observations();
        assertTrue(fresh[3]);
        assertFalse(inlier[3]);
    }

    function test_twoOfFourDisagree_scoreCollapses() public {
        _prices(P, P, P * 12 / 10, P * 12 / 10); // 2 vs 2, 20% apart: no honest majority
        Reading memory r = agg.read();
        assertEq(r.score, 0, "dispersion >= dMax => Wd = 0");
    }

    // ---------------------------------------------------------------- staleness (S1)

    function test_oneStale_otherAgree_yellowNotHalt() public {
        src[0].set(P, 0, uint64(block.timestamp - 2 hours), true); // older than maxAge
        Reading memory r = agg.read();
        assertTrue(r.ok);
        assertEq(r.nFresh, 3);
        assertEq(r.score, 75);
    }

    function test_allStale_notOk() public {
        vm.warp(block.timestamp + 2 hours);
        Reading memory r = agg.read();
        assertFalse(r.ok);
        assertEq(r.score, 0);
        assertEq(r.nFresh, 0);
    }

    function test_belowQuorum_notOk() public {
        src[0].setOk(false);
        src[1].setOk(false);
        src[2].setOk(false);
        Reading memory r = agg.read();
        assertEq(r.nInliers, 1);
        assertFalse(r.ok);
        assertEq(r.score, 0);
    }

    function test_freshnessGraceBand() public {
        vm.warp(block.timestamp + 30 minutes); // exactly maxAge/2: still full Wf
        assertEq(agg.read().score, 100);
        vm.warp(block.timestamp + 15 minutes); // 3/4 of maxAge: Wf = 0.5
        assertEq(agg.read().score, 50);
    }

    function test_freshestInlierDrivesFreshness() public {
        // One very old-but-valid source must not drag the score down (ADR-009).
        agg.addSource(IPriceSource(address(new MockSource("slowChainlink"))), 1, 25 hours);
        MockSource slow = MockSource(address(_lastSource()));
        slow.set(P, 0, uint64(block.timestamp - 18 hours), true);
        Reading memory r = agg.read();
        assertEq(r.nInliers, 5);
        assertEq(r.score, 100);
        assertEq(r.freshestAge, 0);
    }

    // ---------------------------------------------------------------- dispersion + weights

    function test_dispersionReducesScore() public {
        _prices(P, P, P * 1005 / 1000, P * 1005 / 1000); // 0.5% spread -> Wd = 0.75
        Reading memory r = agg.read();
        assertEq(r.nInliers, 4);
        assertApproxEqAbs(r.score, 75, 1);
    }

    function test_weightedMedianFavoursHeavySource() public {
        OracleGuardAggregator w = new OracleGuardAggregator();
        MockSource a = new MockSource("heavy");
        MockSource b = new MockSource("light1");
        MockSource c = new MockSource("light2");
        w.addSource(IPriceSource(address(a)), 5, MAX_AGE);
        w.addSource(IPriceSource(address(b)), 1, MAX_AGE);
        w.addSource(IPriceSource(address(c)), 1, MAX_AGE);
        w.file("madK", 100); // disable outlier filtering for this test
        a.setPrice(1001e18);
        b.setPrice(1000e18);
        c.setPrice(1000e18);
        assertEq(w.read().mid, 1001e18);
    }

    // ---------------------------------------------------------------- robustness

    function test_revertingSource_isIgnored() public {
        agg.addSource(IPriceSource(address(new RevertingSource())), 1, MAX_AGE);
        Reading memory r = agg.read();
        assertTrue(r.ok);
        assertEq(r.nFresh, 4);
        assertEq(r.mid, P);
    }

    function test_absurdPrice_isIgnored() public {
        src[3].setPrice(type(uint256).max);
        Reading memory r = agg.read();
        assertEq(r.nFresh, 3);
        assertEq(r.mid, P);
    }

    function test_noSources_notOk() public {
        OracleGuardAggregator empty = new OracleGuardAggregator();
        Reading memory r = empty.read();
        assertFalse(r.ok);
        assertEq(r.mid, 0);
    }

    // ---------------------------------------------------------------- admin

    function test_admin() public {
        assertEq(agg.sourceCount(), 4);
        (address s0, uint16 w0, uint32 m0) = agg.sourceAt(0);
        assertEq(s0, address(src[0]));
        assertEq(w0, 1);
        assertEq(m0, MAX_AGE);

        agg.removeSource(0);
        assertEq(agg.sourceCount(), 3);
        (s0,,) = agg.sourceAt(0);
        assertEq(s0, address(src[3]), "swap-and-pop");

        vm.expectRevert(OracleGuardAggregator.BadParam.selector);
        agg.addSource(IPriceSource(address(src[0])), 0, MAX_AGE);
        vm.expectRevert(OracleGuardAggregator.UnknownParam.selector);
        agg.file("nope", 1);

        agg.file("quorumMin", 3);
        assertEq(agg.quorumMin(), 3);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Auth.NotAuthorized.selector);
        agg.addSource(IPriceSource(address(src[0])), 1, MAX_AGE);
    }

    function test_maxSources() public {
        for (uint256 i = agg.sourceCount(); i < agg.MAX_SOURCES(); ++i) {
            agg.addSource(IPriceSource(address(src[0])), 1, MAX_AGE);
        }
        vm.expectRevert(OracleGuardAggregator.TooManySources.selector);
        agg.addSource(IPriceSource(address(src[0])), 1, MAX_AGE);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_invariants(uint256[4] memory prices, bool[4] memory oks, uint32[4] memory ages) public {
        for (uint256 i; i < 4; ++i) {
            uint256 age = bound(ages[i], 0, 3 hours);
            src[i].set(bound(prices[i], 0, 1e40), 0, uint64(block.timestamp - age), oks[i]);
        }
        Reading memory r = agg.read(); // must never revert
        assertLe(r.score, 100);
        assertLe(r.nInliers, r.nFresh);
        if (r.ok) {
            assertLe(r.lo, r.mid);
            assertLe(r.mid, r.hi);
            assertGe(r.nInliers, agg.quorumMin());
        } else {
            assertEq(r.score, 0);
        }
    }

    function _lastSource() internal view returns (address s) {
        (s,,) = agg.sourceAt(agg.sourceCount() - 1);
    }
}
