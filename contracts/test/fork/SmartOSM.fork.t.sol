// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {OracleGuardAggregator} from "../../src/OracleGuardAggregator.sol";
import {ChainlinkSource} from "../../src/sources/ChainlinkSource.sol";
import {MockSource} from "../../src/sources/MockSource.sol";
import {SmartOSM} from "../../src/SmartOSM.sol";

/// @notice Drop-in proof on the REAL rwaUSD contracts: Spotter, Vat, Dog and Clipper run on SmartOSM unchanged.
contract SmartOSMForkTest is ForkBase {
    OracleGuardAggregator agg;
    MockSource pyth;
    MockSource red;
    MockSource dex;
    SmartOSM osm;
    uint256 legacyPrice;

    function setUp() public override {
        super.setUp();
        ChainlinkSource cl = new ChainlinkSource(C.CL_PAXG_USD, 25 hours, "Chainlink PAXG/USD");
        pyth = new MockSource("Pyth (mock)");
        red = new MockSource("RedStone (mock)");
        dex = new MockSource("DEX TWAP (mock)");
        agg = new OracleGuardAggregator();
        agg.addSource(IPriceSource(address(cl)), 2, 25 hours);
        agg.addSource(IPriceSource(address(pyth)), 2, 1 hours);
        agg.addSource(IPriceSource(address(red)), 2, 1 hours);
        agg.addSource(IPriceSource(address(dex)), 1, 1 hours);
        _mocks(cl.observe().price);

        osm = new SmartOSM(address(agg), C.SPOTTER, C.ILK);
        (legacyPrice,) = legacyCur();
        osm.init(legacyPrice);
        address[] memory buds = new address[](3);
        (buds[0], buds[1], buds[2]) = (C.SPOTTER, C.CLIPPER_PAXG, C.END);
        osm.kiss(buds);

        // The spell's core step: swap the pip (the only change to the core system).
        vm.prank(C.ADMIN_SAFE);
        spotter.file(C.ILK, "pip", address(osm));
        spotter.poke(C.ILK);
    }

    function _mocks(uint256 p) internal {
        pyth.setPrice(p);
        red.setPrice(p);
        dex.setPrice(p);
    }

    function _pokeOsm() internal {
        uint256 next = uint256(osm.zzz()) + osm.hop();
        if (block.timestamp < next) vm.warp(next);
        osm.poke();
    }

    function test_swap_noDiscontinuity() public view {
        (address pip, uint256 m) = spotter.ilks(C.ILK);
        assertEq(pip, address(osm));
        (,, uint256 spot,,) = ilkParams();
        // spot = price * 1e9 / par / mat (RAY); par = 1 RAY here
        assertApproxEqRel(spot, _expectedSpot(legacyPrice, m), 1e12);
        console2.log("Vat spot after swap (price/mat, $):", spot / C.RAY);
    }

    /// @dev Spotter: spot = rdiv(rdiv(val * 1e9, par), mat)
    function _expectedSpot(uint256 priceWad, uint256 m) internal view returns (uint256) {
        return priceWad * 1e9 * C.RAY / spotter.par() * C.RAY / m;
    }

    /// @dev Like the demo keeper: refresh the fast sources, then poke once the hop has passed.
    function _keeperPoke(uint256 marketPrice) internal {
        uint256 next = uint256(osm.zzz()) + osm.hop();
        if (block.timestamp < next) vm.warp(next);
        _mocks(marketPrice);
        osm.poke();
    }

    function test_poke_propagatesToVatAtomically() public {
        uint256 up = legacyPrice * 102 / 100;
        _keeperPoke(up); // nxt = +2%
        _keeperPoke(up); // cur = +2%, and Spotter.poke ran inside SmartOSM.poke
        (,, uint256 spot,,) = ilkParams();
        assertApproxEqRel(spot, _expectedSpot(up, mat()), 1e14, "Vat spot updated without a separate Spotter.poke");
        console2.log("Vat price after 2 hops (spot*mat, $):", spot * mat() / C.RAY / C.RAY);
    }

    function test_staleSources_vatNeverSeesZero() public {
        vm.warp(block.timestamp + 26 hours); // everything stale, incl. Chainlink
        _pokeOsm(); // skipped, no revert
        spotter.poke(C.ILK); // anyone can still poke the Spotter
        (,, uint256 spot,,) = ilkParams();
        assertGt(spot, 0, "zero-price trap avoided");
        assertEq(osm.status(), osm.STALE(), "and the staleness is visible for the controller");
    }

    function test_liquidations_stillWork_onRealCrash() public {
        // A vault at 145%, then a REAL -15% crash that every source agrees on.
        address victim = makeAddr("victim");
        openVault(victim, 10 ether, 0);
        (uint256 ink,) = vat.urns(C.ILK, victim);
        frobAs(victim, 0, int256(ink * legacyPrice / 145e16));

        _mocks(legacyPrice * 85 / 100);
        vm.mockCall(
            C.CL_PAXG_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(legacyPrice * 85 / 100 / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
        _pokeOsm(); // nxt = crash (full agreement: no quarantine)
        vm.mockCall(
            C.CL_PAXG_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(2), int256(legacyPrice * 85 / 100 / 1e10), block.timestamp + 1 hours, block.timestamp + 1 hours, uint80(2))
        );
        _mocks(legacyPrice * 85 / 100);
        _pokeOsm(); // cur = crash -> Vat spot (atomic)

        // Real Dog + real Clipper read the price through SmartOSM (Clipper is a bud) and start the auction.
        uint256 id = dog.bark(C.ILK, victim, address(this));
        assertGt(id, 0, "Clipper kicked with SmartOSM as pip");
    }

    function test_gas_poke() public {
        uint256 next = uint256(osm.zzz()) + osm.hop();
        vm.warp(next);
        uint256 g = gasleft();
        osm.poke();
        console2.log("SmartOSM.poke() gas (incl. aggregator + Spotter.poke):", g - gasleft());
    }
}
