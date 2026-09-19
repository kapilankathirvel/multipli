// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase, console2} from "./ForkBase.sol";
import {Constants as C} from "../../src/Constants.sol";
import {IChainlinkFeed} from "../../src/interfaces/IMaker.sol";
import {EvilFeed} from "../mocks/EvilFeed.sol";

/// @notice BASELINE: attacks that SUCCEED against the unmodified, deployed rwaUSD oracle stack.
///         Each of these must fail once OracleGuard is installed (see OracleGuard.t.sol, Phase 3).
contract BaselineTest is ForkBase {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");
    address internal keeper = makeAddr("keeper");

    /// S1: the Chainlink feed goes silent for 7 days. The adapter correctly reports (0,false),
    ///     but the OSM ignores it, keeps `has = true`, and the Vat keeps lending against a week-old price.
    function test_Baseline_S1_staleForever_mintStillAllowed() public {
        (uint256 priceBefore,) = legacyCur();
        (,, uint256 spotBefore,,) = ilkParams();

        vm.warp(block.timestamp + 7 days);

        // Adapter knows the price is stale...
        (, bool adapterOk) = adapter.peek();
        assertFalse(adapterOk, "adapter flags stale");

        // ...but the OSM poke silently no-ops and the Vat price is unchanged.
        pokeLegacy();
        (uint256 priceAfter, bool has) = legacyPeek();
        (,, uint256 spotAfter,,) = ilkParams();
        assertTrue(has, "legacy OSM still says VALID");
        assertEq(priceAfter, priceBefore, "same price after 7 days");
        assertEq(spotAfter, spotBefore, "same Vat spot");

        // Attacker borrows against the 7-day-old price.
        openVault(attacker, 10 ether, 0);
        uint256 draw = maxDrawWad(attacker);
        frobAs(attacker, 0, int256(draw));
        assertApproxEqRel(vat.rwaUSD(attacker), draw * C.RAY, 1e9, "minted against stale price"); // art is rate-normalised

        console2.log("=== S1 BASELINE: stale price accepted ===");
        console2.log("Chainlink round age (hours):", chainlinkAge() / 3600);
        console2.log("Legacy OSM still valid at ($):", priceAfter / C.WAD);
        console2.log("rwaUSD minted against it:", toUsd(draw));
    }

    /// S3: the oracle feed is swapped to an attacker-controlled feed (compromised / colluding 4-of-8 Safe,
    ///     no timelock). Two OSM hops later the Vat prices PAXG at 10x and the attacker over-mints.
    function test_Baseline_S3_feedSwap_overMint() public {
        (uint256 truePrice,) = legacyCur();
        (, int256 clAnswer,,,) = IChainlinkFeed(C.CL_PAXG_USD).latestRoundData();
        EvilFeed evil = new EvilFeed(clAnswer * 10);

        vm.prank(C.ADMIN_SAFE);
        adapter.setPriceFeed(address(evil));

        pokeLegacy(); // nxt = 10x
        pokeLegacy(); // cur = 10x -> Vat spot
        (uint256 osmPrice,) = legacyPeek();
        assertApproxEqRel(osmPrice, truePrice * 10, 0.01e18, "OSM now reports 10x");

        uint256 ink = 10 ether;
        openVault(attacker, ink, 0);
        uint256 draw = maxDrawWad(attacker);
        frobAs(attacker, 0, int256(draw));

        (uint256 lockedInk,) = vat.urns(C.ILK, attacker);
        uint256 realCollateralUsd = lockedInk * truePrice / C.WAD / C.WAD;
        uint256 mintedUsd = toUsd(draw);
        assertGt(mintedUsd, realCollateralUsd * 5, "minted > 5x real collateral value");

        console2.log("=== S3 BASELINE: compromised feed drains the protocol ===");
        console2.log("Real collateral value ($):", realCollateralUsd);
        console2.log("rwaUSD minted ($):", mintedUsd);
        console2.log("Bad debt created ($):", mintedUsd - realCollateralUsd);
    }

    /// S4: a -15% wick is captured by the OSM, the market recovers, but the Vat still uses the low price
    ///     for an hour+, so a vault that is healthy at the TRUE price gets liquidated (stale-low direction).
    function test_Baseline_S4_capturedWick_unfairLiquidation() public {
        (uint256 truePrice,) = legacyCur();
        uint256 m = mat();

        // Victim vault at ~145% collateralisation at the true price.
        uint256 ink = 10 ether;
        openVault(victim, ink, 0);
        (uint256 lockedInk,) = vat.urns(C.ILK, victim);
        uint256 debt = lockedInk * truePrice / 145e16; // WAD, CR = 145%
        frobAs(victim, 0, int256(debt));

        // Wick: Chainlink reports -15% (fresh) exactly when the OSM samples it.
        (uint80 rid, int256 ans,,,) = IChainlinkFeed(C.CL_PAXG_USD).latestRoundData();
        int256 wick = ans * 85 / 100;
        vm.mockCall(
            C.CL_PAXG_USD,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(rid + 1, wick, block.timestamp, block.timestamp, rid + 1)
        );
        pokeLegacy(); // nxt = wick
        vm.clearMockedCalls(); // market recovers; Chainlink back to the true price
        pokeLegacy(); // cur = wick (captured) -> Vat spot is 15% low for the next hour

        (uint256 osmPrice,) = legacyPeek();
        assertLt(osmPrice, truePrice * 90 / 100, "OSM serves the captured wick");

        // True collateralisation is still ~145% > mat (140%): the vault is healthy...
        uint256 trueCr = lockedInk * truePrice / debt; // WAD
        assertGt(trueCr * C.RAY / C.WAD, m, "healthy at true price");

        // ...but it gets liquidated anyway.
        vm.prank(keeper);
        uint256 id = dog.bark(C.ILK, victim, keeper);
        assertGt(id, 0, "auction started");

        console2.log("=== S4 BASELINE: healthy vault liquidated on a stale-low price ===");
        console2.log("True price ($):", truePrice / C.WAD);
        console2.log("OSM price used ($):", osmPrice / C.WAD);
        console2.log("Victim CR at true price (%):", trueCr * 100 / C.WAD);
        console2.log("Collateral seized (PAXG, wei):", lockedInk);
    }
}
