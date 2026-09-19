// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Verified Ethereum-mainnet addresses and units (see docs/ONCHAIN_FACTS.md, verified 2026-09-19).
library Constants {
    bytes32 internal constant ILK = "paxg";

    address internal constant VAT = 0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C;
    address internal constant SPOTTER = 0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2;
    address internal constant DOG = 0x15a36d5cAf263160c2a49DDE6429C045Fb711dDD;
    address internal constant CLIPPER_PAXG = 0x62B7a353928142A18C07026A33F8089d1c7378F4;
    address internal constant END = 0x026782F431bfC233c67128af42a4e9De7f834BF5;
    address internal constant VOW = 0x7815e8e9BCEF8708A799eE3802586298e5AFA611;
    address internal constant LEGACY_OSM = 0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a;
    address internal constant OSM_MOM = 0x58B377160283C5B8446B6AD0f2a2D62490E8621a;
    address internal constant PRICE_ADAPTER = 0x82F5790Bd1c96790E4c3a3ebC8142bD4D6F8b1CD;
    address internal constant CL_PAXG_USD = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
    address internal constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address internal constant PAXG_JOIN = 0x3c9567C3b9c20E72858cD5714209EA7D7a8011fD;
    address internal constant ADMIN_SAFE = 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99;

    /// @dev Storage slot of `cur` in Maker's osm.sol (val = low 128 bits, has = high 128 bits). Slot 4 = `nxt`.
    uint256 internal constant OSM_CUR_SLOT = 3;
    uint256 internal constant OSM_NXT_SLOT = 4;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant RAD = 1e45;
}
