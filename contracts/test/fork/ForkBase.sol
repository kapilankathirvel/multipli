// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Constants as C} from "../../src/Constants.sol";
import {
    IVat, ISpotter, IDog, ILegacyOSM, IPriceFeedAdapter, IGemJoin, IChainlinkFeed, IERC20Min
} from "../../src/interfaces/IMaker.sol";

/// @notice Mainnet-fork base: pins the block and exposes helpers against the REAL rwaUSD contracts.
abstract contract ForkBase is Test {
    IVat internal vat = IVat(C.VAT);
    ISpotter internal spotter = ISpotter(C.SPOTTER);
    IDog internal dog = IDog(C.DOG);
    ILegacyOSM internal legacyOsm = ILegacyOSM(C.LEGACY_OSM);
    IPriceFeedAdapter internal adapter = IPriceFeedAdapter(C.PRICE_ADAPTER);
    IGemJoin internal join = IGemJoin(C.PAXG_JOIN);
    IChainlinkFeed internal clFeed = IChainlinkFeed(C.CL_PAXG_USD);

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), vm.envOr("FORK_BLOCK", uint256(26_011_000)));
        vm.label(C.VAT, "Vat");
        vm.label(C.SPOTTER, "Spotter");
        vm.label(C.DOG, "Dog");
        vm.label(C.CLIPPER_PAXG, "Clipper");
        vm.label(C.LEGACY_OSM, "LegacyOSM");
        vm.label(C.PRICE_ADAPTER, "PriceFeedAdapter");
        vm.label(C.CL_PAXG_USD, "ChainlinkPAXG");
        vm.label(C.PAXG, "PAXG");
        vm.label(C.PAXG_JOIN, "PaxgJoin");
        vm.label(C.ADMIN_SAFE, "AdminSafe");
    }

    // ---------- reads ----------

    /// @dev Legacy OSM `cur` read straight from storage (slot 3), so no `bud` whitelisting is needed.
    function legacyCur() internal view returns (uint256 priceWad, bool has) {
        uint256 raw = uint256(vm.load(C.LEGACY_OSM, bytes32(C.OSM_CUR_SLOT)));
        priceWad = uint128(raw);
        has = (raw >> 128) == 1;
    }

    /// @dev Legacy OSM `peek()` as its real consumer (Spotter is a bud).
    function legacyPeek() internal returns (uint256 priceWad, bool has) {
        vm.prank(C.SPOTTER);
        (bytes32 v, bool h) = legacyOsm.peek();
        return (uint256(v), h);
    }

    function ilkParams() internal view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust) {
        return vat.ilks(C.ILK);
    }

    function mat() internal view returns (uint256 m) {
        (, m) = spotter.ilks(C.ILK);
    }

    function chainlinkAge() internal view returns (uint256) {
        (,,, uint256 updatedAt,) = clFeed.latestRoundData();
        return block.timestamp - updatedAt;
    }

    // ---------- actions ----------

    /// @dev Warp to the next hop boundary and poke the legacy OSM, then propagate to the Vat.
    function pokeLegacy() internal {
        uint256 next = uint256(legacyOsm.zzz()) + legacyOsm.hop();
        if (block.timestamp < next) vm.warp(next);
        legacyOsm.poke();
        spotter.poke(C.ILK);
    }

    /// @dev Give `who` PAXG, join it and lock `inkWad` as collateral, drawing `daiWad` of rwaUSD (internal Vat dai).
    function openVault(address who, uint256 inkWad, uint256 daiWad) internal {
        deal(C.PAXG, who, inkWad);
        vm.startPrank(who);
        IERC20Min(C.PAXG).approve(C.PAXG_JOIN, inkWad);
        join.join(who, inkWad);
        uint256 gemBal = vat.gem(C.ILK, who); // PAXG may charge a transfer fee; lock what actually arrived
        vm.stopPrank();
        frobAs(who, int256(gemBal), int256(daiWad));
    }

    /// @dev Draw (daiWad>0) or repay (daiWad<0) rwaUSD and add/remove collateral for `who`'s urn.
    function frobAs(address who, int256 dinkWad, int256 daiWad) internal {
        (, uint256 rate,,,) = ilkParams();
        int256 dart = daiWad >= 0 ? int256(uint256(daiWad) * C.RAY / rate) : -int256(uint256(-daiWad) * C.RAY / rate);
        vm.prank(who);
        vat.frob(C.ILK, who, who, who, dinkWad, dart);
    }

    /// @dev Maximum rwaUSD (WAD) the urn can still draw at the current Vat spot (per-urn safety check only).
    function maxDrawWad(address who) internal view returns (uint256) {
        (, uint256 rate, uint256 spot,,) = ilkParams();
        (uint256 ink, uint256 art) = vat.urns(C.ILK, who);
        uint256 capRad = ink * spot; // RAD
        uint256 usedRad = art * rate;
        if (capRad <= usedRad) return 0;
        return (capRad - usedRad) / C.RAY - 1; // WAD, minus 1 wei for rounding
    }

    function toUsd(uint256 wad) internal pure returns (uint256) {
        return wad / C.WAD;
    }
}
