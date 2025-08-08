// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0x9D7f74d0C41E726EC95884E0e97Fa6129e3b5E99);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xAAC129A3e6e9f44147951dDD5655d66c312A4713);
    }
}