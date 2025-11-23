// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface to allow calling the mint function on the ERC20 token
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}
