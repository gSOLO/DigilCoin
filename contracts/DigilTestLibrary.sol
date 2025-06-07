// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.29;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0x7EF2e0048f5bAeDe046f6BF797943daF4ED8CB47);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xE3Ca443c9fd7AF40A2B5a95d43207E763e56005F);
    }
}