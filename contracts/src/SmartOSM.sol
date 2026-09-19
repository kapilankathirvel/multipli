// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISmartOSM, IOracleGuardAggregator, Reading} from "./interfaces/IOracleGuard.sol";
import {ISpotter} from "./interfaces/IMaker.sol";
import {Auth} from "./utils/Auth.sol";

/// @notice Drop-in replacement for Maker's OSM (same external ABI, so Spotter, Clipper and End work unchanged),
///         fed by the OracleGuardAggregator instead of a single feed.
///
/// What changes vs the legacy OSM (docs/PROBLEM.md):
///  - V1  staleness is no longer silent: `lastGoodAt`, `age()`, `status()` expose it (the RiskController acts on it)
///  - V4  zero-price invariant: after `init`, `peek()` ALWAYS returns (price > 0, true); `void()` is disabled
///  - V5/V6 a large UPWARD jump without broad agreement is quarantined and needs confirmation on a later hop
///  - V12 `poke()` propagates to the Vat atomically (calls `Spotter.poke`)
contract SmartOSM is ISmartOSM, Auth {
    struct Feed {
        uint128 val;
        uint128 has;
    }

    // Status codes (frozen in ISmartOSM)
    uint8 public constant UNINIT = 0;
    uint8 public constant LIVE = 1;
    uint8 public constant STALE = 2;
    uint8 public constant QUARANTINED = 3;
    uint8 public constant STOPPED = 4;

    // PokeSkipped reasons
    uint8 public constant SKIP_NO_QUORUM = 1;
    uint8 public constant SKIP_AGGREGATOR_FAILED = 2;

    ISpotter public immutable spotter;
    bytes32 public immutable ilk;

    // --- Maker OSM storage surface ---
    uint256 public stopped;
    address public src; // the OracleGuardAggregator
    uint16 public hop = 3600;
    uint64 public zzz;
    mapping(address => uint256) public bud;
    Feed internal cur;
    Feed internal nxt;

    // --- OracleGuard extensions ---
    uint64 public lastGoodAt;
    uint256 public staleLimit = 2 hours; // status STALE after this long without an accepted update
    uint256 public jumpLimitBps = 500; // moves above 5% vs `nxt`...
    uint256 public jumpMinScore = 80; // ...need at least this confidence, otherwise quarantine
    uint256 public pending; // quarantined candidate (0 = none)
    uint64 public pendingSince;
    Reading internal lastReading_;

    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event Stop();
    event Start();
    event Change(address indexed src);
    event Step(uint16 hop);
    event File(bytes32 indexed what, uint256 data);

    error AlreadyInitialized();
    error NotInitialized();
    error BadPrice();
    error VoidDisabled();
    error UnknownParam();

    modifier toll() {
        require(bud[msg.sender] == 1, "OSM/contract-not-whitelisted");
        _;
    }

    modifier stoppable() {
        require(stopped == 0, "OSM/is-stopped");
        _;
    }

    constructor(address aggregator_, address spotter_, bytes32 ilk_) {
        src = aggregator_;
        spotter = ISpotter(spotter_);
        ilk = ilk_;
    }

    // ---------------------------------------------------------------- lifecycle

    /// @notice Prime cur = nxt = `priceWad` (the legacy OSM's current price), so the swap causes no discontinuity.
    function init(uint256 priceWad) external auth {
        if (cur.has == 1) revert AlreadyInitialized();
        if (priceWad == 0 || priceWad > type(uint128).max) revert BadPrice();
        cur = nxt = Feed(uint128(priceWad), 1);
        lastGoodAt = uint64(block.timestamp);
        zzz = prev(block.timestamp);
        emit Init(priceWad);
    }

    function poke() external stoppable {
        require(pass(), "OSM/not-passed");
        if (cur.has != 1) revert NotInitialized();

        Reading memory r;
        try IOracleGuardAggregator(src).read() returns (Reading memory rr) {
            r = rr;
        } catch {
            emit PokeSkipped(SKIP_AGGREGATOR_FAILED, 0);
            return;
        }
        lastReading_ = r;

        // No quorum: keep serving the last good price (never 0), but the age now grows -> STALE -> RED.
        // zzz is NOT advanced, so anyone can retry as soon as sources recover.
        if (!r.ok || r.mid == 0) {
            emit PokeSkipped(SKIP_NO_QUORUM, r.score);
            return;
        }

        // Asymmetric quarantine (ADR-011): only a low-agreement UPWARD jump is held back, because an inflated
        // collateral price is what enables over-borrowing. Downward moves pass immediately so liquidations stay
        // timely in a real crash (found by the Black Thursday / LUNA replays); an unfairly LOW price is handled by
        // the RiskController's liquidation guard instead. A held-back rise is confirmed if a LATER hop still shows it.
        uint256 ref = nxt.val;
        if (r.mid > ref && _bps(r.mid, ref) > jumpLimitBps && r.score < jumpMinScore && pending == 0) {
            // Withhold ONLY the suspicious new value; the already-vetted `nxt` still advances into `cur`,
            // so the 1h pipeline keeps flowing (otherwise the Vat would lag the market by 2h+).
            cur = nxt;
            pending = r.mid;
            pendingSince = uint64(block.timestamp);
            zzz = prev(block.timestamp); // consume this hop: confirmation must come from a later one
            emit Quarantined(r.mid, ref, r.score);
            try spotter.poke(ilk) {} catch {}
            return;
        }

        cur = nxt;
        nxt = Feed(uint128(r.mid), 1); // r.mid <= aggregator MAX_PRICE (1e36) < 2^128
        pending = 0;
        pendingSince = 0;
        zzz = prev(block.timestamp);
        lastGoodAt = uint64(block.timestamp);
        emit Poke(bytes32(uint256(cur.val)), zzz);

        try spotter.poke(ilk) {} catch {} // atomic propagation to Vat.spot
    }

    // ---------------------------------------------------------------- Maker OSM reads

    function pass() public view returns (bool) {
        return block.timestamp >= uint256(zzz) + hop;
    }

    function peek() external view toll returns (bytes32, bool) {
        return (bytes32(uint256(cur.val)), cur.has == 1);
    }

    function peep() external view toll returns (bytes32, bool) {
        return (bytes32(uint256(nxt.val)), nxt.has == 1);
    }

    function read() external view toll returns (bytes32) {
        require(cur.has == 1, "OSM/no-current-value");
        return bytes32(uint256(cur.val));
    }

    // ---------------------------------------------------------------- OracleGuard reads (not toll-gated)

    function price() external view returns (uint256 curWad, uint256 nxtWad, uint64 lastGood) {
        return (cur.val, nxt.val, lastGoodAt);
    }

    function age() public view returns (uint256) {
        return cur.has == 1 ? block.timestamp - lastGoodAt : type(uint256).max;
    }

    function status() external view returns (uint8) {
        if (cur.has != 1) return UNINIT;
        if (stopped != 0) return STOPPED;
        if (pending != 0) return QUARANTINED;
        if (age() > staleLimit) return STALE;
        return LIVE;
    }

    function lastReading() external view returns (Reading memory) {
        return lastReading_;
    }

    // ---------------------------------------------------------------- admin (Maker OSM surface)

    function stop() external auth {
        stopped = 1;
        emit Stop();
    }

    function start() external auth {
        stopped = 0;
        emit Start();
    }

    /// @dev In production this must sit behind a timelock (finding V5).
    function change(address src_) external auth {
        src = src_;
        emit Change(src_);
    }

    function step(uint16 ts) external auth {
        require(ts > 0, "OSM/ts-is-zero");
        hop = ts;
        emit Step(ts);
    }

    /// @notice Disabled: zeroing the price makes Spotter set spot = 0 and every vault liquidatable (V4 / ADR-004).
    function void() external auth {
        revert VoidDisabled();
    }

    function kiss(address a) public auth {
        require(a != address(0), "OSM/no-contract-0");
        bud[a] = 1;
        emit Kiss(a);
    }

    function kiss(address[] calldata a) external auth {
        for (uint256 i; i < a.length; ++i) {
            kiss(a[i]);
        }
    }

    function diss(address a) public auth {
        bud[a] = 0;
        emit Diss(a);
    }

    function diss(address[] calldata a) external auth {
        for (uint256 i; i < a.length; ++i) {
            diss(a[i]);
        }
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "staleLimit") staleLimit = data;
        else if (what == "jumpLimitBps") jumpLimitBps = data;
        else if (what == "jumpMinScore") jumpMinScore = data;
        else revert UnknownParam();
        emit File(what, data);
    }

    // ---------------------------------------------------------------- helpers

    function prev(uint256 ts) internal view returns (uint64) {
        return uint64(ts - (ts % hop));
    }

    /// @dev |a - b| / b in bps (b > 0 after init).
    function _bps(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a > b ? a - b : b - a) * 1e4 / b;
    }
}
