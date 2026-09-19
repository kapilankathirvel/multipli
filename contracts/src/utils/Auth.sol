// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Maker-style `wards` authorization, shared by all OracleGuard contracts.
abstract contract Auth {
    mapping(address => uint256) public wards;

    event Rely(address indexed usr);
    event Deny(address indexed usr);

    error NotAuthorized();

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth() {
        if (wards[msg.sender] != 1) revert NotAuthorized();
        _;
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
}
