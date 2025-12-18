// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.31;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title Digil Coin (ERC20)
/// @author gSOLO
/// @notice ERC20 governance + utility coin used by DigilToken.
/// @dev Implements OpenZeppelin ERC20Votes (delegation + historical snapshots) and ERC6372-style timestamp clock for Governor compatibility.
///      Role-gated minting and pausing are managed via AccessControl.
/// @custom:security-contact security@digil.co.in
contract DigilCoin is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ERC20Permit, ERC20Votes {
    /// @notice Role allowed to pause/unpause token transfers.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Role allowed to mint new tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param defaultAdmin Address that receives DEFAULT_ADMIN_ROLE, PAUSER_ROLE, and MINTER_ROLE.
    /// @dev DEFAULT_ADMIN_ROLE can grant/revoke all roles, so this should typically be a multisig or timelock.
    constructor(address defaultAdmin) ERC20("Digil Coin", "DIGIL") ERC20Permit("Digil Coin")
    {
        // Establish initial admin and operational roles.
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
    }

    /// @notice Pauses transfers, mints, and burns by activating ERC20Pausable checks.
    /// @dev Only accounts with PAUSER_ROLE can pause.
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses transfers, mints, and burns by deactivating ERC20Pausable checks.
    /// @dev Only accounts with PAUSER_ROLE can unpause.
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Mints new DIGIL to `to`.
    /// @dev Only accounts with MINTER_ROLE can mint. Minting updates ERC20Votes checkpoints via `_update`.
    /// @param to Recipient address.
    /// @param amount Amount of tokens to mint (in wei-like decimals).
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice ERC6372 clock used by OpenZeppelin Votes/Governor for timepoints.
    /// @dev Uses timestamp mode so snapshots are based on `block.timestamp` rather than block number.
    ///      This must match the Governor’s expectation (or be delegated to by the Governor).
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    /// @notice ERC6372 clock mode descriptor.
    /// @dev Signals to off-chain tooling and OZ internals that `clock()` is timestamp-based.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // The following functions are overrides required by Solidity.

    /// @dev Central hook called on transfers, mint, and burn.
    ///      Combines ERC20 core behavior with pause enforcement (ERC20Pausable) and vote checkpointing (ERC20Votes).
    /// @param from Sender address (zero on mint).
    /// @param to Recipient address (zero on burn).
    /// @param value Amount being moved.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable, ERC20Votes) {
        // `super._update` resolves to the linearized implementation that enforces pause rules and updates voting checkpoints.
        super._update(from, to, value);
    }

    /// @notice Returns the current nonce for `owner` used by ERC2612 permit signatures.
    /// @dev Required override because both ERC20Permit and Nonces define `nonces`.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
