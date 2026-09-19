// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PythSource} from "../../src/sources/PythSource.sol";
import {Observation} from "../../src/interfaces/IPriceSource.sol";
import {IPyth, PythStructsPrice} from "../../src/interfaces/IPyth.sol";

contract PythSourceTest is Test {
    PythSource public src;
    
    // Official Pyth Network contract on Ethereum mainnet
    address public constant PYTH_MAINNET = 0x4305FB666EE7FeA854E05F87c2b6107386d4B3C5;
    // PAXG/USD price feed ID
    bytes32 public constant PAXG_USD_FEED = 0x273717b49430906f4b0c230e99aa1007f83758e3199edbc887c0d06c3e332494;

    uint256 public constant FORK_BLOCK = 26_011_000;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);
        src = new PythSource(PYTH_MAINNET, PAXG_USD_FEED, 150, "Pyth PAXG/USD"); // 1.5% max conf
    }

    function test_observe_returnsSanePrice() public {
        Observation memory obs = src.observe();
        
        // Assert ok
        assertTrue(obs.ok, "Pyth source should be ok");
        assertGt(obs.price, 0, "Price should be > 0");
        assertGt(obs.updatedAt, 0, "Should have updatedAt");
        
        // ±10% of $4,372
        uint256 expectedPrice = 4372 * 1e18;
        uint256 minPrice = expectedPrice * 90 / 100;
        uint256 maxPrice = expectedPrice * 110 / 100;
        
        assertGe(obs.price, minPrice, "Price too low");
        assertLe(obs.price, maxPrice, "Price too high");
        
        console2.log("Pyth PAXG price:", obs.price);
        console2.log("Pyth confidence:", obs.conf);
        console2.log("Pyth updatedAt:", obs.updatedAt);
    }
    
    function test_observe_revertingPyth_returnsOkFalse() public {
        // Mock pyth reverting
        vm.mockCallRevert(
            PYTH_MAINNET,
            abi.encodeWithSelector(IPyth.getPriceUnsafe.selector, PAXG_USD_FEED),
            "Pyth revert"
        );
        
        Observation memory obs = src.observe();
        assertFalse(obs.ok, "Should not be ok when Pyth reverts");
        assertEq(obs.price, 0, "Price should be 0");
    }
}
