// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRiskController, IOracleGuardAggregator, ISmartOSM, Reading} from "./interfaces/IOracleGuard.sol";
import {ILineExecutor, IHoleExecutor, ISessionCalendar} from "./interfaces/IPriceSource.sol";
import {IVat, IDog} from "./interfaces/IMaker.sol";
import {Auth} from "./utils/Auth.sol";

/// @notice Graduated response: maps oracle health to BOUNDED changes of exactly two protocol parameters
///         (review.md §R3). It never touches the price path, `Spotter.mat`, fees or repayments.
///
///   GREEN  : Vat.line = min(debt + greenGap, lineCap), refilled at most once per `refillInterval`
///            (a RATE LIMIT: new debt <= greenGap per interval, even if a correlated failure goes undetected)
///   YELLOW : Vat.line = min(debt_at_entry + yellowGap, lineCap), never raised while YELLOW
///   RED    : Vat.line = debt  -> every mint reverts `Vat/ceiling-exceeded`; repay still works
///   GUARD  : Dog.hole = 0     -> no NEW liquidations while the live market is well ABOVE the delayed OSM
///            price with broad agreement (stale-low / captured wick); auto-expires after `guardMaxDuration`
///
///   Downgrades apply immediately. Upgrades move one level per `kUp` healthy syncs spaced >= `upgradeInterval`.
contract RiskController is IRiskController, Auth {
    uint8 public constant GREEN = 0;
    uint8 public constant YELLOW = 1;
    uint8 public constant RED = 2;

    // SmartOSM status codes (frozen in ISmartOSM)
    uint8 internal constant OSM_LIVE = 1;

    struct IlkCfg {
        IOracleGuardAggregator agg;
        ISmartOSM osm;
        bytes32 sessionAsset; // 0 = always open (no calendar dependency)
        uint256 lineCapRad; // governance debt ceiling (GREEN upper bound)
        uint256 greenGapRad; // max new debt per refillInterval in GREEN
        uint256 yellowGapRad; // max new debt in total while YELLOW
        uint256 holeCapRad; // normal Dog.hole
        uint16 greenScore; // >= this (and no other trigger) -> GREEN
        uint16 yellowScore; // < this -> RED
        uint16 epsBps; // RED if live.lo < osmCur * (1 - eps): market below the delayed price (over-borrow risk)
        uint16 epsLiqBps; // GUARD if live.hi * (1 - epsLiq) > osmCur: market above the delayed price
        uint32 upgradeInterval; // min spacing between counted healthy syncs
        uint8 kUp; // healthy syncs needed per one-level upgrade
        uint32 guardMaxDuration; // guard auto-expiry
        uint32 refillInterval; // GREEN rate-limit window
    }

    struct IlkState {
        uint8 state;
        uint16 score; // score seen at the last sync
        uint8 healthyStreak;
        uint64 lastHealthyCount;
        uint64 lastRefill;
        bool guard;
        bool guardLatched; // guard expired: don't re-arm until the condition clears once
        uint64 guardSince;
    }

    IVat public immutable vat;
    ILineExecutor public immutable lineExec;
    IHoleExecutor public immutable holeExec;
    ISessionCalendar public calendar; // optional (address 0 = markets always open)

    mapping(bytes32 => IlkCfg) internal cfg;
    mapping(bytes32 => IlkState) internal st;

    event IlkConfigured(bytes32 indexed ilk);
    event CalendarSet(address calendar);

    error NotConfigured();
    error BadConfig();

    constructor(address vat_, address lineExec_, address holeExec_) {
        vat = IVat(vat_);
        lineExec = ILineExecutor(lineExec_);
        holeExec = IHoleExecutor(holeExec_);
    }

    // ---------------------------------------------------------------- admin

    function setIlk(bytes32 ilk, IlkCfg calldata c) external auth {
        if (address(c.agg) == address(0) || address(c.osm) == address(0)) revert BadConfig();
        if (c.yellowScore > c.greenScore || c.kUp == 0) revert BadConfig();
        cfg[ilk] = c;
        emit IlkConfigured(ilk);
    }

    function setCalendar(address calendar_) external auth {
        calendar = ISessionCalendar(calendar_);
        emit CalendarSet(calendar_);
    }

    function config(bytes32 ilk) external view returns (IlkCfg memory) {
        return cfg[ilk];
    }

    function ilkState(bytes32 ilk) external view returns (IlkState memory) {
        return st[ilk];
    }

    // ---------------------------------------------------------------- core

    /// @notice Permissionless and idempotent. Keepers call it after every SmartOSM.poke (and whenever they like).
    function sync(bytes32 ilk) external {
        IlkCfg memory c = cfg[ilk];
        if (address(c.agg) == address(0)) revert NotConfigured();
        IlkState memory s = st[ilk];

        Reading memory r = c.agg.read();
        (uint256 osmCur,,) = c.osm.price();

        uint8 prevState = s.state;
        s.state = _nextState(s, _target(c, r, osmCur, c.osm.status()), c.upgradeInterval, c.kUp);
        s.score = r.score;

        (uint256 lineRad,) = _applyLine(ilk, c, s, prevState);
        _applyGuard(ilk, c, s, r, osmCur);

        st[ilk] = s;
        if (s.state != prevState) emit StateChanged(ilk, prevState, s.state);
        emit Synced(ilk, s.state, r.score, r.mid, osmCur, lineRad, s.guard);
    }

    function status(bytes32 ilk)
        external
        view
        returns (uint8 state, uint16 score, bool guard, uint256 lineRad, uint256 debtRad)
    {
        IlkState memory s = st[ilk];
        (uint256 Art, uint256 rate,, uint256 line,) = vat.ilks(ilk);
        return (s.state, s.score, s.guard, line, Art * rate);
    }

    // ---------------------------------------------------------------- state machine

    /// @dev What the state SHOULD be given current evidence (before hysteresis).
    function _target(IlkCfg memory c, Reading memory r, uint256 osmCur, uint8 osmStatus) internal view returns (uint8) {
        if (!r.ok || r.score < c.yellowScore) return RED; // no quorum / low confidence
        if (osmStatus != OSM_LIVE) return RED; // STALE, QUARANTINED, STOPPED or UNINIT
        if (r.lo * 1e4 < osmCur * (1e4 - c.epsBps)) return RED; // market below the delayed price: over-borrow window
        if (r.score < c.greenScore || !_marketOpen(c.sessionAsset)) return YELLOW;
        return GREEN;
    }

    /// @dev Downgrade immediately; upgrade one level after kUp spaced healthy syncs.
    function _nextState(IlkState memory s, uint8 target, uint256 upgradeInterval, uint256 kUp)
        internal
        view
        returns (uint8)
    {
        if (target >= s.state) {
            s.healthyStreak = 0;
            return target; // same or worse
        }
        if (block.timestamp >= uint256(s.lastHealthyCount) + upgradeInterval) {
            s.healthyStreak += 1;
            s.lastHealthyCount = uint64(block.timestamp);
        }
        if (s.healthyStreak >= kUp) {
            s.healthyStreak = 0;
            return s.state - 1;
        }
        return s.state;
    }

    // ---------------------------------------------------------------- levers

    function _applyLine(bytes32 ilk, IlkCfg memory c, IlkState memory s, uint8 prevState)
        internal
        returns (uint256 lineRad, uint256 debtRad)
    {
        uint256 Art;
        uint256 rate;
        (Art, rate,, lineRad,) = vat.ilks(ilk);
        debtRad = Art * rate;

        uint256 target = lineRad;
        if (s.state == RED) {
            target = debtRad; // no new debt
        } else if (s.state == YELLOW) {
            // Anchor on entry, never raise while YELLOW (so repeated syncs can't leak more than yellowGap).
            uint256 cap = _min(debtRad + c.yellowGapRad, c.lineCapRad);
            target = prevState != YELLOW ? cap : _min(lineRad, cap);
        } else if (prevState != GREEN || block.timestamp >= uint256(s.lastRefill) + c.refillInterval) {
            // GREEN: refill the rate-limited headroom at most once per refillInterval.
            target = _min(debtRad + c.greenGapRad, c.lineCapRad);
            s.lastRefill = uint64(block.timestamp);
        }

        if (target != lineRad) {
            lineExec.setLine(ilk, target);
            lineRad = target;
        }
    }

    function _applyGuard(bytes32 ilk, IlkCfg memory c, IlkState memory s, Reading memory r, uint256 osmCur)
        internal
    {
        bool cond = r.ok && r.score >= c.greenScore && r.hi * (1e4 - c.epsLiqBps) > osmCur * 1e4;

        if (!cond) s.guardLatched = false; // condition cleared once: guard may arm again in the future

        if (s.guard) {
            bool expired = block.timestamp > uint256(s.guardSince) + c.guardMaxDuration;
            if (!cond || expired) {
                holeExec.setHole(ilk, c.holeCapRad);
                s.guard = false;
                if (expired && cond) s.guardLatched = true;
                emit GuardOff(ilk, expired);
            }
        } else if (cond && !s.guardLatched) {
            holeExec.setHole(ilk, 0);
            s.guard = true;
            s.guardSince = uint64(block.timestamp);
            emit GuardOn(ilk);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _marketOpen(bytes32 asset) internal view returns (bool) {
        if (asset == bytes32(0) || address(calendar) == address(0)) return true;
        try calendar.isOpen(asset, block.timestamp) returns (bool open) {
            return open;
        } catch {
            return false; // calendar broken -> be cautious (YELLOW), never block repayments
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
