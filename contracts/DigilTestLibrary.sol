// SPDX-License-Identifier: GPL-3.0
        
pragma solidity >=0.4.22 <0.9.0;

import "./IDigilToken.sol";

library DigilTestLibrary {
    function getCoins() public pure returns (IERC20) {
        return IERC20(0x9d83e140330758a8fFD07F8Bd73e86ebcA8a5692);
    }
    function getToken() public pure returns (IDigilToken) {
        return IDigilToken(0xD4Fc541236927E2EAf8F27606bD7309C1Fc2cbee);
    }
}