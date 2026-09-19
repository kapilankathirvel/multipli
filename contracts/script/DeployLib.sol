// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Constants as C} from "../src/Constants.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {IOracleGuardAggregator, ISmartOSM} from "../src/interfaces/IOracleGuard.sol";
import {IVat, IDog, ISpotter} from "../src/interfaces/IMaker.sol";
import {ChainlinkSource} from "../src/sources/ChainlinkSource.sol";
import {MockSource} from "../src/sources/MockSource.sol";
import {OracleGuardAggregator} from "../src/OracleGuardAggregator.sol";
import {SmartOSM} from "../src/SmartOSM.sol";
import {LineExecutor} from "../src/executors/LineExecutor.sol";
import {HoleExecutor} from "../src/executors/HoleExecutor.sol";
import {RiskController} from "../src/RiskController.sol";

/// @notice Single source of truth for installing OracleGuard. Used by script/Deploy.s.sol + script/Spell.s.sol
///         (live demo) AND by the fork tests, so the demo and the tests install exactly the same system.
library DeployLib {
    struct Deployment {
        address aggregator;
        address smartOsm;
        address controller;
        address lineExecutor;
        address holeExecutor;
        address calendar; // optional (Varun's SessionCalendar, wired at the integration checkpoint)
        address chainlink;
        address pyth;
        address redstone;
        address dexTwap;
    }

    // --- PAXG parameters (review.md §R3) ---
    uint256 internal constant GREEN_GAP = 250_000 * C.RAD;
    uint256 internal constant YELLOW_GAP = 50_000 * C.RAD;

    /// @notice Step 1 (any deployer): deploy + wire OracleGuard. Does NOT touch the Maker core.
    /// @param legacyPriceWad the legacy OSM `cur` (storage slot 3) used to prime SmartOSM without a price jump
    function deploy(uint256 legacyPriceWad) internal returns (Deployment memory d) {
        // Sources: real Chainlink + scenario-controllable stand-ins (docs/DECISIONS.md ADR-003)
        ChainlinkSource cl = new ChainlinkSource(C.CL_PAXG_USD, 25 hours, "Chainlink PAXG/USD");
        MockSource pyth = new MockSource("Pyth PAXG/USD (mock)");
        MockSource red = new MockSource("RedStone PAXG/USD (mock)");
        MockSource dex = new MockSource("Uniswap v3 TWAP (mock)");
        uint256 p = cl.observe().price;
        pyth.setPrice(p);
        red.setPrice(p);
        dex.setPrice(p);

        // Aggregator: weights 2/2/2/1 (review.md §R1.1)
        OracleGuardAggregator agg = new OracleGuardAggregator();
        agg.addSource(IPriceSource(address(cl)), 2, 25 hours);
        agg.addSource(IPriceSource(address(pyth)), 2, 1 hours);
        agg.addSource(IPriceSource(address(red)), 2, 1 hours);
        agg.addSource(IPriceSource(address(dex)), 1, 1 hours);

        // SmartOSM primed from the legacy OSM, readable by the same consumers as the legacy OSM
        SmartOSM osm = new SmartOSM(address(agg), C.SPOTTER, C.ILK);
        osm.init(legacyPriceWad);
        address[] memory buds = new address[](3);
        (buds[0], buds[1], buds[2]) = (C.SPOTTER, C.CLIPPER_PAXG, C.END);
        osm.kiss(buds);

        // Bounded executors + controller
        (,,, uint256 lineCap,) = IVat(C.VAT).ilks(C.ILK);
        (,, uint256 holeCap,) = IDog(C.DOG).ilks(C.ILK);
        LineExecutor lineExec = new LineExecutor(C.VAT);
        HoleExecutor holeExec = new HoleExecutor(C.DOG);
        RiskController ctl = new RiskController(C.VAT, address(lineExec), address(holeExec));
        lineExec.setCap(C.ILK, lineCap);
        holeExec.setCap(C.ILK, holeCap);
        lineExec.rely(address(ctl));
        holeExec.rely(address(ctl));
        ctl.setIlk(C.ILK, config(address(agg), address(osm), lineCap, holeCap));

        // Governance (the Admin Safe) also gets admin rights on every new contract.
        agg.rely(C.ADMIN_SAFE);
        osm.rely(C.ADMIN_SAFE);
        ctl.rely(C.ADMIN_SAFE);
        lineExec.rely(C.ADMIN_SAFE);
        holeExec.rely(C.ADMIN_SAFE);

        d = Deployment({
            aggregator: address(agg),
            smartOsm: address(osm),
            controller: address(ctl),
            lineExecutor: address(lineExec),
            holeExecutor: address(holeExec),
            calendar: address(0),
            chainlink: address(cl),
            pyth: address(pyth),
            redstone: address(red),
            dexTwap: address(dex)
        });
    }

    function config(address agg, address osm, uint256 lineCap, uint256 holeCap)
        internal
        pure
        returns (RiskController.IlkCfg memory)
    {
        return RiskController.IlkCfg({
            agg: IOracleGuardAggregator(agg),
            osm: ISmartOSM(osm),
            sessionAsset: bytes32(0), // PAXG: always open in the MVP
            lineCapRad: lineCap,
            greenGapRad: GREEN_GAP,
            yellowGapRad: YELLOW_GAP,
            holeCapRad: holeCap,
            greenScore: 80,
            yellowScore: 50,
            epsBps: 150,
            epsLiqBps: 300,
            upgradeInterval: 10 minutes,
            kUp: 3,
            guardMaxDuration: 6 hours,
            refillInterval: 1 hours
        });
    }

    /// @notice Step 2 (MUST be executed by the Admin Safe, a ward of Spotter/Vat/Dog): the governance spell.
    ///         The only changes to the Maker core are: the pip swap + authorising two bounded executors.
    function spell(Deployment memory d) internal {
        ISpotter(C.SPOTTER).file(C.ILK, "pip", d.smartOsm);
        IVat(C.VAT).rely(d.lineExecutor);
        IDog(C.DOG).rely(d.holeExecutor);
        ISpotter(C.SPOTTER).poke(C.ILK);
        RiskController(d.controller).sync(C.ILK);
    }

    /// @notice One-call rollback (Admin Safe): back to the legacy oracle; executors lose their rights.
    function rollback(Deployment memory d) internal {
        LineExecutor(d.lineExecutor).setLine(C.ILK, LineExecutor(d.lineExecutor).cap(C.ILK)); // restore the ceiling
        HoleExecutor(d.holeExecutor).setHole(C.ILK, HoleExecutor(d.holeExecutor).cap(C.ILK));
        ISpotter(C.SPOTTER).file(C.ILK, "pip", C.LEGACY_OSM);
        IVat(C.VAT).deny(d.lineExecutor);
        IDog(C.DOG).deny(d.holeExecutor);
        ISpotter(C.SPOTTER).poke(C.ILK);
    }
}
