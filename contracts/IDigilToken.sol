// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title Interface for Digil Token (NFT)
/// @notice Interface for the DigilToken contract used for the creation, charging, and activation of Digital Sigils on the Ethereum Blockchain
interface IDigilToken is IERC721, IERC721Receiver {
    // Events
    event Configure(uint256 coinRate, uint256 incrementalValue, uint256 transferValue, uint16 batchSize);
    event OptStatus(address indexed account, bool optOut);
    event Whitelist(address indexed account, uint256 indexed tokenId);
    event Restrict(uint256 indexed tokenId, bool indexed restricted);
    event Update(uint256 indexed tokenId);
    event Batch(uint256 indexed tokenId);
    event Activate(uint256 indexed tokenId);
    event Deactivate(uint256 indexed tokenId);
    event Charge(address indexed addr, uint256 indexed tokenId, uint256 coins, uint256 value);
    event ActiveCharge(uint256 indexed tokenId, uint256 coins);
    event Discharge(uint256 indexed tokenId);
    event Link(uint256 indexed tokenId, uint256 indexed linkId, uint8 efficiency, uint256 affinityBonus);
    event Unlink(uint256 indexed tokenId, uint256 indexed linkId);
    event Buff(uint256 indexed tokenId);
    event Contribute(address indexed addr, uint256 indexed tokenId, uint256 value);
    event Enrich(uint256 indexed tokenId, uint256 value);
    event Reclaim(address indexed addr, uint256 indexed tokenId, uint256 value);

    // Errors
    error InsufficientFunds(uint256 required);
    error CoinTransferFailed(uint256 coins);
    error InsufficientActiveCharge(uint256 required);

    // Public and External Functions

    // Configuration
    function configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize) external;

    // Withdraw
    function withdraw() external returns (uint256 coins, uint256 value);

    // Opt In / Opt Out
    function setOptStatus(bool optOut) external payable;

    // ERC721 Receiver
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4);

    // Reclaim Contribution
    function reclaimContribution(uint256 tokenId) external payable;

    // Vault Token
    function vaultToken(address account, uint256 externalTokenId, bytes calldata data) external;

    // Recall Token
    function recallToken(address account, uint256 externalTokenId) external;

    // Token Information
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function tokenCharge(uint256 tokenId) external view returns (uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold);
    function tokenData(uint256 tokenId) external view returns (bool active, bool activating, bool discharging, bool restricted, uint256 links, uint256 contributors, uint256 contributionEpoch, uint256 distributionIndex, bytes memory data);
    function tokenBuff(uint256 tokenId) external view returns (uint40 expiresAt, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance);
    function tokenContribution(uint256 tokenId, address contributor) external view returns (uint256 charge, uint256 discharge, uint256 value, bool exists, bool whitelisted, uint256 epoch);
    function tokenLinkAt(uint256 tokenId, uint256 index) external view returns (uint256 linkId, uint8 baseEfficiency, uint256 affinityBonus);
    function tokenAttachment(uint256 tokenId) external view returns (address contractTokenAddress, uint256 externalTokenId, bool recallable, bool vaulted); 

    // Token Creation
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes calldata data) external payable returns (uint256 tokenId);

    // Restrict Token
    function restrictToken(uint256 tokenId, address[] memory whitelisted) external payable;

    // Update Token
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data, string calldata uri) external payable;

    // Charge Token
    function chargeToken(uint256 tokenId, uint256 coins) external payable returns (bool);
    function chargeTokenAs(address contributor, uint256 tokenId, uint256 coins) external payable returns (bool);

    // Discharge Token
    function dischargeToken(uint256 tokenId) external payable returns (bool);

    // Activate Token
    function activateToken(uint256 tokenId) external returns (bool);

    // Deactivate Token
    function deactivateToken(uint256 tokenId) external;

    // Link Token
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) external payable;

    // Unlink Token
    function unlinkToken(uint256 tokenId, uint256 linkId) external;

    // Buff Token
    function buffToken(uint256 tokenId, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance, uint256 duration) external;

    // Stabilize Token
    function stabilizeToken(uint256 tokenId) external;

    // Prime Token
    function primeToken(uint256 tokenId) external;

    // Overcharge Token
    function overchargeToken(uint256 tokenId, uint256 coins) external payable;

    // Create Value (Admin Function)
    function createValue(uint256 tokenId, uint256 value) external payable;
}
