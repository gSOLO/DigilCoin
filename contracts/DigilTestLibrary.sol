// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDigilToken} from "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0xd9145CCE52D386f254917e481eB44e9943F39138);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8);
    }
}