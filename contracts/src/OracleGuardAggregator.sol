// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceSource, Observation} from "./interfaces/IPriceSource.sol";
import {IOracleGuardAggregator, Reading} from "./interfaces/IOracleGuard.sol";
import {Auth} from "./utils/Auth.sol";

/// @notice Combines several independent price sources into one robust price plus a 0-100 confidence score.
///
///   fresh_i  = ok_i && age_i <= maxAge_i
///   m0       = weighted median of fresh prices
///   inlier_i = |p_i - m0| <= madK * max(MAD, m0 * madFloor)          (MAD = median |p_i - m0|)
///   mid      = weighted median of inliers;  lo/hi = min/max inlier;  d = (hi - lo) / mid
///   score    = 100 * Wq * Wd * Wf
///     Wq = Σ weight(inliers) / Σ weight(all)    each oracle contributes its weight share (mentor review R1)
///     Wd = max(0, 1 - d / dMax)                   how tightly they agree
///     Wf = 1 while the FRESHEST inlier is <= maxAge/2 old, then linear to 0   (ADR-009)
///   ok = nInliers >= quorumMin   (otherwise score = 0)
///
/// @dev View-only and never reverts on source misbehaviour: every source call is wrapped in try/catch.
contract OracleGuardAggregator is IOracleGuardAggregator, Auth {
    struct SourceCfg {
        IPriceSource src;
        uint16 weight;
        uint32 maxAge;
    }

    uint256 public constant MAX_SOURCES = 8;
    uint256 internal constant BPS = 1e4;
    uint256 public constant MAX_PRICE = 1e36; // anything above is nonsense (and could overflow the maths)

    SourceCfg[] internal sources;

    uint256 public quorumMin = 2; // fewer inliers than this => ok = false, score = 0
    uint256 public dMaxBps = 200; // dispersion (hi-lo)/mid at which Wd reaches 0 (2%)
    uint256 public madK = 3; // outlier threshold multiplier
    uint256 public madFloorBps = 10; // MAD floor as bps of the median (0.1%), so identical sources don't zero the band

    event SourceAdded(address indexed src, uint16 weight, uint32 maxAge);
    event SourceRemoved(address indexed src);
    event File(bytes32 indexed what, uint256 data);

    error TooManySources();
    error BadParam();
    error UnknownParam();

    // ---------------------------------------------------------------- admin

    function addSource(IPriceSource src, uint16 weight, uint32 maxAge) external auth {
        if (sources.length >= MAX_SOURCES) revert TooManySources();
        if (address(src) == address(0) || weight == 0 || maxAge == 0) revert BadParam();
        sources.push(SourceCfg(src, weight, maxAge));
        emit SourceAdded(address(src), weight, maxAge);
    }

    function removeSource(uint256 i) external auth {
        address src = address(sources[i].src);
        sources[i] = sources[sources.length - 1];
        sources.pop();
        emit SourceRemoved(src);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "quorumMin") {
            if (data == 0) revert BadParam();
            quorumMin = data;
        } else if (what == "dMaxBps") {
            if (data == 0) revert BadParam();
            dMaxBps = data;
        } else if (what == "madK") {
            if (data == 0) revert BadParam();
            madK = data;
        } else if (what == "madFloorBps") {
            madFloorBps = data;
        } else {
            revert UnknownParam();
        }
        emit File(what, data);
    }

    // ---------------------------------------------------------------- views

    /// @notice Sum of all configured weights; source i contributes weight_i / totalWeight to price and confidence.
    function totalWeight() public view returns (uint256 w) {
        for (uint256 i; i < sources.length; ++i) {
            w += sources[i].weight;
        }
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function sourceAt(uint256 i) external view returns (address src, uint16 weight, uint32 maxAge) {
        SourceCfg memory c = sources[i];
        return (address(c.src), c.weight, c.maxAge);
    }

    function read() external view returns (Reading memory r) {
        (r,,,) = _compute();
    }

    function observations() external view returns (Observation[] memory obs, bool[] memory fresh, bool[] memory inlier) {
        (, obs, fresh, inlier) = _compute();
    }

    // ---------------------------------------------------------------- core

    function _compute()
        internal
        view
        returns (Reading memory r, Observation[] memory obs, bool[] memory fresh, bool[] memory inlier)
    {
        uint256 n = sources.length;
        inlier = new bool[](n);

        // 1. observe + freshness
        uint256[] memory idx;
        uint256 nFresh;
        (obs, fresh, idx, nFresh) = _observeAll(n);
        r.nFresh = uint8(nFresh);
        if (nFresh == 0) return (r, obs, fresh, inlier);

        // 2-3. robust centre + MAD outlier filter (inliers stay sorted by price)
        _sortByPrice(idx, nFresh, obs);
        (uint256[] memory inl, uint256 nInl, uint256 inlierWeight) = _inliers(idx, nFresh, obs, inlier);
        r.nInliers = uint8(nInl);

        // 4. band
        r.mid = _weightedMedian(inl, nInl, obs);
        r.lo = obs[inl[0]].price;
        r.hi = obs[inl[nInl - 1]].price;
        uint256 freshestMaxAge;
        (r.freshestAge, freshestMaxAge) = _freshest(inl, nInl, obs);

        // 5. score
        r.ok = nInl >= quorumMin;
        if (r.ok) r.score = _score(r, inlierWeight, freshestMaxAge);
    }

    function _observeAll(uint256 n)
        internal
        view
        returns (Observation[] memory obs, bool[] memory fresh, uint256[] memory idx, uint256 nFresh)
    {
        obs = new Observation[](n);
        fresh = new bool[](n);
        idx = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            try sources[i].src.observe() returns (Observation memory o) {
                obs[i] = o;
                if (_isFresh(o, sources[i].maxAge)) {
                    fresh[i] = true;
                    idx[nFresh++] = i;
                }
            } catch {}
        }
    }

    function _isFresh(Observation memory o, uint256 maxAge) internal view returns (bool) {
        return o.ok && o.price > 0 && o.price <= MAX_PRICE && o.updatedAt <= block.timestamp
            && block.timestamp - o.updatedAt <= maxAge;
    }

    function _inliers(uint256[] memory idx, uint256 nFresh, Observation[] memory obs, bool[] memory inlier)
        internal
        view
        returns (uint256[] memory inl, uint256 nInl, uint256 inlierWeight)
    {
        uint256 m0 = _weightedMedian(idx, nFresh, obs);
        uint256[] memory dev = new uint256[](nFresh);
        for (uint256 k; k < nFresh; ++k) {
            dev[k] = _absDiff(obs[idx[k]].price, m0);
        }
        uint256 mad = _median(dev, nFresh);
        uint256 floor_ = m0 * madFloorBps / BPS;
        uint256 thr = madK * (mad > floor_ ? mad : floor_);

        inl = new uint256[](nFresh);
        for (uint256 k; k < nFresh; ++k) {
            uint256 i = idx[k];
            if (_absDiff(obs[i].price, m0) <= thr) {
                inlier[i] = true;
                inl[nInl++] = i;
                inlierWeight += sources[i].weight;
            }
        }
    }

    function _freshest(uint256[] memory inl, uint256 nInl, Observation[] memory obs)
        internal
        view
        returns (uint64 age, uint256 maxAge)
    {
        uint256 best = type(uint256).max;
        for (uint256 k; k < nInl; ++k) {
            uint256 i = inl[k];
            uint256 a = block.timestamp - obs[i].updatedAt;
            if (a < best) (best, maxAge) = (a, sources[i].maxAge);
        }
        age = uint64(best);
    }

    function _score(Reading memory r, uint256 inlierWeight, uint256 maxAge) internal view returns (uint16) {
        uint256 wq = inlierWeight * BPS / totalWeight();
        uint256 dBps = (r.hi - r.lo) * BPS / r.mid;
        uint256 age = r.freshestAge;
        uint256 wd = dBps >= dMaxBps ? 0 : BPS - dBps * BPS / dMaxBps;
        uint256 half = maxAge / 2;
        uint256 wf = age <= half ? BPS : BPS - _min(BPS, (age - half) * BPS / (half == 0 ? 1 : half));
        return uint16(100 * wq * wd * wf / (BPS * BPS * BPS));
    }

    // ---------------------------------------------------------------- math helpers

    /// @dev Insertion sort of the first `n` entries of `idx`, ascending by observed price (n <= MAX_SOURCES).
    function _sortByPrice(uint256[] memory idx, uint256 n, Observation[] memory obs) internal pure {
        for (uint256 a = 1; a < n; ++a) {
            uint256 key = idx[a];
            uint256 p = obs[key].price;
            uint256 b = a;
            while (b > 0 && obs[idx[b - 1]].price > p) {
                idx[b] = idx[b - 1];
                --b;
            }
            idx[b] = key;
        }
    }

    /// @dev `idx[0..n)` must be sorted by price. Returns the first price where cumulative weight reaches half.
    function _weightedMedian(uint256[] memory idx, uint256 n, Observation[] memory obs)
        internal
        view
        returns (uint256)
    {
        uint256 total;
        for (uint256 k; k < n; ++k) {
            total += sources[idx[k]].weight;
        }
        uint256 cum;
        for (uint256 k; k < n; ++k) {
            cum += sources[idx[k]].weight;
            if (cum * 2 >= total) return obs[idx[k]].price;
        }
        return obs[idx[n - 1]].price; // unreachable
    }

    /// @dev Plain median (average of the two middles for even n). Sorts `v[0..n)` in place.
    function _median(uint256[] memory v, uint256 n) internal pure returns (uint256) {
        for (uint256 a = 1; a < n; ++a) {
            uint256 key = v[a];
            uint256 b = a;
            while (b > 0 && v[b - 1] > key) {
                v[b] = v[b - 1];
                --b;
            }
            v[b] = key;
        }
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
