// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Digil Timelock Controller
/// @author gSOLO
/// @notice This contract holds the funds and the "Owner" permissions for the DAO.
/// @custom:security-contact security@digil.co.in
contract DigilTimelock is TimelockController {
    /**
     * @dev Constructor.
     * @param minDelay The minimum time (in seconds) a proposal must wait before execution.
     * @param proposers List of addresses allowed to propose (usually just the Governor).
     * @param executors List of addresses allowed to execute (usually the Governor or address(0)).
     * @param admin The address that can grant/revoke roles (initially you, later the Timelock itself).
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin) TimelockController(minDelay, proposers, executors, admin) {

    }
}