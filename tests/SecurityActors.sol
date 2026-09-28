// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IDigilCoin} from "../contracts/IDigilCoin.sol";

contract FeeSpender {
    function pay(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.spendFrom(payer, amount));
    }

    function deposit(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.transferFrom(payer, address(this), amount));
    }

    function refund(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.transfer(payer, amount));
    }
}
