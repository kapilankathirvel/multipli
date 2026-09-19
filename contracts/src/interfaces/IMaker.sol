// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Minimal interfaces to the deployed rwaUSD (Maker-fork, solc 0.6.12) core.
// Units: WAD = 1e18, RAY = 1e27, RAD = 1e45.

interface IVat {
    function ilks(bytes32)
        external
        view
        returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
    function urns(bytes32, address) external view returns (uint256 ink, uint256 art);
    function gem(bytes32, address) external view returns (uint256);
    function rwaUSD(address) external view returns (uint256); // Maker `dai(address)` renamed in this fork (RAD)
    function sin(address) external view returns (uint256);
    function Line() external view returns (uint256);
    function debt() external view returns (uint256);
    function live() external view returns (uint256);
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external;
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function slip(bytes32 ilk, address usr, int256 wad) external;
    function hope(address) external;
    function rely(address) external;
    function deny(address) external;
    function wards(address) external view returns (uint256);
}

interface ISpotter {
    function ilks(bytes32) external view returns (address pip, uint256 mat);
    function par() external view returns (uint256);
    function poke(bytes32 ilk) external;
    function file(bytes32 ilk, bytes32 what, address pip_) external;
    function wards(address) external view returns (uint256);
}

interface IDog {
    function ilks(bytes32) external view returns (address clip, uint256 chop, uint256 hole, uint256 dirt);
    function Hole() external view returns (uint256);
    function Dirt() external view returns (uint256);
    function bark(bytes32 ilk, address urn, address kpr) external returns (uint256 id);
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function rely(address) external;
    function deny(address) external;
    function wards(address) external view returns (uint256);
}

interface IPip {
    function peek() external view returns (bytes32, bool);
    function read() external view returns (bytes32);
}

interface ILegacyOSM is IPip {
    function poke() external;
    function pass() external view returns (bool);
    function hop() external view returns (uint16);
    function zzz() external view returns (uint64);
    function src() external view returns (address);
    function peep() external view returns (bytes32, bool);
    function wards(address) external view returns (uint256);
    function bud(address) external view returns (uint256);
}

interface IPriceFeedAdapter is IPip {
    function owner() external view returns (address);
    function maxDelay() external view returns (uint256);
    function priceFeed() external view returns (address);
    function setPriceFeed(address) external;
}

interface IGemJoin {
    function join(address usr, uint256 wad) external;
    function exit(address usr, uint256 wad) external;
    function ilk() external view returns (bytes32);
    function gem() external view returns (address);
    function dec() external view returns (uint256);
    function live() external view returns (uint256);
}

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function aggregator() external view returns (address);
}

interface IChainlinkAggregatorBounds {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
