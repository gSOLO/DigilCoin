// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xf8e81D47203A594245E36C48e151709F0C19fBe8);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xD7ACd2a9FD159E69Bb102A1ca21C9a3e3A5F771B);
    }
}