// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Settable Chainlink-shaped feed + aggregator (min/max bounds) for unit tests.
contract MockChainlinkFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals = 8;
    int192 public minAnswer;
    int192 public maxAnswer;
    bool public revertOnRead;

    constructor(int256 answer_, int192 minAnswer_, int192 maxAnswer_) {
        answer = answer_;
        updatedAt = block.timestamp;
        minAnswer = minAnswer_;
        maxAnswer = maxAnswer_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRevert(bool r) external {
        revertOnRead = r;
    }

    /// @dev The feed doubles as its own aggregator, so bounds are discoverable like a real proxy.
    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!revertOnRead, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
