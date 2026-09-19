// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Observation} from "../../src/interfaces/IPriceSource.sol";
import {ChainlinkSource} from "../../src/sources/ChainlinkSource.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {Auth} from "../../src/utils/Auth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

contract ChainlinkSourceTest is Test {
    MockChainlinkFeed feed;
    ChainlinkSource src;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockChainlinkFeed(4372_00000000, 1, 1_000_000_00000000); // $4372, bounds [$0.00000001, $1M]
        src = new ChainlinkSource(address(feed), 25 hours, "Chainlink");
    }

    function test_convertsTo18Decimals() public view {
        Observation memory o = src.observe();
        assertTrue(o.ok);
        assertEq(o.price, 4372e18);
        assertEq(o.updatedAt, block.timestamp);
        assertEq(src.sourceName(), "Chainlink");
        assertTrue(src.boundsEnabled());
    }

    function test_feedReverts_notOk_noRevert() public {
        feed.setRevert(true);
        Observation memory o = src.observe();
        assertFalse(o.ok);
        assertEq(o.price, 0);
    }

    function test_nonPositiveAnswer_notOk() public {
        feed.set(0, block.timestamp);
        assertFalse(src.observe().ok);
        feed.set(-1, block.timestamp);
        assertFalse(src.observe().ok);
    }

    function test_zeroOrFutureTimestamp_notOk() public {
        feed.set(4372_00000000, 0);
        assertFalse(src.observe().ok);
        feed.set(4372_00000000, block.timestamp + 1);
        assertFalse(src.observe().ok);
    }

    function test_clampedAnswer_reportedButNotOk() public {
        feed.set(1_000_000_00000000, block.timestamp); // pinned at maxAnswer
        Observation memory o = src.observe();
        assertFalse(o.ok);
        assertEq(o.price, 1_000_000e18, "value still visible for the UI");
    }

    function test_staleIsNotJudgedHere() public {
        feed.set(4372_00000000, block.timestamp - 7 days);
        assertTrue(src.observe().ok, "aggregator decides staleness");
    }

    function testFuzz_neverReverts(int256 answer, uint256 updatedAt, bool down) public {
        feed.set(answer, updatedAt);
        feed.setRevert(down);
        src.observe(); // must not revert
    }
}

contract MockSourceTest is Test {
    MockSource src;
    address stranger = makeAddr("stranger");

    function setUp() public {
        src = new MockSource("Pyth (mock)");
    }

    function test_setPrice_stampsNowAndOk() public {
        vm.warp(5000);
        src.setPrice(4000e18);
        Observation memory o = src.observe();
        assertEq(o.price, 4000e18);
        assertEq(o.updatedAt, 5000);
        assertTrue(o.ok);
    }

    function test_setAndSetOk() public {
        src.set(1e18, 2e16, 77, true);
        src.setOk(false);
        Observation memory o = src.observe();
        assertEq(o.price, 1e18);
        assertEq(o.conf, 2e16);
        assertEq(o.updatedAt, 77);
        assertFalse(o.ok);
    }

    function test_onlyWards() public {
        vm.startPrank(stranger);
        vm.expectRevert(Auth.NotAuthorized.selector);
        src.setPrice(1);
        vm.expectRevert(Auth.NotAuthorized.selector);
        src.set(1, 0, 0, true);
        vm.expectRevert(Auth.NotAuthorized.selector);
        src.setOk(true);
        vm.stopPrank();
    }
}
