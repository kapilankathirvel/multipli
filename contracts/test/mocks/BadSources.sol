// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Observation} from "../../src/interfaces/IPriceSource.sol";

/// @notice A source that violates the never-revert rule: the aggregator must survive it.
contract RevertingSource {
    function sourceName() external pure returns (string memory) {
        return "reverting";
    }

    function observe() external pure returns (Observation memory) {
        revert("boom");
    }
}
