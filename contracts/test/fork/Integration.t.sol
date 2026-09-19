// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {RiskController} from "../../src/RiskController.sol";
import {DeployLib} from "../../script/DeployLib.sol";
import {MockCalendar} from "../mocks/MockCore.sol";

/// @notice K7: teammates' components (Varun's SessionCalendar / PythSource) plug in through DeployLib.wireExtras
///         with no other change. Stand-ins are used here; the real contracts implement the same frozen interfaces.
contract IntegrationForkTest is ForkBase {
    DeployLib.Deployment d;
    MockCalendar calendar;
    MockSource realPyth; // stand-in for Varun's PythSource (IPriceSource)

    function setUp() public override {
        super.setUp();
        (uint256 P,) = legacyCur();
        DeployLib.Deployment memory dm = DeployLib.deploy(P);
        address oldPyth = dm.pyth;

        calendar = new MockCalendar();
        realPyth = new MockSource("Pyth PAXG/USD (real adapter stand-in)");
        realPyth.setPrice(P);
        DeployLib.wireExtras(dm, address(calendar), address(realPyth)); // updates the memory struct in place
        assertTrue(dm.pyth == address(realPyth) && dm.pyth != oldPyth);
        assertEq(dm.calendar, address(calendar));
        d = dm;

        vm.startPrank(C.ADMIN_SAFE);
        DeployLib.spell(d);
        vm.stopPrank();
    }

    function test_pythReplaced_weightsAndScoreUnchanged() public view {
        OracleGuardAggregator agg = OracleGuardAggregator(d.aggregator);
        assertEq(agg.sourceCount(), 4);
        assertEq(agg.totalWeight(), 7, "weights 2/2/2/1 preserved");
        bool found;
        for (uint256 i; i < 4; ++i) {
            (address src, uint16 w, uint32 maxAge) = agg.sourceAt(i);
            if (src == address(realPyth)) {
                found = true;
                assertEq(w, 2);
                assertEq(maxAge, 1 hours);
            }
        }
        assertTrue(found, "new Pyth source wired");
        assertEq(agg.read().score, 100);
    }

    function test_calendarWired_closedMarketGivesYellow() public {
        RiskController ctl = RiskController(d.controller);
        assertEq(address(ctl.calendar()), address(calendar));

        // A market-hours asset (e.g. tokenized equity): the Safe sets a sessionAsset on the ilk config.
        RiskController.IlkCfg memory c = ctl.config(C.ILK);
        c.sessionAsset = "tslax";
        vm.prank(C.ADMIN_SAFE);
        ctl.setIlk(C.ILK, c);

        calendar.setOpen(false);
        ctl.sync(C.ILK);
        (uint8 state,,,,) = ctl.status(C.ILK);
        assertEq(state, ctl.YELLOW(), "market closed -> YELLOW (borrowing capped)");
    }

    function test_noExtras_isNoop() public {
        (uint256 P,) = legacyCur();
        DeployLib.Deployment memory d2 = DeployLib.deploy(P);
        address pythBefore = d2.pyth;
        DeployLib.wireExtras(d2, address(0), address(0));
        assertEq(d2.pyth, pythBefore);
        assertEq(d2.calendar, address(0));
    }
}
