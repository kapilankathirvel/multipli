// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Constants as C} from "../src/Constants.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Step 1 of the demo: deploy OracleGuard on the anvil mainnet fork and write deployments/fork.json.
///
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// The deployer (anvil account #0) keeps admin rights on the MockSources, so the dashboard can drive scenarios.
contract Deploy is Script {
    string internal constant OUT = "../deployments/fork.json";

    function run() external returns (DeployLib.Deployment memory d) {
        // Legacy OSM `cur` (storage slot 3, low 128 bits): prime SmartOSM without a price jump.
        uint256 legacyPrice = uint128(uint256(vm.load(C.LEGACY_OSM, bytes32(C.OSM_CUR_SLOT))));
        require(legacyPrice > 0, "Deploy/no-legacy-price");

        vm.startBroadcast();
        d = DeployLib.deploy(legacyPrice);
        vm.stopBroadcast();

        write(d);
        console2.log("OracleGuard deployed. SmartOSM:", d.smartOsm);
        console2.log("Next: run script/Spell.s.sol as the Admin Safe.");
    }

    /// @dev Writes the FROZEN schema of deployments/fork.example.json.
    function write(DeployLib.Deployment memory d) internal {
        string memory s = "sources";
        vm.serializeAddress(s, "chainlink", d.chainlink);
        vm.serializeAddress(s, "pyth", d.pyth);
        vm.serializeAddress(s, "redstone", d.redstone);
        string memory sources = vm.serializeAddress(s, "dexTwap", d.dexTwap);

        string memory o = "oracleguard";
        vm.serializeAddress(o, "aggregator", d.aggregator);
        vm.serializeAddress(o, "smartOsm", d.smartOsm);
        vm.serializeAddress(o, "controller", d.controller);
        vm.serializeAddress(o, "lineExecutor", d.lineExecutor);
        vm.serializeAddress(o, "holeExecutor", d.holeExecutor);
        vm.serializeAddress(o, "calendar", d.calendar);
        string memory og = vm.serializeString(o, "sources", sources);

        string memory m = "maker";
        vm.serializeAddress(m, "vat", C.VAT);
        vm.serializeAddress(m, "spotter", C.SPOTTER);
        vm.serializeAddress(m, "dog", C.DOG);
        vm.serializeAddress(m, "legacyOsm", C.LEGACY_OSM);
        vm.serializeAddress(m, "adapter", C.PRICE_ADAPTER);
        vm.serializeAddress(m, "chainlinkPaxgUsd", C.CL_PAXG_USD);
        vm.serializeAddress(m, "paxg", C.PAXG);
        string memory maker = vm.serializeAddress(m, "paxgJoin", C.PAXG_JOIN);

        string memory r = "root";
        vm.serializeString(r, "rpc", "http://127.0.0.1:8545");
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeUint(r, "forkBlock", vm.envOr("FORK_BLOCK", uint256(26_011_000)));
        vm.serializeString(r, "ilk", "paxg");
        vm.serializeString(r, "snapshotId", "0x0");
        vm.serializeString(r, "oracleguard", og);
        vm.serializeString(r, "maker", maker);
        string memory json = vm.serializeAddress(r, "adminSafe", C.ADMIN_SAFE);
        vm.writeJson(json, OUT);
    }
}
