// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource, Observation} from "../interfaces/IPriceSource.sol";
import {IChainlinkFeed, IChainlinkAggregatorBounds} from "../interfaces/IMaker.sol";

/// @notice Wraps a Chainlink feed as an OracleGuard price source.
/// @dev Never reverts. Staleness is judged by the aggregator (per-source maxAge); this source only rejects
///      values that are malformed or sitting on the aggregator's min/max circuit-breaker clamp (V7).
contract ChainlinkSource is IPriceSource {
    IChainlinkFeed public immutable feed;
    uint8 public immutable decimals;
    uint256 public immutable maxAge; // informational (UI); the aggregator holds the enforced value
    bool public immutable boundsEnabled;
    int256 public immutable minAnswer;
    int256 public immutable maxAnswer;

    string private name;

    constructor(address feed_, uint256 maxAge_, string memory name_) {
        feed = IChainlinkFeed(feed_);
        decimals = IChainlinkFeed(feed_).decimals();
        maxAge = maxAge_;
        name = name_;

        // Clamp bounds live on the underlying aggregator; not every feed exposes them.
        bool enabled;
        int256 lo;
        int256 hi;
        try IChainlinkFeed(feed_).aggregator() returns (address agg) {
            try IChainlinkAggregatorBounds(agg).minAnswer() returns (int192 mn) {
                try IChainlinkAggregatorBounds(agg).maxAnswer() returns (int192 mx) {
                    (enabled, lo, hi) = (true, mn, mx);
                } catch {}
            } catch {}
        } catch {}
        boundsEnabled = enabled;
        minAnswer = lo;
        maxAnswer = hi;
    }

    function sourceName() external view returns (string memory) {
        return name;
    }

    function observe() external view returns (Observation memory o) {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return o; // ok = false
            if (uint256(answer) > type(uint256).max / 1e18) return o; // absurd value: avoid overflow revert
            o.price = uint256(answer) * 1e18 / 10 ** decimals;
            o.updatedAt = uint64(updatedAt);
            // A value pinned at the clamp is not a real price (LUNA-style failure): report it, but not ok.
            o.ok = !(boundsEnabled && (answer <= minAnswer || answer >= maxAnswer));
        } catch {}
    }
}
