// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";

/// @notice Sanity: the fork matches docs/ONCHAIN_FACTS.md.
contract HarnessTest is ForkBase {
    function test_liveParamsMatchOnchainFacts() public view {
        (uint256 Art, uint256 rate,, uint256 line, uint256 dust) = ilkParams();
        (address pip, uint256 m) = spotter.ilks(C.ILK);

        assertEq(pip, C.LEGACY_OSM, "pip is legacy OSM");
        assertEq(m, 14e26, "mat = 1.40");
        assertEq(line, 1_000_000 * C.RAD, "line = 1M");
        assertEq(dust, 200 * C.RAD, "dust = 200");
        assertEq(legacyOsm.hop(), 3600, "hop = 1h");
        assertEq(adapter.maxDelay(), 86_400, "maxDelay = 24h");
        assertEq(adapter.owner(), C.ADMIN_SAFE, "adapter owned by Safe");
        assertEq(vat.wards(C.ADMIN_SAFE), 1, "Safe is Vat ward");
        assertEq(spotter.wards(C.ADMIN_SAFE), 1, "Safe is Spotter ward");
        assertEq(dog.wards(C.ADMIN_SAFE), 1, "Safe is Dog ward");
        assertEq(legacyOsm.bud(C.SPOTTER), 1, "Spotter is bud");
        assertEq(legacyOsm.bud(C.CLIPPER_PAXG), 1, "Clipper is bud");
        assertEq(legacyOsm.bud(C.END), 1, "End is bud");

        (uint256 cur, bool has) = legacyCur();
        assertTrue(has, "cur.has");
        assertApproxEqRel(cur, 4372e18, 0.05e18, "cur ~ $4372");

        console2.log("PAXG-A debt (rwaUSD):", Art * rate / C.RAD);
        console2.log("legacy OSM price ($):", cur / C.WAD);
        console2.log("Chainlink round age (h):", chainlinkAge() / 3600);
    }
}
