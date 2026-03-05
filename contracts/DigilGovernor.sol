// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IERC20Burnable} from "contracts/IERC20Burnable.sol";

/// @title Digil Governor
/// @author gSOLO
/// @notice Governance contract for DigilCoin with: (1) NFT-gated voting, (2) vote weight boosted by time-locked coins, (3) quadratic counting, (4) timelock execution, and (5) an optional proposal outcome staking market.
/// @dev Extends OpenZeppelin Governor with custom `_getVotes` (raw power) + `_countVote` (quadratic tally). Time is sourced from the token’s ERC6372 clock (`token().clock()` / `token().CLOCK_MODE()`).
/// @custom:security-contact security@digil.co.in
// OPTIMIZATION: Removed 'GovernorSettings' inheritance
contract DigilGovernor is Governor, GovernorStorage, GovernorVotes, GovernorTimelockControl {
    using Checkpoints for Checkpoints.Trace208;

    /// @notice ERC721 used as a gate/credential to cast a vote (by tokenId) and to prevent double-use of an NFT per proposal.
    /// @dev Assumed to be a “well-behaved” ERC721. Even if malicious, reentrancy into `_countVote` is prevented by setting replay-protection flags before calling `ownerOf`.
    IERC721 internal immutable nftGate;

    /// @dev Per-proposal vote totals + replay-protection mappings.
    /// - `hasVoted[address]` prevents multiple ballots per address for that proposal.
    /// - `nftUsed[tokenId]` prevents using the same NFT tokenId more than once for that proposal.
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
        mapping(uint256 => bool) nftUsed; 
    }

    /// @dev Custom storage for vote totals keyed by proposalId.
    mapping(uint256 => ProposalVote) private _proposalVotes;

    // Tracks Amount over time
    /// @dev Checkpointed locked coin amounts per user (keyed by ERC6372 timepoints).
    mapping(address => Checkpoints.Trace208) private _userLockedAmounts;
    // Tracks Expiry Timestamp over time
    /// @dev Checkpointed lock expiry timestamps per user (keyed by ERC6372 timepoints). Expiry itself is a timestamp-like timepoint.
    mapping(address => Checkpoints.Trace208) private _userLockExpiries;

    /// @notice Minimum lock duration enforced for any lock/extension operation.
    uint256 private constant MIN_LOCK_DURATION = 1 weeks;
    /// @notice Maximum lock duration used both for validation and for bonus normalization.
    uint256 private constant MAX_LOCK_DURATION = 1460 days; // 4 years
    /// @dev Quorum is computed as a percentage of sqrt(totalSupplyAtSnapshot).
    uint256 private constant QUORUM_PERCENT = 4; // 4%

    /// @dev Tracks the PvP staking markets per proposal.
    struct ProposalMarket {
        uint256 totalStakedFor;
        uint256 totalStakedAgainst;
        bool orphanedSwept; // Flags if orphaned tokens have been burned
        mapping(address => uint256) stakeFor;
        mapping(address => uint256) stakeAgainst;
    }
    
    /// @dev Tracks the PvP staking markets per proposal.
    mapping(uint256 => ProposalMarket) public proposalMarkets;

    /// @dev Internal support encoding used in `_countVote`.
    enum VoteType {
        Against,
        For,
        Abstain
    }

    // @dev Minimum proposal threshold in raw voting units
    uint256 private _proposalThreshold = 10000e18;

    // Events
    /// @notice Emitted when coins are locked and/or the expiry is extended.
    event Lock(address indexed user, uint256 amount, uint48 expiry);
    /// @notice Emitted when coins are unlocked (principal returned).
    event Unlock(address indexed user);
    /// @notice Emitted when the proposal threshold is set.
    event ProposalThresholdSet(uint256 oldProposalThreshold, uint256 newProposalThreshold);
    /// @notice Emitted when a user places a stake on a proposal outcome.
    /// @param proposalId The ID of the proposal being staked on.
    /// @param user The address of the user placing the stake.
    /// @param supportFor True if betting the proposal will pass, False if betting it will fail.
    /// @param amount The amount of tokens staked.
    event Stake(uint256 indexed proposalId, address indexed user, bool supportFor, uint256 amount);
    /// @notice Emitted when a user claims their winnings or refund.
    /// @param proposalId The ID of the proposal.
    /// @param user The address of the user claiming.
    /// @param amount The total amount of tokens sent back to the user (principal + winnings).
    event Claim(uint256 indexed proposalId, address indexed user, uint256 amount);
    /// @notice Emitted when orphaned tokens (from a losing side with no winners) are burned.
    /// @param proposalId The ID of the proposal.
    /// @param amount The amount of tokens burned.
    event Burn(uint256 indexed proposalId, uint256 amount);

    // Errors
    /// @notice Thrown when vote params are missing (tokenId is required for NFT-gated voting)
    ///         or when a lock operation would overflow the checkpointed locked amount type (uint208)
    error InvalidParams();
    /// @notice Thrown when the same NFT tokenId is reused on the same proposal.
    error AlreadyUsedNft(uint256 tokenId);
    /// @notice Thrown when `account` is not owner/approved operator for the specified NFT tokenId.
    error InsufficientApproval(address voter, uint256 tokenId);
    /// @notice Thrown when the same address tries to vote multiple times on the same proposal.
    error AlreadyCastVote(address voter);
    /// @notice Thrown when `support` is not a recognized VoteType.
    error InvalidVoteType();
    /// @notice Thrown when standard Governor castVote variants are called without params.
    error VoteWithParamsRequired();
    /// @notice Thrown when ERC20 transfer/transferFrom fails (false return or revert).
    error TransferFailed(address from, address to, uint256 amount);
    /// @notice Thrown when `lockCoins` neither increases amount nor extends expiry.
    error NoLockAction();
    /// @notice Thrown when lock duration is outside configured bounds.
    error LockDurationOutOfBounds(uint256 duration);
    /// @notice Thrown when attempting to unlock before expiry.
    error LockNotExpired(uint256 expiry);
    /// @notice Thrown when attempting to unlock with no locked balance.
    error NoLockedCoins();
    /// @notice Thrown when staking actions are attempted in an invalid Governor state.
    error InvalidProposalState(ProposalState state);
    /// @notice Thrown when a user attempts to claim from a proposal where they have no stake.
    error NoStake();
    /// @notice Thrown when attempting to claim or sweep on a market that is still pending or active.
    error MarketNotFinalized();
    /// @notice Thrown when a user attempts to claim winnings but their chosen side lost, or they already claimed.
    error StakeLostOrNothingToClaim();
    /// @notice Thrown when a burn operation is attempted but there are no orphaned stakes to burn.
    error NoOrphanedStakes();

    /// @param _token The IVotes token used for delegation-based voting power (DigilCoin).
    /// @param _timelock Timelock controller used for queued/executed operations.
    /// @param _nftGate The ERC721 used to gate voting by NFT tokenId.
    constructor(IVotes _token, TimelockController _timelock, address _nftGate) Governor("Digil Governor") GovernorVotes(_token) GovernorTimelockControl(_timelock) {
        // Immutable gate reference (saves gas vs storage read).
        nftGate = IERC721(_nftGate);
    }

    // --- CLOCK SETTINGS ---

    /// @notice ERC6372 clock passthrough to the IVotes token.
    /// @dev Ensures this Governor and token share the same timepoint system (timestamp vs blocknumber).
    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return token().clock();
    }

    /// @notice ERC6372 clock mode passthrough to the IVotes token (e.g., "mode=timestamp").
    function CLOCK_MODE() public view override(Governor, GovernorVotes) returns (string memory) {
        return token().CLOCK_MODE();
    }

    // --- GOVERNOR SETTINGS ---

    /// @notice Voting delay (time from proposal creation until voting starts).
    function votingDelay() public view virtual override returns (uint256) {
        return 1 days;
    }

    /// @notice Voting period (time between vote start and vote end).
    function votingPeriod() public view virtual override returns (uint256) {
        return 1 weeks;
    }

    /// @notice Minimum proposal threshold in raw voting units (token base units).
    function proposalThreshold() public view virtual override returns (uint256) {
        return _proposalThreshold;
    }

    /// @dev Update the proposal threshold. This operation can only be performed through a governance proposal.
    ///      Emits a {ProposalThresholdSet} event.
    function setProposalThreshold(uint256 newProposalThreshold) external virtual onlyGovernance {
        emit ProposalThresholdSet(_proposalThreshold, newProposalThreshold);
        _proposalThreshold = newProposalThreshold;
    }

    // --- VOTE LOGIC ---

    /// @dev Disabled: voting must include params (an NFT tokenId) for gate/replay protection.
    function castVote(uint256 /*proposalId*/, uint8 /*support*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    /// @dev Disabled: voting must include params (an NFT tokenId) for gate/replay protection.
    function castVoteWithReason(uint256 /*proposalId*/, uint8 /*support*/, string calldata /*reason*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    /// @dev Disabled: signature voting must include params (an NFT tokenId) for gate/replay protection.
    function castVoteBySig(uint256 /*proposalId*/, uint8 /*support*/, address /*voter*/, bytes memory /*signature*/) public virtual override returns (uint256) {
        revert VoteWithParamsRequired();
    }

    /// @notice Computes an account’s raw voting power at a snapshot timepoint.
    /// @dev This function feeds `weight` into `_countVote`. Here you combine:
    /// 1) Liquid delegated votes from the token, plus
    /// 2) Locked coins tracked by this Governor, plus a time-based bonus.
    /// The bonus model is linear: `lockedAmount + lockedAmount * (timeRemaining / MAX_LOCK_DURATION)`.
    /// @param account Voter address whose power is being queried.
    /// @param timepoint Snapshot timepoint (ERC6372-based).
    /// @return Raw (pre-quadratic) voting weight.
    function _getVotes(address account, uint256 timepoint, bytes memory /*params*/) internal view override(Governor, GovernorVotes) returns (uint256) {
        // 1. Get Liquid Balance (Delegated) from Token
        uint256 rawWeight = token().getPastVotes(account, timepoint);

        // 2. Get Locked Balance + Bonus from Internal State
        // Note: Using uint48 casting because checkpoints store uint48 keys
        uint48 snapshot = uint48(timepoint);
        
        // Look up the latest lock amount/expiry that was in effect at the snapshot.
        uint256 lockedAmount = _userLockedAmounts[account].upperLookup(snapshot);
        uint256 lockedExpiry = _userLockExpiries[account].upperLookup(snapshot);

        // If lock existed and was valid at the snapshot
        if (lockedAmount > 0 && lockedExpiry > snapshot) {
            // Remaining lock time as-of the snapshot, capped at MAX_LOCK_DURATION for normalization.
            uint256 timeRemaining = lockedExpiry - snapshot;
            if (timeRemaining > MAX_LOCK_DURATION) {
                timeRemaining = MAX_LOCK_DURATION;
            }
            
            // Bonus Model: LockedAmount + (LockedAmount * Time / MaxTime)
            // - If timeRemaining == 0 -> bonus = 0, power adds lockedAmount.
            // - If timeRemaining == MAX_LOCK_DURATION -> bonus = lockedAmount, power adds 2x lockedAmount.
            uint256 timeBonus = (lockedAmount * timeRemaining) / MAX_LOCK_DURATION;
            
            // Add both principal and bonus power to the liquid power.
            rawWeight += (lockedAmount + timeBonus);
        }

        return rawWeight;
    }

    /// @notice Counts a vote for a proposal using NFT gating, replay protection, and quadratic counting.
    /// @dev `weight` is raw power computed by `_getVotes()` at the proposal snapshot; this function applies sqrt() and tallies.
    /// Params MUST decode to a `uint256 tokenId`.
    /// @param proposalId Proposal being voted on.
    /// @param account Voter address credited for the vote.
    /// @param support Support value (Against/For/Abstain).
    /// @param weight Raw voting weight passed from `_getVotes`.
    /// @param params ABI-encoded `uint256 tokenId` used for NFT gating and anti-replay.
    /// @return finalWeight Quadratic (sqrt) weight actually counted.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override returns (uint256) {
        // Enforce presence of vote params (must contain tokenId).
        if (params.length == 0) revert InvalidParams();
        // Decode the NFT tokenId used for gating.
        uint256 tokenId = abi.decode(params, (uint256));

        // 1. STATE UPDATES
        // Replay protection is applied before the external ERC721 call to prevent reentrancy abuse.
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        if (proposalVote.nftUsed[tokenId]) revert AlreadyUsedNft(tokenId);
        if (proposalVote.hasVoted[account]) revert AlreadyCastVote(account);
        
        proposalVote.hasVoted[account] = true;
        proposalVote.nftUsed[tokenId] = true;

        // 2. NFT GATE (Scoped)
        // Voter must be the owner OR approved operator for the tokenId (supports delegated custody/approval patterns).
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
        // Note: quadratic reduces marginal influence of large weights while still rewarding larger holders.
        uint256 finalWeight = Math.sqrt(weight);

        // 4. TALLY
        // Tally the quadratic weight into the per-proposal buckets.
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

    /// @notice Calculates the quorum requirement at a given timepoint.
    /// @dev Quorum = QUORUM_PERCENT% of sqrt(totalSupplyAtTimepoint). Uses the IVotes snapshot supply.
    /// @param timepoint Snapshot timepoint used to query past total supply.
    function quorum(uint256 timepoint) public view override returns (uint256) {
        uint256 pastTotalSupply = token().getPastTotalSupply(timepoint);
        uint256 sqrtSupply = Math.sqrt(pastTotalSupply);
        return (sqrtSupply * QUORUM_PERCENT) / 100;
    }

    /// @dev Proposal passes if ForVotes > AgainstVotes (Abstain does not affect success).
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return proposalVote.forVotes > proposalVote.againstVotes;
    }

    /// @dev Quorum checks participation as (For + Abstain) against the snapshot quorum.
    /// @notice Treats abstentions as participation for quorum purposes.
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        uint256 participationVotes = proposalVote.forVotes + proposalVote.abstainVotes;
        return participationVotes >= quorum(proposalSnapshot(proposalId));
    }

    /// @notice Returns whether `account` has already cast a vote on `proposalId`.
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    /// @notice Returns current tallies for a proposal (Against, For, Abstain).
    function proposalVotes(uint256 proposalId) external view virtual returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return (proposalVote.againstVotes, proposalVote.forVotes, proposalVote.abstainVotes);
    }

    /// @notice Declares this Governor’s counting configuration for off-chain tooling.
    /// @dev Indicates a Bravo-like 3-option support, quorum counts For+Abstain, quadratic mode, and NFT gate requirement.
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,abstain&mode=quadratic&gate=nft_id";
    }

    // Overrides required by Solidity due to multiple inheritance

    /// @notice Returns the current Governor state of a proposal (includes timelock pipeline states).
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    /// @notice Whether a proposal needs to be queued in the timelock before execution.
    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @dev Storage extension hook for proposal creation bookkeeping.
    function _propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description, address proposer) internal override(Governor, GovernorStorage) returns (uint256) {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    /// @dev Timelock enqueue hook.
    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Timelock execute hook.
    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Timelock/Governor cancel hook.
    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Returns the execution authority (typically the timelock).
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    /// @notice ERC165 support for interfaces exposed through Governor and AccessControl.
    /// @dev Required because both parents implement supportsInterface; super() resolves correctly by linearization.
    function supportsInterface(bytes4 interfaceId) public view override(Governor) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Locking Coins

    /// @notice Locks DigilCoin inside this Governor and/or extends the lock expiry.
    /// @dev Uses checkpoints so `_getVotes` can read the locked state at any proposal snapshot timepoint.
    ///      Uses a CEI pattern: compute new state, commit to storage, then perform the ERC20 transferFrom.
    /// @param amount Additional amount to lock (0 allowed if only extending).
    /// @param duration Desired lock duration from “now” (used only to compute a proposedExpiry); must be within bounds.
    function lockCoins(uint256 amount, uint256 duration) external {
        address sender = _msgSender();

        // VALIDATION: Duration must always be valid to prevent accidental short-locks
        if (duration < MIN_LOCK_DURATION || duration > MAX_LOCK_DURATION) {
            revert LockDurationOutOfBounds(duration);
        }

        // Read current state
        // `clock()` aligns with token().clock() so checkpoints and snapshots share the same time scale.
        uint48 nowTs = clock();
        uint208 currentAmount = _userLockedAmounts[sender].latest();
        uint48 currentExpiry = uint48(_userLockExpiries[sender].latest());

        // Decide new state (no external calls yet)
        uint208 newAmount = currentAmount;
        if (amount > 0) {
            // Guard: amount must fit in uint208, and currentAmount + amount must not overflow uint208.
            if (amount > type(uint208).max) revert InvalidParams();
            newAmount = currentAmount + uint208(amount);
        }

        // Proposed expiry is “now + duration” in the Governor’s clock units (timestamp-mode).
        uint48 proposedExpiry = uint48(nowTs + uint48(duration));
        bool isExtension = proposedExpiry > currentExpiry;

        // Caller must either add coins or extend expiry.
        if (amount == 0 && !isExtension) {
            revert NoLockAction();
        }

        // --- EFFECTS ---
        // Record new checkpoints before external token transfer; revert will roll back if transfer fails.
        if (amount > 0) {
            _userLockedAmounts[sender].push(nowTs, newAmount);
        }
        if (isExtension) {
            _userLockExpiries[sender].push(nowTs, proposedExpiry);
        }

        // --- INTERACTION ---
        // Pull tokens into the Governor only when increasing locked amount.
        if (amount > 0) {
            _transferFrom(sender, address(this), amount);
        }

        // Emit final expiry used (either newly extended or unchanged).
        emit Lock(sender, amount, isExtension ? proposedExpiry : currentExpiry);
    }

    /// @notice Unlocks and withdraws all locked coins after the lock period has expired.
    /// @dev Resets voting power to zero (by pushing 0 to the checkpoint) and returns tokens.
    function unlockCoins() external {
        address sender = _msgSender();
        
        // 1. Check current state
        // Use clock() to ensure time consistency with lockCoins/voting
        uint48 nowTs = clock();
        uint208 currentAmount = _userLockedAmounts[sender].latest();
        uint48 currentExpiry = uint48(_userLockExpiries[sender].latest());

        // 2. Validation
        if (currentAmount == 0) {
            revert NoLockedCoins();
        }
        if (nowTs < currentExpiry) {
            revert LockNotExpired(currentExpiry);
        }

        // 3. Effects (Update State)
        // We push a new checkpoint with 0 amount. 
        // This ensures future calls to _getVotes return 0 for locked balance.
        _userLockedAmounts[sender].push(nowTs, 0);
        
        // We do not strictly need to clear expiry, as 0 amount results in 0 voting power 
        // regardless of the expiry date in _getVotes.

        // 4. Interaction
        // Transfer the total locked principal back to the user.
        _transfer(sender, currentAmount);

        emit Unlock(sender);
    }

    // --- PVP STAKING (PREDICTION MARKET) ---

    /// @dev Internal safe wrapper for ERC20 transferFrom with explicit false-return handling.
    function _transferFrom(address from, address to, uint256 amount) internal {
        bool success = IERC20Burnable(address(token())).transferFrom(from, to, amount);
        if (!success) revert TransferFailed(from, to, amount);
    }

    /// @dev Internal safe wrapper for ERC20 transfer with explicit false-return handling.
    function _transfer(address to, uint256 amount) internal {
        bool success = IERC20Burnable(address(token())).transfer(to, amount);
        if (!success) revert TransferFailed(address(this), to, amount);
    }

    /// @dev Burns DigilCoin held by this Governor.
    function _burn(uint256 amount) internal {
        IERC20Burnable(address(token())).burn(amount);
    }

    /// @notice Evaluates the current state of a proposal and translates it into a prediction market outcome.
    /// @dev    Internal helper used by `claim` and `burn` to consolidate logic.
    /// @param  proposalId The ID of the proposal being evaluated.
    /// @return outcome An integer representing the market result: 1 = FOR won, 0 = AGAINST won, 2 = DRAW (Canceled).
    /// @custom:reverts MarketNotFinalized if the proposal is still voting (Pending or Active).
    function _getMarketOutcome(uint256 proposalId) internal view returns (uint8) {
        ProposalState s = state(proposalId);
        if (s == ProposalState.Succeeded || s == ProposalState.Queued || s == ProposalState.Executed) return 1;
        if (s == ProposalState.Defeated || s == ProposalState.Expired) return 0;
        if (s == ProposalState.Canceled) return 2;
        revert MarketNotFinalized();
    }

    /// @notice Stakes coins on the outcome of a governance proposal (PvP Prediction Market).
    /// @dev    Tokens are transferred from the user to the Governor. Can only be called during Pending or Active states.
    /// @param  proposalId The ID of the proposal to stake on.
    /// @param  supportFor Set to `true` to bet that the proposal will succeed. Set to `false` to bet it will fail.
    /// @param  amount The amount of DigilCoin to stake.
    function stake(uint256 proposalId, bool supportFor, uint256 amount) external {
        ProposalState currentState = state(proposalId);

        // Can only enter the market while voting is pending or active
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert InvalidProposalState(currentState);
        }

        address sender = _msgSender();
        ProposalMarket storage market = proposalMarkets[proposalId];

        // --- EFFECTS ---
        if (supportFor) {
            market.stakeFor[sender] += amount;
            market.totalStakedFor += amount;
        } else {
            market.stakeAgainst[sender] += amount;
            market.totalStakedAgainst += amount;
        }

        // --- INTERACTION ---
        _transferFrom(sender, address(this), amount);

        emit Stake(proposalId, sender, supportFor, amount);
    }

    /// @notice Claims winnings or a refund for a finalized proposal market.
    /// @dev    If the user bet correctly, they receive their principal plus a proportional share of the losing side's pool.
    ///         If the proposal was canceled, the market is a DRAW and the user receives exactly their principal back.
    ///         Calculates payout dynamically and clears user balances before transfer (CEI pattern).
    ///         Integer division can leave small residual dust in the contract after all claims.
    /// @param  proposalId The ID of the finalized proposal to claim from.
    function claim(uint256 proposalId) external {
        uint8 outcome = _getMarketOutcome(proposalId);

        address sender = _msgSender();
        ProposalMarket storage market = proposalMarkets[proposalId];
        
        uint256 userFor = market.stakeFor[sender];
        uint256 userAgainst = market.stakeAgainst[sender];
        
        if (userFor == 0 && userAgainst == 0) revert NoStake();

        // Clear balances first to prevent reentrancy
        market.stakeFor[sender] = 0;
        market.stakeAgainst[sender] = 0;

        uint256 payout = 0;

        if (outcome == 1) { // FOR Won
            if (userFor > 0) payout = userFor + ((userFor * market.totalStakedAgainst) / market.totalStakedFor);
        } else if (outcome == 0) { // AGAINST Won
            if (userAgainst > 0) payout = userAgainst + ((userAgainst * market.totalStakedFor) / market.totalStakedAgainst);
        } else if (outcome == 2) { // DRAW
            payout = userFor + userAgainst; 
        }

        if (payout == 0) revert StakeLostOrNothingToClaim();

        _transfer(sender, payout);
        emit Claim(proposalId, sender, payout);
    }

    /// @notice Burns orphaned stakes for a finalized proposal market and optionally pays a caller bounty.
    /// @dev    If the winning side has zero participants, all tokens staked on the losing side become orphaned.
    ///         This function can be called by anyone exactly once per finalized market to dispose of those orphaned tokens.
    ///         A bounty of 1% is paid to the caller from the orphaned amount.
    ///         the remainder is burned.
    /// @param  proposalId The ID of the finalized proposal to sweep.
    function burn(uint256 proposalId) external {
        ProposalMarket storage market = proposalMarkets[proposalId];
        if (market.orphanedSwept) revert NoOrphanedStakes();

        uint8 outcome = _getMarketOutcome(proposalId);
        uint256 amountToBurn = 0;

        if (outcome == 1) { // FOR won
            if (market.totalStakedFor == 0) amountToBurn = market.totalStakedAgainst;
        } else if (outcome == 0) { // AGAINST won
            if (market.totalStakedAgainst == 0) amountToBurn = market.totalStakedFor;
        } else {
            // outcome == 2 (DRAW). Everyone is refunded, no orphaned tokens.
            revert NoOrphanedStakes(); 
        }

        if (amountToBurn == 0) revert NoOrphanedStakes();

        // --- Effects ---
        market.orphanedSwept = true;

        // --- Bounty (paid out of the orphaned pool), then burn remainder ---
        uint256 bounty = amountToBurn / 100; // 1%
        if (bounty != 0) {
            _transfer(_msgSender(), bounty);
            amountToBurn -= bounty;
        }

        _burn(amountToBurn);
        emit Burn(proposalId, amountToBurn);
    }
}
