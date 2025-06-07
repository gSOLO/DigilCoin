// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0x7EF2e0048f5bAeDe046f6BF797943daF4ED8CB47);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xDA0bab807633f07f013f94DD0E6A4F96F8742B53);
    }
}