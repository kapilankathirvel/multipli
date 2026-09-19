// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Vat: only what the executors/controller touch (ilks + file "line").
contract MockVat {
    struct Ilk {
        uint256 Art;
        uint256 rate;
        uint256 spot;
        uint256 line;
        uint256 dust;
    }

    mapping(bytes32 => Ilk) public ilks;

    function setIlk(bytes32 ilk, uint256 Art, uint256 rate, uint256 line) external {
        ilks[ilk] = Ilk(Art, rate, 0, line, 0);
    }

    function setArt(bytes32 ilk, uint256 Art) external {
        ilks[ilk].Art = Art;
    }

    function file(bytes32 ilk, bytes32 what, uint256 data) external {
        require(what == "line", "MockVat/file-unrecognized-param");
        ilks[ilk].line = data;
    }
}

/// @notice Minimal Dog: ilks + file "hole".
contract MockDog {
    struct Ilk {
        address clip;
        uint256 chop;
        uint256 hole;
        uint256 dirt;
    }

    mapping(bytes32 => Ilk) public ilks;

    function file(bytes32 ilk, bytes32 what, uint256 data) external {
        require(what == "hole", "MockDog/file-unrecognized-param");
        ilks[ilk].hole = data;
    }
}

contract MockCalendar {
    bool public open = true;

    function setOpen(bool o) external {
        open = o;
    }

    function isOpen(bytes32, uint256) external view returns (bool) {
        return open;
    }
}
