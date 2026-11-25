// SPDX-License-Identifier: MIT
pragma solidity ^0.8.39;

import {IERC20Mintable} from "contracts/IERC20Mintable.sol";

/// @notice Mintable DIGIL with explicit, allowance-backed feature-fee rewards.
interface IDigilCoin is IERC20Mintable {
    /// @notice Pays the caller a nonrefundable fee; its configured weight determines reward eligibility.
    /// @dev Weighted callers are trusted to use this only for fees, never refundable deposits.
    function spendFrom(address payer, uint256 amount) external returns (bool);
}
