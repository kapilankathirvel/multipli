// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Constants as C} from "../src/Constants.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Step 2 of the demo: the governance spell, executed AS the Admin Safe (impersonated on anvil).
///
///   cast rpc anvil_setBalance 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99 0x56BC75E2D63100000
///   forge script script/Spell.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
///     --sender 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99
///
///   Rollback: same command with `--sig "rollback()"`.
contract Spell is Script {
    string internal constant IN = "../deployments/fork.json";

    function run() external {
        DeployLib.Deployment memory d = load();
        vm.startBroadcast(C.ADMIN_SAFE);
        DeployLib.spell(d);
        vm.stopBroadcast();
        console2.log("Spell executed: Spotter pip -> SmartOSM", d.smartOsm);
    }

    function rollback() external {
        DeployLib.Deployment memory d = load();
        vm.startBroadcast(C.ADMIN_SAFE);
        DeployLib.rollback(d);
        vm.stopBroadcast();
        console2.log("Rolled back: Spotter pip -> legacy OSM");
    }

    function load() internal view returns (DeployLib.Deployment memory d) {
        string memory json = vm.readFile(IN);
        d.aggregator = vm.parseJsonAddress(json, ".oracleguard.aggregator");
        d.smartOsm = vm.parseJsonAddress(json, ".oracleguard.smartOsm");
        d.controller = vm.parseJsonAddress(json, ".oracleguard.controller");
        d.lineExecutor = vm.parseJsonAddress(json, ".oracleguard.lineExecutor");
        d.holeExecutor = vm.parseJsonAddress(json, ".oracleguard.holeExecutor");
        d.calendar = vm.parseJsonAddress(json, ".oracleguard.calendar");
        d.chainlink = vm.parseJsonAddress(json, ".oracleguard.sources.chainlink");
        d.pyth = vm.parseJsonAddress(json, ".oracleguard.sources.pyth");
        d.redstone = vm.parseJsonAddress(json, ".oracleguard.sources.redstone");
        d.dexTwap = vm.parseJsonAddress(json, ".oracleguard.sources.dexTwap");
    }
}
