// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xC588fFb141b4cFc405BD87BB4793C49eAA4E9Bf5);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0x86BA8f41279c2B029EE140698D09c0766A71419f);
    }
}