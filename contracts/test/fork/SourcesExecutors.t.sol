// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {Observation} from "../../src/interfaces/IPriceSource.sol";
import {ChainlinkSource} from "../../src/sources/ChainlinkSource.sol";
import {LineExecutor} from "../../src/executors/LineExecutor.sol";
import {HoleExecutor} from "../../src/executors/HoleExecutor.sol";
import {Auth} from "../../src/utils/Auth.sol";

/// @notice K1 on the real fork: ChainlinkSource reads the live PAXG/USD feed; executors move the real Vat/Dog params.
contract SourcesExecutorsForkTest is ForkBase {
    ChainlinkSource cl;
    LineExecutor lineExec;
    HoleExecutor holeExec;
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        cl = new ChainlinkSource(C.CL_PAXG_USD, 25 hours, "Chainlink PAXG/USD");
        lineExec = new LineExecutor(C.VAT);
        holeExec = new HoleExecutor(C.DOG);

        // Governance (the Admin Safe) authorises the executors: exactly what the spell will do.
        vm.startPrank(C.ADMIN_SAFE);
        vat.rely(address(lineExec));
        dog.rely(address(holeExec));
        vm.stopPrank();

        lineExec.setCap(C.ILK, 1_000_000 * C.RAD);
        holeExec.setCap(C.ILK, 400_000 * C.RAD);
    }

    function test_chainlinkSource_readsRealFeed() public view {
        Observation memory o = cl.observe();
        (uint256 legacy,) = legacyCur();
        assertTrue(o.ok, "ok");
        assertApproxEqRel(o.price, legacy, 0.02e18, "matches the legacy OSM price");
        assertTrue(cl.boundsEnabled(), "bounds discovered on the aggregator");
        assertEq(cl.decimals(), 8);
        console2.log("ChainlinkSource price ($):", o.price / C.WAD);
        console2.log("round age (h):", (block.timestamp - o.updatedAt) / 3600);
    }

    function test_lineExecutor_movesRealVatLine() public {
        (uint256 Art, uint256 rate,,,) = ilkParams();
        uint256 debtRad = Art * rate;

        lineExec.setLine(C.ILK, debtRad); // RED: freeze new debt
        (,,, uint256 line,) = ilkParams();
        assertEq(line, debtRad);

        // New borrowing now reverts on the real Vat...
        address user = makeAddr("user");
        openVault(user, 1 ether, 0);
        (, uint256 r,,,) = ilkParams();
        vm.prank(user);
        vm.expectRevert("Vat/ceiling-exceeded");
        vat.frob(C.ILK, user, user, user, 0, int256(1000 * C.RAY / r));

        lineExec.setLine(C.ILK, 1_000_000 * C.RAD); // back to GREEN
        (,,, line,) = ilkParams();
        assertEq(line, 1_000_000 * C.RAD);
    }

    function test_lineExecutor_boundedByCap() public {
        vm.expectRevert(LineExecutor.AboveCap.selector);
        lineExec.setLine(C.ILK, 1_000_000 * C.RAD + 1);
    }

    function test_holeExecutor_pausesRealLiquidations() public {
        holeExec.setHole(C.ILK, 0);
        (,, uint256 hole,) = dog.ilks(C.ILK);
        assertEq(hole, 0);

        vm.expectRevert(HoleExecutor.AboveCap.selector);
        holeExec.setHole(C.ILK, 400_000 * C.RAD + 1);
    }

    function test_executors_onlyWards() public {
        vm.startPrank(stranger);
        vm.expectRevert(Auth.NotAuthorized.selector);
        lineExec.setLine(C.ILK, 0);
        vm.expectRevert(Auth.NotAuthorized.selector);
        holeExec.setHole(C.ILK, 0);
        vm.expectRevert(Auth.NotAuthorized.selector);
        lineExec.setCap(C.ILK, type(uint256).max);
        vm.stopPrank();
    }
}
