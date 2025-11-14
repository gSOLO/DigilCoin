// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xf02A102153DDf132032B7De5D19F43aA049052Dd);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0x6C5b401BcdF3009bDB35613c20f101DF53cc39AC);
    }
}