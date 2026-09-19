// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPip} from "../../src/interfaces/IMaker.sol";

/// @notice Minimal Spotter stand-in: `poke` reads the pip exactly like Maker's Spotter (has ? val : 0).
contract MockSpotter {
    address public pip;
    uint256 public lastVal;
    uint256 public pokes;

    function setPip(address pip_) external {
        pip = pip_;
    }

    function poke(bytes32) external {
        (bytes32 val, bool has) = IPip(pip).peek();
        lastVal = has ? uint256(val) : 0;
        pokes++;
    }
}
