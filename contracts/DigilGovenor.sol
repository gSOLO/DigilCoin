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

import {IERC20Burnable} from "contracts/IERC20Burnable.sol";

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

    // --- SIGNALING & STAKING STORAGE ---
    uint256 public constant STAKE_KEEPER_FEE =   500; // 5%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Individual User Stakes
    mapping(uint256 => mapping(address => uint256)) public proposalStakes;
    
    // Running Total for Batch Burning
    mapping(uint256 => uint256) public proposalTotalStaked;
    
    // Safety flag to ensure we don't burn twice
    mapping(uint256 => bool) public proposalStakesBurned;

    mapping(uint256 => uint256) public proposalSignal;

    enum VoteType {
        Against,
        For,
        Abstain
    }

    // Events

    /// @notice Emitted when coins are burned to signal a proposal
    event Signal(uint256 indexed proposalId, address indexed user, uint256 amount);

    /// @notice Emitted when coins are staked on a proposal outcome
    event Stake(uint256 indexed proposalId, address indexed user, uint256 amount);

    /// @notice Emitted when a stake is returned (Proposal Passed)
    event Claim(uint256 indexed proposalId, address indexed user, uint256 amount);

    /// @notice Emitted when stakes are batch burned (Proposal Failed)
    event Burn(uint256 indexed proposalId, address indexed keeper, uint256 amountBurned, uint256 bountyPaid);

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

    /// @notice Thrown when moving staked tokens fails (transfer/transferFrom returned false or reverted).
    error TransferFailed(address from, address to, uint256 amount);

    // New Errors for Staking/Signaling
    error ProposalNotActive();
    error ProposalNotResolved();
    error ProposalFailed(); // Used when trying to claim on a failed proposal
    error ProposalPassed(); // Used when trying to burn on a passed proposal
    error ProposalResolved();
    error NoStakeFound();
    error StakesAlreadyBurned();

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

    // Signaling and Staking

    function _transferFrom(address from, address to, uint256 amount) internal {
        try IERC20Burnable(address(token())).transferFrom(from, to, amount) returns (bool ok) {
            if (!ok) revert TransferFailed(from, to, amount);
        } catch {
            revert TransferFailed(from, to, amount);
        }
    }

    function _transfer(address to, uint256 amount) internal {
        try IERC20Burnable(address(token())).transfer(to, amount) returns (bool ok) {
            if (!ok) revert TransferFailed(address(this), to, amount);
        } catch {
            revert TransferFailed(address(this), to, amount);
        }
    }

    function _burn(uint256 amount) internal {
        IERC20Burnable(address(token())).burn(amount);
    }

    function stakeOnProposal(uint256 proposalId, uint256 amount) external {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert ProposalNotActive();
        }

        _transferFrom(msg.sender, address(this), amount);

        // Update both Individual and Running Total
        proposalStakes[proposalId][msg.sender] += amount;
        proposalTotalStaked[proposalId] += amount;

        emit Stake(proposalId, msg.sender, amount);
    }

    /**
     * @notice SUCCESS CASE: Individual Claim.
     *         Called by the USER to get their money back.
     */
    function claimStake(uint256 proposalId) external {
        ProposalState currentState = state(proposalId);
        
        // Ensure Proposal Passed or was Vetoed/Canceled
        bool claimable = (
            currentState == ProposalState.Succeeded || 
            currentState == ProposalState.Queued || 
            currentState == ProposalState.Executed ||
            currentState == ProposalState.Canceled
        );
        if (!claimable) revert ProposalFailed();

        uint256 amount = proposalStakes[proposalId][msg.sender];
        if (amount == 0) revert NoStakeFound();

        // Zero out user balance
        proposalStakes[proposalId][msg.sender] = 0;        
        proposalTotalStaked[proposalId] -= amount; 

        _transfer(msg.sender, amount);
        emit Claim(proposalId, msg.sender, amount);
    }

    /**
     * @notice FAILURE CASE: Batch Burn.
     *         Called by ANYONE (Keeper) to burn the entire pile.
     *         Keeper gets 5% of the TOTAL pot.
     */
    function burnAllStakes(uint256 proposalId) external {
        if (proposalStakesBurned[proposalId]) revert StakesAlreadyBurned();

        ProposalState currentState = state(proposalId);

        if (currentState == ProposalState.Pending || currentState == ProposalState.Active) {
            revert ProposalNotResolved();
        }
        
        // If it passed (or is in the execution pipeline), burning is not allowed.
        if (currentState == ProposalState.Succeeded || currentState == ProposalState.Queued || currentState == ProposalState.Executed) {
            revert ProposalPassed();
        }

        // If it was vetoed/canceled, stakes are refundable (claim), not burnable.
        if (currentState == ProposalState.Canceled) {
            revert ProposalResolved();
        }

        // At this point, only true failure finals should remain.
        // (Governor defines Defeated / Expired as failure outcomes.)
        if (currentState != ProposalState.Defeated && currentState != ProposalState.Expired) {
            revert ProposalFailed();
        }

        uint256 totalAmount = proposalTotalStaked[proposalId];
        if (totalAmount == 0) revert NoStakeFound();

        // Mark as burned so it can't be called again
        proposalStakesBurned[proposalId] = true;
        proposalTotalStaked[proposalId] = 0; // prevent any accidental reuse

        // Calculate Jackpot Bounty
        uint256 bounty = (totalAmount * STAKE_KEEPER_FEE) / BPS_DENOMINATOR;
        uint256 burnAmount = totalAmount - bounty;

        // Pay the Keeper
        if (bounty > 0) {
            _transfer(msg.sender, bounty);
        }

        // Burn the rest
        if (burnAmount > 0) {
            _burn(burnAmount);
        }

        emit Burn(proposalId, msg.sender, burnAmount, bounty);
    }

    function signalProposal(uint256 proposalId, uint256 amount) external {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert ProposalNotActive();
        }

        _transferFrom(msg.sender, address(this), amount);
        _burn(amount);

        proposalSignal[proposalId] += amount;
        emit Signal(proposalId, msg.sender, amount);
    }
}