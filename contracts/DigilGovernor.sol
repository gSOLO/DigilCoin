// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.31;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IERC20Burnable} from "contracts/IERC20Burnable.sol";

/// @title Digil Governor
/// @author gSOLO
/// @custom:security-contact security@digil.co.in
// OPTIMIZATION: Removed 'GovernorSettings' inheritance
contract DigilGovernor is Governor, GovernorStorage, GovernorVotes, GovernorTimelockControl, AccessControl {
    using Checkpoints for Checkpoints.Trace208;

    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");

    IERC721 internal immutable nftGate;

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
        mapping(uint256 => bool) nftUsed; 
    }

    mapping(uint256 => ProposalVote) private _proposalVotes;

    // Tracks Amount over time
    mapping(address => Checkpoints.Trace208) private _userLockedAmounts;
    // Tracks Expiry Timestamp over time
    mapping(address => Checkpoints.Trace208) private _userLockExpiries;

    uint256 public constant MIN_LOCK_DURATION = 1 weeks;
    uint256 public constant MAX_LOCK_DURATION = 1460 days; // 4 years
    uint256 private constant QUORUM_PERCENT = 4; // 4%

    // --- SIGNALING & STAKING STORAGE ---
    uint256 private constant STAKE_KEEPER_FEE =   500; // 5%
    uint256 private constant BPS_DENOMINATOR = 10000;

    mapping(uint256 => mapping(address => uint256)) internal proposalStakes;
    
    mapping(uint256 => uint256) internal proposalTotalStaked;
    mapping(uint256 => bool) internal proposalStakesBurned;

    enum VoteType {
        Against,
        For,
        Abstain
    }

    // Events
    event Lock(address indexed user, uint256 amount, uint48 expiry);
    event Unlock(address indexed user);
    event Signal(uint256 indexed proposalId, address indexed user, uint256 amount);
    event Stake(uint256 indexed proposalId, address indexed user, uint256 amount);
    event Claim(uint256 indexed proposalId, address indexed user, uint256 amount);
    event Burn(uint256 indexed proposalId, address indexed keeper, uint256 amountBurned, uint256 bountyPaid);

    // Errors
    error InvalidParams();
    error AlreadyUsedNft(uint256 tokenId);
    error InsufficientApproval(address voter, uint256 tokenId);
    error AlreadyCastVote(address voter);
    error InvalidVoteType();
    error VoteWithParamsRequired();
    error TransferFailed(address from, address to, uint256 amount);
    error NoLockAction();
    error LockDurationOutOfBounds(uint256 duration);
    error LockNotExpired(uint256 expiry);
    error NoLockedTokens();
    error InvalidProposalState(ProposalState state);
    error NoStake();

    constructor(address defaultAdmin, IVotes _token, TimelockController _timelock, address _nftGate) Governor("Digil Governor") GovernorVotes(_token) GovernorTimelockControl(_timelock) {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(VETO_ROLE, defaultAdmin);
        nftGate = IERC721(_nftGate);
    }

    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return token().clock();
    }

    function CLOCK_MODE() public view override(Governor, GovernorVotes) returns (string memory) {
        return token().CLOCK_MODE();
    }

    function votingDelay() public pure override returns (uint256) {
        return 1 days; 
    }

    function votingPeriod() public pure override returns (uint256) {
        return 1 weeks;
    }

    function proposalThreshold() public pure override returns (uint256) {
        return 10000e18;
    }

    // --- VOTE LOGIC ---

    function castVote(uint256 /*proposalId*/, uint8 /*support*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    function castVoteWithReason(uint256 /*proposalId*/, uint8 /*support*/, string calldata /*reason*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    function castVoteBySig(uint256 /*proposalId*/, uint8 /*support*/, address /*voter*/, bytes memory /*signature*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override returns (uint256) {
        if (params.length == 0) revert InvalidParams();
        uint256 tokenId = abi.decode(params, (uint256));

        // 1. STATE UPDATES
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        if (proposalVote.nftUsed[tokenId]) revert AlreadyUsedNft(tokenId);
        if (proposalVote.hasVoted[account]) revert AlreadyCastVote(account);
        
        proposalVote.hasVoted[account] = true;
        proposalVote.nftUsed[tokenId] = true;

        // 2. NFT GATE (Scoped)
        {
            address owner = nftGate.ownerOf(tokenId);
            if (owner != account && 
                nftGate.getApproved(tokenId) != account && 
                !nftGate.isApprovedForAll(owner, account)) {
                revert InsufficientApproval(account, tokenId);
            }
        }

        // 3. COMBINED WEIGHT CALCULATION
        uint256 finalWeight;
        {
            uint48 snapshot = uint48(proposalSnapshot(proposalId));
            uint256 lockedAmount = _userLockedAmounts[account].upperLookup(snapshot);
            uint256 lockedExpiry = _userLockExpiries[account].upperLookup(snapshot);

            // Start with Liquid Weight (from params)
            uint256 totalRawWeight = weight;

            // Add Locked Weight (if valid)
            if (lockedAmount > 0 && lockedExpiry > snapshot) {
                uint256 timeRemaining = lockedExpiry - snapshot;
                if (timeRemaining > MAX_LOCK_DURATION) {
                    timeRemaining = MAX_LOCK_DURATION;
                }
                
                // INCENTIVE FIX: Bonus Model
                // Power = Amount + (Amount * Time / MaxTime)
                // Result: 100 Tokens locked for 0 time = 100 Power (Same as liquid)
                // Result: 100 Tokens locked for 4 years = 200 Power (2x Bonus)
                uint256 timeBonus = (lockedAmount * timeRemaining) / MAX_LOCK_DURATION;
                totalRawWeight += (lockedAmount + timeBonus);
            }

            // Apply Quadratic Root to the Sum
            finalWeight = Math.sqrt(totalRawWeight);
        }

        // 4. CAP & TALLY
        {
            uint256 voteCap = quorum(proposalSnapshot(proposalId));
            if (finalWeight > voteCap) {
                finalWeight = voteCap;
            }
        }

        if (support == uint8(VoteType.Against)) {
            proposalVote.againstVotes += finalWeight;
        } else if (support == uint8(VoteType.For)) {
            proposalVote.forVotes += finalWeight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalVote.abstainVotes += finalWeight;
        } else {
            revert InvalidVoteType();
        }

        return finalWeight;
    }

    function quorum(uint256 timepoint) public view override returns (uint256) {
        uint256 pastTotalSupply = token().getPastTotalSupply(timepoint);
        uint256 sqrtSupply = Math.sqrt(pastTotalSupply);
        return (sqrtSupply * QUORUM_PERCENT) / 100;
    }

    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return proposalVote.forVotes > proposalVote.againstVotes;
    }

    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        uint256 participationVotes = proposalVote.forVotes + proposalVote.abstainVotes;
        return participationVotes >= quorum(proposalSnapshot(proposalId));
    }

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

    function veto(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) public onlyRole(VETO_ROLE) {
        _cancel(targets, values, calldatas, descriptionHash);
    }

    // Overrides required by Solidity due to multiple inheritance
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
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

    // Locking Tokens

    function lockTokens(uint256 amount, uint256 duration) external {
        // VALIDATION: Duration must always be valid to prevent accidental short-locks
        if (duration < MIN_LOCK_DURATION || duration > MAX_LOCK_DURATION) {
            revert LockDurationOutOfBounds(duration);
        }

        // 1. HANDLE AMOUNT (Only if adding tokens)
        if (amount > 0) {
            _transferFrom(msg.sender, address(this), amount);

            uint208 currentAmount = _userLockedAmounts[msg.sender].latest();
            uint208 newAmount = currentAmount + uint208(amount);
            _userLockedAmounts[msg.sender].push(clock(), newAmount);
        }

        // 2. HANDLE DURATION (Extend if new duration is longer than current)
        uint48 currentExpiry = uint48(_userLockExpiries[msg.sender].latest());
        uint48 newExpiry = uint48(block.timestamp + duration);
        
        bool isExtension = newExpiry > currentExpiry;
        if (isExtension) {
            _userLockExpiries[msg.sender].push(clock(), newExpiry);
        }

        // 3. FINAL CHECK: Must do at least one thing
        if (amount == 0 && !isExtension) {
            revert NoLockAction();
        }

        // Note: Event now handles 0 amount gracefully
        emit Lock(msg.sender, amount, newExpiry);
    }

    function unlockTokens() external {
        address sender = _msgSender();

        uint48 expiry = uint48(_userLockExpiries[sender].latest());
        uint208 amount = _userLockedAmounts[sender].latest();

        if (clock() < expiry) revert LockNotExpired(expiry);
        if (amount == 0) revert NoLockedTokens();

        _userLockedAmounts[sender].push(clock(), 0);
        _userLockExpiries[sender].push(clock(), 0);

        _transfer(sender, amount);

        emit Unlock(msg.sender);
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
        
        // Rule: Can only stake if Pending or Active
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert InvalidProposalState(currentState);
        }

        address sender = _msgSender();

        _transferFrom(sender, address(this), amount);

        proposalStakes[proposalId][sender] += amount;
        proposalTotalStaked[proposalId] += amount;

        emit Stake(proposalId, sender, amount);
    }

    function claimStake(uint256 proposalId) external {
        ProposalState currentState = state(proposalId);
        
        // Rule: Can claim if Succeeded, Queued, Executed, or Canceled.
        // (i.e., NOT Pending, Active, Defeated, or Expired)
        bool claimable = (
            currentState == ProposalState.Succeeded || 
            currentState == ProposalState.Queued || 
            currentState == ProposalState.Executed ||
            currentState == ProposalState.Canceled
        );
        
        if (!claimable) revert InvalidProposalState(currentState);

        address sender = _msgSender();

        uint256 amount = proposalStakes[proposalId][sender];
        if (amount == 0) revert NoStake();

        proposalStakes[proposalId][sender] = 0;        
        proposalTotalStaked[proposalId] -= amount; 

        _transfer(sender, amount);
        emit Claim(proposalId, sender, amount);
    }

    function burnAllStakes(uint256 proposalId) external {
        // 1. CONSOLIDATED STATE CHECK
        // Instead of rejecting specific bad states, we only accept the two valid ones.
        ProposalState currentState = state(proposalId);
        
        // Rule: Can only burn if Defeated or Expired
        if (currentState != ProposalState.Defeated && currentState != ProposalState.Expired) {
            revert InvalidProposalState(currentState);
        }

        // 2. CONSOLIDATED AMOUNT CHECK
        // If we already burned it, or if nobody ever staked, there is "NothingToBurn".
        if (proposalStakesBurned[proposalId] || proposalTotalStaked[proposalId] == 0) {
            revert NoStake();
        }

        // 3. EXECUTION
        uint256 totalAmount = proposalTotalStaked[proposalId];
        
        // Update state first (Checks-Effects-Interactions)
        proposalStakesBurned[proposalId] = true;
        proposalTotalStaked[proposalId] = 0; 

        // Calculate Jackpot Bounty
        uint256 bounty = (totalAmount * STAKE_KEEPER_FEE) / BPS_DENOMINATOR;
        uint256 burnAmount = totalAmount - bounty;

        address sender = _msgSender();

        // Pay the Keeper
        if (bounty > 0) {
            _transfer(sender, bounty);
        }

        // Burn the rest
        if (burnAmount > 0) {
            _burn(burnAmount);
        }

        emit Burn(proposalId, sender, burnAmount, bounty);
    }

    function signalProposal(uint256 proposalId, uint256 amount) external {
        ProposalState currentState = state(proposalId);
        
        // Rule: Can only signal if Pending or Active
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert InvalidProposalState(currentState);
        }

        address sender = _msgSender();

        _transferFrom(sender, address(this), amount);
        _burn(amount);

        emit Signal(proposalId, sender, amount);
    }
}