// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface to allow calling the mint function on the ERC20 token
interface IERC20Mintable is IERC20 {
    function mint(address to, uint256 amount) external;
}
