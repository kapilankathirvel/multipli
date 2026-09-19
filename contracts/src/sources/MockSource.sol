// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource, Observation} from "../interfaces/IPriceSource.sol";
import {IMockSource} from "../interfaces/IOracleGuard.sol";
import {Auth} from "../utils/Auth.sol";

/// @notice Scenario-controllable price source: stands in for Pyth / RedStone / DEX TWAP in the demo,
///         behind the same interface a production adapter would implement.
contract MockSource is IPriceSource, IMockSource, Auth {
    Observation internal obs;
    string private name;

    constructor(string memory name_) {
        name = name_;
    }

    function sourceName() external view returns (string memory) {
        return name;
    }

    function observe() external view returns (Observation memory) {
        return obs;
    }

    function set(uint256 price, uint256 conf, uint64 updatedAt, bool ok) external auth {
        obs = Observation(price, conf, updatedAt, ok);
        emit MockSet(price, conf, updatedAt, ok);
    }

    function setPrice(uint256 price) external auth {
        obs = Observation(price, obs.conf, uint64(block.timestamp), true);
        emit MockSet(price, obs.conf, uint64(block.timestamp), true);
    }

    function setOk(bool ok) external auth {
        obs.ok = ok;
        emit MockSet(obs.price, obs.conf, obs.updatedAt, ok);
    }
}
