// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IHoleExecutor} from "../interfaces/IPriceSource.sol";
import {IDog} from "../interfaces/IMaker.sol";
import {Auth} from "../utils/Auth.sol";

/// @notice The ONLY OracleGuard contract that is a Dog ward. It can write exactly one parameter,
///         `Dog.ilks[ilk].hole`, and never above the governance-set cap. `hole = 0` pauses new liquidations.
contract HoleExecutor is IHoleExecutor, Auth {
    IDog public immutable dog;
    mapping(bytes32 => uint256) public cap; // RAD

    event CapSet(bytes32 indexed ilk, uint256 capRad);
    event HoleSet(bytes32 indexed ilk, uint256 holeRad);

    error AboveCap();

    constructor(address dog_) {
        dog = IDog(dog_);
    }

    function setCap(bytes32 ilk, uint256 capRad) external auth {
        cap[ilk] = capRad;
        emit CapSet(ilk, capRad);
    }

    function setHole(bytes32 ilk, uint256 holeRad) external auth {
        if (holeRad > cap[ilk]) revert AboveCap();
        dog.file(ilk, "hole", holeRad);
        emit HoleSet(ilk, holeRad);
    }
}
