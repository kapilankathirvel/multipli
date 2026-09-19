// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ILineExecutor} from "../interfaces/IPriceSource.sol";
import {IVat} from "../interfaces/IMaker.sol";
import {Auth} from "../utils/Auth.sol";

/// @notice The ONLY OracleGuard contract that is a Vat ward. It can write exactly one parameter,
///         `Vat.ilks[ilk].line`, and never above the governance-set cap (bounded authority).
contract LineExecutor is ILineExecutor, Auth {
    IVat public immutable vat;
    mapping(bytes32 => uint256) public cap; // RAD

    event CapSet(bytes32 indexed ilk, uint256 capRad);
    event LineSet(bytes32 indexed ilk, uint256 lineRad);

    error AboveCap();

    constructor(address vat_) {
        vat = IVat(vat_);
    }

    function setCap(bytes32 ilk, uint256 capRad) external auth {
        cap[ilk] = capRad;
        emit CapSet(ilk, capRad);
    }

    function setLine(bytes32 ilk, uint256 lineRad) external auth {
        if (lineRad > cap[ilk]) revert AboveCap();
        vat.file(ilk, "line", lineRad);
        emit LineSet(ilk, lineRad);
    }
}
