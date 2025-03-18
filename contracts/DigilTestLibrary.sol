// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.29;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xd9145CCE52D386f254917e481eB44e9943F39138);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xf8e81D47203A594245E36C48e151709F0C19fBe8);
    }
}