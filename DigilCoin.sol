// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Digil Coin (ERC20)
/// @author gSOLO
/// @notice ERC20 contract used to facilitate actions with the Digil Token
/// @custom:security-contact security@digil.co.in
contract DigilCoin is ERC20, ERC20Pausable, Ownable, ERC20Permit {
    constructor(address initialOwner) ERC20("Digil Coin", "DIGIL") Ownable(initialOwner) ERC20Permit("Digil Coin")
    {
        _mint(initialOwner, 8208008028 * 10 ** decimals());
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}