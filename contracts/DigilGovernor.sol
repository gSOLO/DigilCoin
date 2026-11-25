// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.39;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IERC20Burnable} from "contracts/IERC20Burnable.sol";

/// @title Digil Governor
/// @author gSOLO
/// @notice Governance contract for DigilCoin with: (1) NFT-gated voting, (2) vote weight boosted by time-locked coins, (3) quadratic counting, (4) timelock execution, and (5) an optional proposal outcome staking market.
/// @dev Extends OpenZeppelin Governor with custom `_getVotes` (raw power) + `_countVote` (quadratic tally). Time is sourced from the token’s ERC6372 clock (`token().clock()` / `token().CLOCK_MODE()`).
/// @custom:security-contact security@digil.xyz
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
        uint256[3] totals; // Indexed in VoteType order.
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
    uint256 private constant QUORUM_DIVISOR = 25; // 4% of the square root of supply.

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

    uint8 private constant UNSETTLED = 0;
    uint8 private constant AGAINST = 1;
    uint8 private constant FOR = 2;
    uint8 private constant REFUND = 3;

    /// @notice Settlement result: 0 = unsettled, 1 = Against, 2 = For, 3 = early-cancellation refund.
    mapping(uint256 => uint8) public marketOutcome;

    /// @notice Emitted once when a ballot result or early-cancellation refund is fixed.
    event MarketFinalized(uint256 indexed proposalId, uint8 outcome);

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
    /// @dev    `amount` is the total payout transferred to the claimer for this market.
    /// @param proposalId The ID of the proposal.
    /// @param user The address of the user claiming.
    /// @param amount The total amount of tokens sent back to the user (principal + winnings).
    event Claim(uint256 indexed proposalId, address indexed user, uint256 amount);
    /// @notice Emitted when orphaned tokens (from a losing side with no winners) are burned.
    /// @param proposalId The ID of the proposal.
    /// @param amount The amount of tokens burned.
    event Burn(uint256 indexed proposalId, uint256 amount);

    // Errors
    /// @notice Thrown when a ballot lacks a tokenId or snapshot voting power,
    ///         a lock operation would overflow the checkpointed locked amount type (uint208),
    ///         or a staking amount is zero.
    error InvalidParams();
    /// @notice The Governor cannot relay calls to the DIGIL it holds for lockers and stakers.
    error ProtectedToken();
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

    /// @notice Allows governance to recover unrelated assets while protecting all DIGIL in custody.
    function relay(address target, uint256 value, bytes calldata data) public payable override onlyGovernance {
        if (target == address(token())) revert ProtectedToken();
        (bool success, bytes memory result) = target.call{value: value}(data);
        Address.verifyCallResult(success, result);
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
        uint256 lockedExpiry = _userLockExpiries[account].upperLookup(snapshot);
        if (lockedExpiry <= snapshot) return rawWeight;
        uint256 lockedAmount = _userLockedAmounts[account].upperLookup(snapshot);
        // The expiry checkpoint was written at or before snapshot, at most MAX_LOCK_DURATION ahead.
        // A uint208 principal times that duration fits uint256, as does twice the principal.
        unchecked { lockedAmount += lockedAmount * (lockedExpiry - snapshot) / MAX_LOCK_DURATION; }
        return rawWeight + lockedAmount;
    }

    /// @notice Counts a vote for a proposal using NFT gating, replay protection, and quadratic counting.
    /// @dev `weight` is raw power computed by `_getVotes()` at the proposal snapshot; this function applies sqrt() and tallies.
    /// Params MUST decode to a `uint256 tokenId`. Only positive snapshot power can consume the credential.
    /// @param proposalId Proposal being voted on.
    /// @param account Voter address credited for the vote.
    /// @param support Support value (Against/For/Abstain).
    /// @param weight Raw voting weight passed from `_getVotes`.
    /// @param params ABI-encoded `uint256 tokenId` used for NFT gating and anti-replay.
    /// @return finalWeight Quadratic (sqrt) weight actually counted.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override returns (uint256) {
        if (params.length == 0 || weight == 0) revert InvalidParams();
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
            IERC721 gate = nftGate;
            address owner = gate.ownerOf(tokenId);
            if (owner != account && 
                gate.getApproved(tokenId) != account &&
                !gate.isApprovedForAll(owner, account)) {
                revert InsufficientApproval(account, tokenId);
            }
        }

        // 3. QUADRATIC MATH
        // 'weight' is passed in from _getVotes(), so it already includes Liquid + Locked + Bonus.
        // We simply apply the square root here.
        // Note: quadratic reduces marginal influence of large weights while still rewarding larger holders.
        uint256 finalWeight = Math.sqrt(weight);

        // 4. TALLY
        if (support >= proposalVote.totals.length) revert InvalidVoteType();
        proposalVote.totals[support] += finalWeight;

        return finalWeight;
    }

    /// @notice Calculates the quorum requirement at a given timepoint.
    /// @dev Quorum is 4% of the square root of the IVotes snapshot supply, rounded down.
    /// @param timepoint Snapshot timepoint used to query past total supply.
    function quorum(uint256 timepoint) public view override returns (uint256) {
        uint256 pastTotalSupply = token().getPastTotalSupply(timepoint);
        uint256 sqrtSupply = Math.sqrt(pastTotalSupply);
        return sqrtSupply / QUORUM_DIVISOR;
    }

    /// @dev Proposal passes if ForVotes > AgainstVotes (Abstain does not affect success).
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        uint256[3] storage totals = _proposalVotes[proposalId].totals;
        return totals[uint8(VoteType.For)] > totals[uint8(VoteType.Against)];
    }

    /// @dev Quorum checks participation as (For + Abstain) against the snapshot quorum.
    /// @notice Treats abstentions as participation for quorum purposes.
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        uint256[3] storage totals = _proposalVotes[proposalId].totals;
        uint256 participationVotes = totals[uint8(VoteType.For)] + totals[uint8(VoteType.Abstain)];
        return participationVotes >= quorum(proposalSnapshot(proposalId));
    }

    /// @notice Returns whether `account` has already cast a vote on `proposalId`.
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    /// @notice Returns current tallies for a proposal (Against, For, Abstain).
    function proposalVotes(uint256 proposalId) external view virtual returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) {
        uint256[3] storage totals = _proposalVotes[proposalId].totals;
        return (
            totals[uint8(VoteType.Against)],
            totals[uint8(VoteType.For)],
            totals[uint8(VoteType.Abstain)]
        );
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
        uint256 proposalId = super._cancel(targets, values, calldatas, descriptionHash);
        finalizeMarket(proposalId);
        return proposalId;
    }

    /// @dev Returns the execution authority (typically the timelock).
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
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
        Checkpoints.Trace208 storage expiries = _userLockExpiries[sender];
        uint48 expiry = uint48(expiries.latest());
        uint48 proposedExpiry = nowTs + uint48(duration);
        if (proposedExpiry > expiry) {
            expiry = proposedExpiry;
            expiries.push(nowTs, expiry);
        } else if (amount == 0) {
            revert NoLockAction();
        }

        if (amount > 0) {
            Checkpoints.Trace208 storage amounts = _userLockedAmounts[sender];
            uint208 current = amounts.latest();
            unchecked {
                if (amount > type(uint208).max - current) revert InvalidParams();
                amounts.push(nowTs, current + uint208(amount));
            }
            _pull(sender, amount);
        }
        emit Lock(sender, amount, expiry);
    }

    /// @notice Unlocks and withdraws all locked coins after the lock period has expired.
    /// @dev Resets voting power to zero (by pushing 0 to the checkpoint) and returns tokens.
    function unlockCoins() external {
        address sender = _msgSender();
        
        // 1. Check current state
        // Use clock() to ensure time consistency with lockCoins/voting
        uint48 nowTs = clock();
        Checkpoints.Trace208 storage amounts = _userLockedAmounts[sender];
        uint208 currentAmount = amounts.latest();
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
        amounts.push(nowTs, 0);
        
        // We do not strictly need to clear expiry, as 0 amount results in 0 voting power 
        // regardless of the expiry date in _getVotes.

        // 4. Interaction
        // Transfer the total locked principal back to the user.
        _transfer(sender, currentAmount);

        emit Unlock(sender);
    }

    // --- PVP STAKING (PREDICTION MARKET) ---

    /// @dev Internal safe wrapper for ERC20 transferFrom with explicit false-return handling.
    function _pull(address from, uint256 amount) private {
        bool success = IERC20Burnable(address(token())).transferFrom(from, address(this), amount);
        if (!success) _revertTransfer(from, address(this), amount);
    }

    /// @dev Internal safe wrapper for ERC20 transfer with explicit false-return handling.
    function _transfer(address to, uint256 amount) internal {
        bool success = IERC20Burnable(address(token())).transfer(to, amount);
        if (!success) _revertTransfer(address(this), to, amount);
    }

    function _revertTransfer(address from, address to, uint256 amount) private pure {
        revert TransferFailed(from, to, amount);
    }

    /// @notice Permanently settles a market from its completed ballot, irrespective of later execution or cancellation.
    /// @dev Early cancellations are recorded by `_cancel`. Failed quorum and ties settle Against.
    ///      Anyone may finalize; claims and orphan burns also finalize lazily.
    function finalizeMarket(uint256 proposalId) public returns (uint8 outcome) {
        outcome = marketOutcome[proposalId];
        if (outcome != UNSETTLED) return outcome;
        ProposalState current = state(proposalId); // Also validates proposal existence.
        if (clock() <= proposalDeadline(proposalId)) {
            if (current != ProposalState.Canceled) revert MarketNotFinalized();
            outcome = REFUND;
        } else {
            outcome = _quorumReached(proposalId) && _voteSucceeded(proposalId)
                ? FOR : AGAINST;
        }
        marketOutcome[proposalId] = outcome;
        emit MarketFinalized(proposalId, outcome);
    }

    /// @notice Stakes coins on the outcome of a governance proposal (PvP Prediction Market).
    /// @dev    Tokens are transferred from the user to the Governor. Can only be called during Pending or Active states.
    ///         Zero-amount stakes are rejected to avoid meaningless market entries and event spam.
    /// @param  proposalId The ID of the proposal to stake on.
    /// @param  supportFor Set to `true` to bet that the proposal will succeed. Set to `false` to bet it will fail.
    /// @param  amount The non-zero amount of DigilCoin to stake.
    function stake(uint256 proposalId, bool supportFor, uint256 amount) external {
        if (amount == 0) revert InvalidParams();

        ProposalState currentState = state(proposalId);

        // Can only enter the market while voting is pending or active
        if (currentState != ProposalState.Pending && currentState != ProposalState.Active) {
            revert InvalidProposalState(currentState);
        }

        address sender = _msgSender();
        ProposalMarket storage market = proposalMarkets[proposalId];

        // --- EFFECTS ---
        mapping(address => uint256) storage stakes = supportFor ? market.stakeFor : market.stakeAgainst;
        stakes[sender] += amount;
        if (supportFor) market.totalStakedFor += amount;
        else market.totalStakedAgainst += amount;

        // --- INTERACTION ---
        _pull(sender, amount);

        emit Stake(proposalId, sender, supportFor, amount);
    }

    /// @notice Claims winnings or a refund for a finalized proposal market.
    /// @dev    If the user bet correctly, they receive their principal plus a proportional share of the losing side's pool.
    ///         Only cancellation before voting finishes refunds principal. Later cancellation cannot change settlement.
    ///         Calculates payout dynamically and clears user balances before transfer (CEI pattern).
    ///         Integer division can leave small residual dust in the contract after all claims.
    /// @param  proposalId The ID of the finalized proposal to claim from.
    function claim(uint256 proposalId) external {
        uint8 outcome = finalizeMarket(proposalId);

        address sender = _msgSender();
        ProposalMarket storage market = proposalMarkets[proposalId];
        
        uint256 userFor = market.stakeFor[sender];
        uint256 userAgainst = market.stakeAgainst[sender];
        
        if (userFor == 0 && userAgainst == 0) revert NoStake();

        // Clear balances first to prevent reentrancy
        market.stakeFor[sender] = 0;
        market.stakeAgainst[sender] = 0;

        uint256 payout;
        if (outcome == REFUND) {
            payout = userFor + userAgainst;
        } else {
            (uint256 winningPool, uint256 losingPool) = _marketPools(market, outcome);
            uint256 stakeWon = outcome == FOR ? userFor : userAgainst;
            if (stakeWon == 0) revert StakeLostOrNothingToClaim();
            payout = stakeWon + Math.mulDiv(stakeWon, losingPool, winningPool);
        }

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

        uint8 outcome = finalizeMarket(proposalId);
        (uint256 winningPool, uint256 amountToBurn) = _marketPools(market, outcome);
        if (outcome == REFUND || winningPool != 0 || amountToBurn == 0) revert NoOrphanedStakes();

        // --- Effects ---
        market.orphanedSwept = true;

        // --- Bounty (paid out of the orphaned pool), then burn remainder ---
        uint256 bounty = amountToBurn / 100; // 1%
        if (bounty != 0) {
            _transfer(_msgSender(), bounty);
            unchecked { amountToBurn -= bounty; } // bounty is at most amountToBurn / 100.
        }

        IERC20Burnable(address(token())).burn(amountToBurn);
        emit Burn(proposalId, amountToBurn);
    }

    function _marketPools(ProposalMarket storage market, uint8 outcome) private view returns (uint256 winning, uint256 losing) {
        winning = market.totalStakedFor;
        losing = market.totalStakedAgainst;
        if (outcome != FOR) return (losing, winning);
    }
}
