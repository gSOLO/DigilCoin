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
    event ProposalVetoed(uint256 proposalId);
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
    error NoLockedCoins();
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

    function _getVotes(address account, uint256 timepoint, bytes memory /*params*/) internal view override(Governor, GovernorVotes) returns (uint256) {
        // 1. Get Liquid Balance (Delegated) from Token
        uint256 rawWeight = token().getPastVotes(account, timepoint);

        // 2. Get Locked Balance + Bonus from Internal State
        // Note: Using uint48 casting because checkpoints store uint48 keys
        uint48 snapshot = uint48(timepoint);
        
        uint256 lockedAmount = _userLockedAmounts[account].upperLookup(snapshot);
        uint256 lockedExpiry = _userLockExpiries[account].upperLookup(snapshot);

        // If lock existed and was valid at the snapshot
        if (lockedAmount > 0 && lockedExpiry > snapshot) {
            uint256 timeRemaining = lockedExpiry - snapshot;
            if (timeRemaining > MAX_LOCK_DURATION) {
                timeRemaining = MAX_LOCK_DURATION;
            }
            
            // Bonus Model: LockedAmount + (LockedAmount * Time / MaxTime)
            uint256 timeBonus = (lockedAmount * timeRemaining) / MAX_LOCK_DURATION;
            
            rawWeight += (lockedAmount + timeBonus);
        }

        return rawWeight;
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

        // 3. QUADRATIC MATH
        // 'weight' is passed in from _getVotes(), so it already includes Liquid + Locked + Bonus.
        // We simply apply the square root here.
        uint256 finalWeight = Math.sqrt(weight);

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
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);
        emit ProposalVetoed(proposalId);
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

    // Locking Coins

    function lockCoins(uint256 amount, uint256 duration) external {
        address sender = _msgSender();

        // VALIDATION: Duration must always be valid to prevent accidental short-locks
        if (duration < MIN_LOCK_DURATION || duration > MAX_LOCK_DURATION) {
            revert LockDurationOutOfBounds(duration);
        }

        // Read current state
        uint48 nowTs = clock();
        uint208 currentAmount = _userLockedAmounts[sender].latest();
        uint48 currentExpiry = uint48(_userLockExpiries[sender].latest());

        // Decide new state (no external calls yet)
        uint208 newAmount = currentAmount;
        if (amount > 0) {
            newAmount = currentAmount + uint208(amount);
        }

        uint48 proposedExpiry = uint48(nowTs + uint48(duration));
        bool isExtension = proposedExpiry > currentExpiry;

        if (amount == 0 && !isExtension) {
            revert NoLockAction();
        }

        // --- EFFECTS ---
        if (amount > 0) {
            _userLockedAmounts[sender].push(nowTs, newAmount);
        }
        if (isExtension) {
            _userLockExpiries[sender].push(nowTs, proposedExpiry);
        }

        // --- INTERACTION ---
        if (amount > 0) {
            _transferFrom(sender, address(this), amount);
        }

        emit Lock(sender, amount, isExtension ? proposedExpiry : currentExpiry);
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

        // --- EFFECTS ---
        proposalStakes[proposalId][sender] += amount;
        proposalTotalStaked[proposalId] += amount;

        // --- INTERACTION ---
        _transferFrom(sender, address(this), amount);

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