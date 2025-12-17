// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.31;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title Digil Governor
/// @author gSOLO
/// @custom:security-contact security@digil.co.in
contract DigilGovernor is Governor, GovernorSettings, GovernorStorage, GovernorVotes, GovernorTimelockControl, AccessControl {
    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");

    // The NFT Contract used for Gating
    IERC721 public immutable nftGate;

    // Custom Storage for Votes
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
        // Tracks which NFT IDs have been consumed for this proposal
        mapping(uint256 => bool) nftUsed; 
    }

    mapping(uint256 => ProposalVote) private _proposalVotes;

    enum VoteType {
        Against,
        For,
        Abstain
    }

    // Errors

    /// @notice Thrown when params are missing or malformed (need tokenId).
    error InvalidParams();

    /// @notice Thrown when an NFT ID has already been used to vote on this proposal.
    /// @param tokenId The ID that was reused.
    error AlreadyUsedNft(uint256 tokenId);

    error InsufficientApproval(address voter, uint256 tokenId);

    /// @notice Thrown when a user attempts to vote twice on the same proposal.
    /// @param voter The address attempting to vote again.
    error AlreadyCastVote(address voter);

    /// @notice Thrown when an invalid vote type (not Against, For, or Abstain) is submitted.
    error InvalidVoteType();

    /// @notice Thrown when a user tries to use standard castVote functions.
    error VoteWithParamsRequired();

    // Constructor

    constructor(address defaultAdmin, IVotes _token, TimelockController _timelock, address _nftGate) Governor("Digil Governor") GovernorSettings(1 days, 1 weeks, 10000e18) GovernorVotes(_token) GovernorTimelockControl(_timelock) {
        // Grant the specified admin the ability to Veto
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(VETO_ROLE, defaultAdmin);

        // Set the NFT Gate
        nftGate = IERC721(_nftGate);
    }

    // Standard Vote Functions

    /**
     * @dev Disabled: Requires params to verify NFT ownership.
     *      Use `castVoteWithReasonAndParams` instead.
     */
    function castVote(uint256 /*proposalId*/, uint8 /*support*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    /**
     * @dev Disabled: Requires params to verify NFT ownership.
     *      Use `castVoteWithReasonAndParams` instead.
     */
    function castVoteWithReason(uint256 /*proposalId*/, uint8 /*support*/, string calldata /*reason*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    /**
     * @dev Disabled: Requires params to verify NFT ownership.
     *      Use `castVoteWithReasonAndParamsBySig` instead.
     *      (Note: This is the correct v5 signature)
     */
    function castVoteBySig(uint256 /*proposalId*/, uint8 /*support*/, address /*voter*/, bytes memory /*signature*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    // Quadratic Counting + NFT Gate

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override returns (uint256) {
        // 1. DECODE PARAMS & GATE CHECKS
        if (params.length == 0) revert InvalidParams();
        uint256 tokenId = abi.decode(params, (uint256));

        address owner = nftGate.ownerOf(tokenId);
        // Check 1: Is the voter the owner?
        bool approvedOrOwner = owner == account;
        
        // Check 2: Is the voter the specific approval?
        approvedOrOwner = approvedOrOwner || nftGate.getApproved(tokenId) == account;
        
        // Check 3: Is the voter an operator for all?
        approvedOrOwner = approvedOrOwner || nftGate.isApprovedForAll(owner, account);

        // If NONE of these are true, revert
        if (!approvedOrOwner) {
            revert InsufficientApproval(account, tokenId);
        }

        ProposalVote storage proposalVote = _proposalVotes[proposalId];

        if (proposalVote.nftUsed[tokenId]) revert AlreadyUsedNft(tokenId);
        if (proposalVote.hasVoted[account]) revert AlreadyCastVote(account);
        
        proposalVote.hasVoted[account] = true;
        proposalVote.nftUsed[tokenId] = true;

        // 2. THE MATH: Quadratic Weight
        uint256 quadraticWeight = Math.sqrt(weight); 

        // 3. THE HARD CAP
        // We calculate the Quorum for this specific proposal's timepoint.
        // Cap logic: No single user can have more votes than the Quorum itself.
        uint256 voteCap = quorum(proposalSnapshot(proposalId));
        
        // If the user's power exceeds the Quorum, clip it.
        if (quadraticWeight > voteCap) {
            quadraticWeight = voteCap;
        }

        // 4. CAST VOTE
        if (support == uint8(VoteType.Against)) {
            proposalVote.againstVotes += quadraticWeight;
        } else if (support == uint8(VoteType.For)) {
            proposalVote.forVotes += quadraticWeight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalVote.abstainVotes += quadraticWeight;
        } else {
            revert InvalidVoteType();
        }

        return quadraticWeight;
    }

    // Quadratic Quorum

    /**
     * @notice Calculates Quorum based on Square Root of Total Supply.
     */
    function quorum(uint256 timepoint) public view override returns (uint256) {
        // Get total supply of DigilCoin at the snapshot block
        uint256 pastTotalSupply = token().getPastTotalSupply(timepoint);
        
        // Calculate sqrt
        uint256 sqrtSupply = Math.sqrt(pastTotalSupply);

        // REQUIREMENT: 4% of the Sqrt(Supply)
        return (sqrtSupply * 4) / 100;
    }

    // Proposal Status

    /**
     * @dev Determines if the proposal has passed the vote.
     *      Rule: ForVotes > AgainstVotes
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return proposalVote.forVotes > proposalVote.againstVotes;
    }

    /**
     * @dev Determines if the proposal met the quorum requirement.
     *      Rule: (For + Against) >= Quorum
     */
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        
        // We count Total Participation (For + Abstain) against the threshold
        uint256 participationVotes = proposalVote.forVotes + proposalVote.abstainVotes;
        
        return participationVotes >= quorum(proposalSnapshot(proposalId));
    }

    // View Helpers

    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    function proposalVotes(uint256 proposalId) public view virtual returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return (proposalVote.againstVotes, proposalVote.forVotes, proposalVote.abstainVotes);
    }

    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,abstain&mode=quadratic&gate=nft_id";
    }

    // Boilerplate Overrides

    function veto(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) public onlyRole(VETO_ROLE) {
        _cancel(targets, values, calldatas, descriptionHash);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function _propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description, address proposer) internal override(Governor, GovernorStorage) returns (uint256) {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}