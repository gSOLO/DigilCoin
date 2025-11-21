// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xd9145CCE52D386f254917e481eB44e9943F39138);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xd7Ca4e99F7C171B9ea2De80d3363c47009afaC5F);
    }
}