// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource, Observation} from "../interfaces/IPriceSource.sol";
import {IPyth, PythStructsPrice} from "../interfaces/IPyth.sol";

/// @notice Fetches prices from the Pyth Network pull oracle.
contract PythSource is IPriceSource {
    IPyth public immutable pyth;
    bytes32 public immutable feedId;
    uint256 public immutable maxConfBps;
    string public name;

    constructor(address pyth_, bytes32 feedId_, uint256 maxConfBps_, string memory name_) {
        pyth = IPyth(pyth_);
        feedId = feedId_;
        maxConfBps = maxConfBps_;
        name = name_;
    }

    function sourceName() external view returns (string memory) {
        return name;
    }

    function observe() external view returns (Observation memory obs) {
        try pyth.getPriceUnsafe(feedId) returns (PythStructsPrice memory p) {
            if (p.price <= 0) {
                return obs; // ok = false
            }
            
            // Pyth price is represented as price * 10^expo.
            // We need to convert this to WAD (18 decimals).
            uint256 priceWad;
            uint256 confWad;
            
            if (p.expo < 0) {
                uint256 shift = uint256(int256(-p.expo));
                if (shift > 18) {
                    priceWad = uint256(int256(p.price)) / (10 ** (shift - 18));
                    confWad = p.conf / (10 ** (shift - 18));
                } else {
                    priceWad = uint256(int256(p.price)) * (10 ** (18 - shift));
                    confWad = p.conf * (10 ** (18 - shift));
                }
            } else {
                uint256 shift = uint256(int256(p.expo));
                priceWad = uint256(int256(p.price)) * (10 ** (18 + shift));
                confWad = p.conf * (10 ** (18 + shift));
            }
            
            obs.price = priceWad;
            obs.conf = confWad;
            obs.updatedAt = uint64(p.publishTime);
            
            // Revert if confidence is too wide: (conf / price) > (maxConfBps / 10000)
            // Equivalent to: conf * 10000 > price * maxConfBps
            if (confWad * 10000 > maxConfBps * priceWad) {
                return obs; // ok = false
            }
            
            obs.ok = true;
        } catch {
            // Returns obs with ok = false
        }
    }
}
