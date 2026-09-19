// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

struct PythStructsPrice {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

interface IPyth {
    function getPriceUnsafe(bytes32 id) external view returns (PythStructsPrice memory price);
}
