// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Chainlink-shaped feed controlled by an attacker (models a compromised / mis-configured feed).
///         Always reports a "fresh" round so the legacy PriceFeedAdapter accepts it.
contract EvilFeed {
    int256 public answer;

    constructor(int256 answer_) {
        answer = answer_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
