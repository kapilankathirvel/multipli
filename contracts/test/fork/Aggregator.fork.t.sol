// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {Reading} from "../../src/interfaces/IOracleGuard.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {ChainlinkSource} from "../../src/sources/ChainlinkSource.sol";
import {MockSource} from "../../src/sources/MockSource.sol";

/// @notice The demo configuration on the real fork: real Chainlink (18h-old round) + 3 fresh mocks.
contract AggregatorForkTest is ForkBase {
    OracleGuardAggregator agg;
    MockSource pyth;
    MockSource redstone;
    MockSource dex;
    uint256 clPrice;

    function setUp() public override {
        super.setUp();
        ChainlinkSource cl = new ChainlinkSource(C.CL_PAXG_USD, 25 hours, "Chainlink PAXG/USD");
        pyth = new MockSource("Pyth (mock)");
        redstone = new MockSource("RedStone (mock)");
        dex = new MockSource("Uniswap v3 TWAP (mock)");

        agg = new OracleGuardAggregator();
        agg.addSource(IPriceSource(address(cl)), 2, 25 hours); // quiet deviation feed: long maxAge
        agg.addSource(IPriceSource(address(pyth)), 2, 1 hours);
        agg.addSource(IPriceSource(address(redstone)), 2, 1 hours);
        agg.addSource(IPriceSource(address(dex)), 1, 1 hours); // thin RWA liquidity: low weight

        clPrice = cl.observe().price;
        pyth.setPrice(clPrice);
        redstone.setPrice(clPrice);
        dex.setPrice(clPrice);
    }

    function test_demoStartsGreen() public view {
        Reading memory r = agg.read();
        assertTrue(r.ok);
        assertEq(r.nInliers, 4);
        assertGe(r.score, 80, "healthy system must start GREEN (ADR-009)");
        assertEq(r.mid, clPrice);
        console2.log("score at fork block:", r.score);
        console2.log("mid ($):", r.mid / C.WAD);
    }

    function test_S1a_chainlinkStale_othersAgree_yellow() public {
        vm.warp(block.timestamp + 7 days);
        pyth.setPrice(clPrice);
        redstone.setPrice(clPrice);
        dex.setPrice(clPrice);
        Reading memory r = agg.read();
        assertTrue(r.ok);
        assertEq(r.nFresh, 3);
        assertLt(r.score, 80);
        assertGe(r.score, 50);
        console2.log("S1a score (Chainlink 7d stale):", r.score);
    }

    function test_S2_marketDrop_chainlinkBecomesOutlier() public {
        uint256 dropped = clPrice * 92 / 100;
        pyth.setPrice(dropped);
        redstone.setPrice(dropped);
        dex.setPrice(dropped);
        Reading memory r = agg.read();
        assertEq(r.mid, dropped, "live price follows the market, not the lagging feed");
        assertEq(r.nInliers, 3);
        console2.log("S2 live mid ($):", r.mid / C.WAD);
    }

    function test_gas_read() public view {
        uint256 g = gasleft();
        agg.read();
        console2.log("read() gas with 4 sources:", g - gasleft());
    }
}
