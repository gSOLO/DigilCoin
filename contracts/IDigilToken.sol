// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Interface for Digil Token (NFT)
/// @notice Interface for the DigilToken contract used for the creation, charging, and activation of Digital Sigils on the Ethereum Blockchain
interface IDigilToken is IERC721, IERC721Receiver {
    // Events
    event Configure(uint256 coinRate, uint256 incrementalValue, uint256 transferValue, uint16 batchSize);
    event OptOut(address indexed account);
    event OptIn(address indexed account);
    event Whitelist(address indexed account, uint256 indexed tokenId);
    event Create(uint256 indexed tokenId);
    event Restrict(uint256 indexed tokenId);
    event Update(uint256 indexed tokenId);
    event Activate(uint256 indexed tokenId, bool complete);
    event Deactivate(uint256 indexed tokenId);
    event Charge(address indexed addr, uint256 indexed tokenId, uint256 coins);
    event ActiveCharge(uint256 indexed tokenId, uint256 coins);
    event Discharge(uint256 indexed tokenId, bool complete);
    event Link(uint256 indexed tokenId, uint256 indexed linkId);
    event Link(uint256 indexed tokenId, uint256 indexed linkId, uint8 efficiency, uint256 affinityBonus);
    event Unlink(uint256 indexed tokenId, uint256 indexed linkId);
    event ContractDistribution(uint256 value);
    event PendingDistribution(address indexed addr, uint256 coins, uint256 value);
    event Contribute(address indexed addr, uint256 indexed tokenId, uint256 value);
    event ContributeValue(address indexed addr, uint256 indexed tokenId, uint256 value);
    event ContributeValue(uint256 indexed tokenId, uint256 value);

    // Errors
    error InsufficientFunds(uint256 required);
    error CoinTransferFailed(uint256 coins);

    // Structs (for external visibility if needed)
    struct Distribution {
        uint256 time;   // Timestamp of the last distribution or withdrawal
        uint256 coins;  // Pending coins to be distributed
        uint256 value;  // Pending Ether value to be distributed
    }

    struct TokenContribution {
        uint256 charge;     // Coins contributed to the token's charge
        uint256 value;      // Ether value contributed
        bool exists;        // Indicates if the contributor has contributed
        bool distributed;   // Indicates if the contribution has been distributed
        bool whitelisted;   // Indicates if the contributor is whitelisted
    }

    struct ContractToken {
        uint256 tokenId;    // ID of the external ERC721 token
        bool recallable;    // Indicates if the token can be recalled
    }

    struct LinkEfficiency {
        uint8 base;             // Base efficiency percentage for coin transfer
        uint256 affinityBonus;  // Additional bonus based on plane affinity
    }

    // Public and External Functions

    // Configuration
    function configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize) external;

    // Pending Distribution
    function pendingDistribution(address addr) external view returns(uint256 coins, uint256 value, uint256 time);

    // Withdraw
    function withdraw() external payable returns (uint256 coins, uint256 value);

    // Opt In / Opt Out
    function setOptStatus(bool optOut) external payable;

    // Rescue Token
    function rescueToken(uint256 tokenId, address to) external;

    // ERC721 Receiver
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4);

    // Recall Token
    function recallToken(address account, uint256 tokenId) external;

    // Token Information
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function tokenCharge(uint256 tokenId) external view returns (uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold);
    function tokenData(uint256 tokenId) external view returns (bool active, bool activating, bool discharging, bool restricted, uint256 links, uint256 contributors, uint256 dischargeIndex, uint256 distributionIndex, bytes memory data);

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
    function deactivateToken(uint256 tokenId) external payable;

    // Link Token
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) external payable;

    // Unlink Token
    function unlinkToken(uint256 tokenId, uint256 linkId) external;

    // Create Value (Admin Function)
    function createValue(uint256 tokenId, uint256 value) external payable;
}