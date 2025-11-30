// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xf8e81D47203A594245E36C48e151709F0C19fBe8);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8);
    }
}