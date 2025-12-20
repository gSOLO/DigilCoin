// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title Digil Coin (ERC20)
/// @author gSOLO
/// @notice ERC20 governance + utility coin used by DigilToken and related protocol components.
/// @dev
/// ## Token features
/// - ERC20 + burnable + pausable
/// - ERC2612 Permit approvals (ERC20Permit)
/// - ERC20Votes for delegation + vote checkpoints (timestamp clock via ERC6372-style `clock()`/`CLOCK_MODE()`)
/// - AccessControl roles for minting/pausing/rewards configuration
///
/// ## Donor-funded ETH rewards (NOT holding-based)
/// This contract implements an ETH rewards system that is intentionally **not dependent on holding** DigilCoin.
/// Users earn points by *spending* DigilCoin into eligible contracts **only when those contracts pull funds via `transferFrom`**:
/// - A spend is eligible iff:
///   - `spendWeightBps[to] > 0` (allowlisted spender contract)
///   - `msg.sender == to` (the spender contract initiated the pull)
///   - `from != 0` and `to != 0` (not mint/burn)
///
/// Donors fund ETH pools via `donate()` and `receive()`; users claim pro-rata by effective points.
/// Effective points include a **days-active multiplier** (based on uncapped raw spend), while point-earning is
/// capped daily and per-epoch to limit gaming. Remaining ETH is swept forward so it never becomes unclaimable.
/// @custom:security-contact security@digil.co.in
contract DigilCoin is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ERC20Permit, ERC20Votes {
    // Roles

    /// @notice Can pause token transfers.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Can mint new tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Can configure rewards settings (spender weights, caps, thresholds, multipliers).
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    // Rewards parameters (units & defaults are configurable)

    /// @notice Fixed denominator for basis-point math (100.00% = 10,000 bps).
    uint16 public constant BASE_BPS = 10_000;

    /// @notice Number of epoch snapshots stored in a ring buffer (12 ≈ 12 months).
    uint8 public constant STORED_EPOCHS = 12;

    /// @notice Number of completed epochs that are claimable (3 ≈ a quarter).
    uint8 public constant CLAIMABLE_EPOCHS = 3;

    /// @notice Epoch length in seconds (30 days fixed-month approximation).
    uint32 public constant EPOCH_LENGTH = 30 days;

    /// @notice Minimum raw eligible spend in a day required to count that day as "active".
    /// @dev Uses raw (uncapped) eligible spend so the active-days multiplier can keep increasing
    ///      even if the user's *counted* spend hits caps.
    uint256 public minDailySpend;

    /// @notice Max *counted* eligible spend per day for point accrual (anti-gaming cap).
    uint256 public dailyCap;

    /// @notice Max *counted* eligible spend per epoch for point accrual (anti-gaming cap).
    uint256 public epochCap;

    /// @notice Bonus applied per active day in bps (e.g., 100 = +1% per active day).
    uint16 public dayBonusBps;

    /// @notice Maximum number of active days that may contribute to the multiplier.
    uint8 public maxActiveDays;

    /// @notice Mapping of eligible spender contracts to their weight in basis points.
    /// @dev `0` = not eligible. Weight is multiplied into points: deltaPoints = countedSpend * weightBps.
    ///      Keeping weights configurable allows steering incentives over time.
    mapping(address => uint16) public spendWeightBps;

    // Rewards storage (bounded ring buffer)

    /// @notice Snapshot of a single epoch.
    /// @dev Stored in a ring buffer slot keyed by `epochId % STORED_EPOCHS`.
    struct EpochSnap {
        /// @notice Absolute epoch identifier.
        uint32 epochId;
        /// @notice Epoch start timestamp.
        uint32 startTime;
        // Reward parameter snapshots for this epoch (critical for math correctness).
        uint16 dayBonusBps;
        uint8  maxActiveDays;
        /// @notice Total ETH allocated to this epoch (donations + sweeps).
        uint256 poolEth;
        /// @notice ETH already paid out for this epoch (sum of user claims).
        uint256 claimedEth;
        /// @notice Total effective points for the epoch (sum over all users).
        uint256 totalEff;
    }

    /// @notice Per-user data for a specific epoch.
    /// @dev Stored per user per ring-slot, with `epochId` inside to detect stale/reused slots.
    struct UserEpoch {
        /// @notice Absolute epoch id this slot currently represents for this user.
        uint32 epochId;

        /// @notice Last computed day index (0..29) for which daily counters are valid.
        uint8 lastDayIndex;

        /// @notice Number of active days counted for multiplier (capped at `maxActiveDays`).
        uint8 activeDays;

        /// @notice Bitmap tracking which days (0..29) have been marked active.
        /// @dev Lower 30 bits used; 1 bit per day.
        uint32 activeBitmap;

        /// @notice Flags:
        /// - bit0: claimed for this epoch
        uint8 flags;

        /// @notice Counted eligible spend today (resets on day change).
        uint128 countedDaySpend;

        /// @notice Raw (uncapped) eligible spend today (resets on day change).
        uint128 rawDaySpend;

        /// @notice Counted eligible spend this epoch (resets on epoch change).
        uint128 countedEpochSpend;

        /// @notice Raw points accumulated this epoch, already scaled by spender weight bps.
        /// @dev points = Σ(countedSpend * weightBps). Effective points add multiplier at claim time.
        uint256 points;
    }

    /// @dev Ring buffer storing the last STORED_EPOCHS epoch snapshots.
    EpochSnap[STORED_EPOCHS] internal _epochs;

    /// @dev Per-user per-slot epoch data. Slot = epochId % STORED_EPOCHS.
    mapping(uint8 => mapping(address => UserEpoch)) internal _userEpoch;

    /// @notice Current epoch id.
    uint32 public currentEpochId;

    /// @notice Current epoch start timestamp.
    uint32 public currentEpochStart;

    /// @notice Total ETH ever accounted into pools (donations + absorbed untracked ETH).
    uint256 public totalDonatedEth;

    /// @notice Total ETH ever claimed by users.
    uint256 public totalClaimedEth;

    // Events

    /// @notice Emitted when ETH is donated into the current epoch pool.
    event Donation(address indexed donor, uint256 amount, uint32 indexed epochId);

    /// @notice Emitted when an eligible spender weight is updated.
    event SpenderWeightSet(address indexed spender, uint16 weightBps);

    /// @notice Emitted when a user claims rewards for an epoch.
    event Claim(address indexed account, uint32 indexed epochId, uint256 amount, uint256 userEff, uint256 totalEff);

    /// @notice Emitted when the epoch is fast forwarded.
    event EpochFastForward(uint32 indexed fromEpochId, uint32 indexed toEpochId, uint256 sweptEth);

    /// @notice Emitted when the epoch advances.
    event EpochAdvance(uint32 indexed newEpochId, uint32 newStartTime);

    /// @notice Emitted when unclaimable ETH is swept forward into the current epoch.
    event SweptUnclaimable(uint32 indexed expiredEpochId, uint256 amountSwept, uint32 indexed intoEpochId);

    /// @notice Emitted when an epoch ends with no participants and its pool is rolled forward.
    event RolledForwardNoParticipants(uint32 indexed endedEpochId, uint256 amountRolled, uint32 indexed intoEpochId);

    /// @notice Emitted when forced/untracked ETH is absorbed into the current epoch pool.
    event SyncedUntrackedEth(uint256 amountAdded, uint32 indexed intoEpochId);

    /// @notice Emitted when reward parameters are updated.
    event ParametersUpdate(uint256 minDailySpend, uint256 dailyCap, uint256 epochCap, uint16 dayBonusBps, uint8 maxActiveDays);

    // Errors

    error EpochNotFound();
    error EpochNotClaimable();
    error AlreadyClaimed();
    error NothingToClaim();
    error ClaimTransferFailed();
    error BadParameters();

    // Constructor

    /// @notice Creates DigilCoin and initializes roles and the first epoch.
    /// @param defaultAdmin Address granted DEFAULT_ADMIN_ROLE, PAUSER_ROLE, MINTER_ROLE, and REWARDS_ROLE.
    constructor(address defaultAdmin) ERC20("Digil Coin", "DIGIL") ERC20Permit("Digil Coin") {
        // Role bootstrap
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(CONFIG_ROLE, defaultAdmin);

        // Recommended starting defaults (tune as desired)
        // - minDailySpend below 100 (aligns with your DigilToken daily coin amounts)
        // - dailyCap 500 and epochCap 5000 per your latest plan
        minDailySpend = 50e18;
        dailyCap = 500e18;
        epochCap = 5_000e18;
        dayBonusBps = 100;   // +1% per active day
        maxActiveDays = 20;  // max +20%

        // Initialize epoch 0 at deploy time
        currentEpochId = 0;
        currentEpochStart = uint32(block.timestamp);

        EpochSnap storage e0 = _epochs[0];
        e0.epochId = 0;
        e0.startTime = currentEpochStart;
        e0.dayBonusBps = dayBonusBps;
        e0.maxActiveDays = maxActiveDays;
    }

    // Admin / role-gated functions (existing features, restored NatSpec)

    /// @notice Pauses token transfers.
    /// @dev While paused, transfers, mints, and burns revert (ERC20Pausable).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses token transfers.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Mints `amount` DigilCoin to `to`.
    /// @dev Restricted to MINTER_ROLE. Minting updates ERC20Votes checkpoints.
    /// @param to Recipient of minted tokens.
    /// @param amount Amount to mint (token decimals apply).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // Rewards configuration

    /// @notice Sets the reward weight (in bps) for an eligible spender contract.
    /// @dev
    /// - `weightBps == 0` disables eligibility for that spender.
    /// - `weightBps` is applied to counted spend as: `deltaPoints = countedSpend * weightBps`.
    /// - Eligibility *also* requires `msg.sender == spender` so arbitrary user transfers do not earn points.
    /// @param spender The contract address that will be eligible to earn rewards for users who spend into it.
    /// @param weightBps Weight in basis points, must be <= 10,000.
    function setSpendWeight(address spender, uint16 weightBps) external onlyRole(CONFIG_ROLE) {
        if (spender == address(0) || weightBps > BASE_BPS) revert BadParameters();
        spendWeightBps[spender] = weightBps;
        emit SpenderWeightSet(spender, weightBps);
    }

    /// @notice Updates reward parameters (thresholds/caps/multiplier settings).
    /// @dev These parameters affect future accrual; they do not retroactively change ended epochs.
    /// @param _minDailySpend Minimum raw eligible spend in a day needed to count that day as active.
    /// @param _dailyCap Max counted spend per day used for point accrual.
    /// @param _epochCap Max counted spend per epoch used for point accrual.
    /// @param _dayBonusBps Bonus bps added per active day (e.g., 100 = +1%).
    /// @param _maxActiveDays Maximum number of active days counted for multiplier.
    function setRewardParameters(uint256 _minDailySpend, uint256 _dailyCap, uint256 _epochCap, uint16 _dayBonusBps, uint8 _maxActiveDays) external onlyRole(CONFIG_ROLE) {
        // Bound active-day settings so multiplier math stays sane and cannot overflow
        // in extreme admin misconfiguration scenarios.
        if (_maxActiveDays == 0 || _maxActiveDays > 30) revert BadParameters();
        if (_dayBonusBps > 1_000) revert BadParameters(); // <= +10% per active day
        uint256 maxMultBps = uint256(BASE_BPS) + uint256(_maxActiveDays) * uint256(_dayBonusBps);
        if (maxMultBps > 50_000) revert BadParameters(); // hard cap: 5.0x effective multiplier

        if (_dailyCap == 0 || _epochCap == 0 || _dailyCap > _epochCap) revert BadParameters();

        _syncEpoch(); // ensure we are configuring for future epochs, not a stale "current" one

        minDailySpend = _minDailySpend;
        dailyCap = _dailyCap;
        epochCap = _epochCap;
        dayBonusBps = _dayBonusBps;
        maxActiveDays = _maxActiveDays;

        emit ParametersUpdate(_minDailySpend, _dailyCap, _epochCap, _dayBonusBps, _maxActiveDays);
    }

    // Donations (ETH funding)

    /// @notice Donates ETH into the current epoch reward pool.
    /// @dev Calls `_syncEpoch()` first so donations always land in the correct epoch.
    function donate() external payable {
        _donate(msg.sender, msg.value);
    }

    /// @notice Accepts direct ETH transfers as donations into the current epoch reward pool.
    /// @dev This is intentionally non-reverting; donors can send ETH directly.
    receive() external payable {
        _donate(msg.sender, msg.value);
    }

    /// @dev Internal donation accounting. No-op for zero donations.
    function _donate(address donor, uint256 amount) internal {
        if (amount == 0) return;

        // Ensure we are donating into the correct epoch.
        _syncEpoch();

        // Add to current epoch pool.
        uint8 slot = _epochSlot(currentEpochId);
        _epochs[slot].poolEth += amount;

        // Global accounting used to detect forced/untracked ETH.
        totalDonatedEth += amount;

        emit Donation(donor, amount, currentEpochId);
    }

    /// @notice Absorbs any ETH that exists in the contract balance but was not accounted into pools.
    /// @dev
    /// ETH can be forced into the contract without calling `receive()` (e.g., via `selfdestruct`).
    /// This function detects any untracked ETH and credits it to the current epoch pool so it can be claimed.
    /// Safe to call anytime; if there is no untracked ETH it does nothing.
    function syncUntrackedEth() external {
        _syncEpoch();

        // "Outstanding pooled ETH" = donated - claimed.
        // If contract balance exceeds that, the extra ETH is untracked/forced ETH.
        uint256 outstanding = totalDonatedEth - totalClaimedEth;
        uint256 bal = address(this).balance;
        if (bal <= outstanding) return;

        uint256 diff = bal - outstanding;
        uint8 slot = _epochSlot(currentEpochId);

        _epochs[slot].poolEth += diff;
        totalDonatedEth += diff;

        emit SyncedUntrackedEth(diff, currentEpochId);
        emit Donation(address(0), diff, currentEpochId);
    }

    // Claiming

    /// @notice Claims ETH rewards for a completed, claimable epoch.
    /// @dev
    /// - Epoch must be completed: `epochId < currentEpochId`.
    /// - Epoch must be within claim window: last `CLAIMABLE_EPOCHS` completed epochs.
    /// - If `poolEth == 0` or `totalEff == 0`, claim pays 0 (and marks claimed).
    /// - Uses `call` to transfer ETH; reverts on failure.
    /// @param epochId The completed epoch identifier to claim against.
    function claim(uint32 epochId) external {
        _syncEpoch();

        // Must be a completed epoch.
        if (epochId >= currentEpochId) revert EpochNotClaimable();

        // Enforce claim window: [currentEpochId-CLAIMABLE_EPOCHS, currentEpochId-1]
        if (currentEpochId > uint32(CLAIMABLE_EPOCHS)) {
            if (epochId < currentEpochId - uint32(CLAIMABLE_EPOCHS)) revert EpochNotClaimable();
        }

        uint8 slot = _epochSlot(epochId);
        EpochSnap storage ep = _epochs[slot];
        if (ep.epochId != epochId) revert EpochNotFound();

        UserEpoch storage ue = _userEpoch[slot][msg.sender];
        if (ue.epochId != epochId) revert NothingToClaim();
        if ((ue.flags & 0x01) != 0) revert AlreadyClaimed();

        uint256 pool = ep.poolEth;
        uint256 totalEff = ep.totalEff;

        // Mark claimed even if payout is 0, to prevent repeated calls.
        ue.flags |= 0x01;

        if (pool == 0 || totalEff == 0) {
            emit Claim(msg.sender, epochId, 0, 0, totalEff);
            return;
        }

        // User effective points = points * (BASE + activeDays*dayBonusBps)
        uint256 userEff = ue.points * (uint256(BASE_BPS) + uint256(ue.activeDays) * uint256(ep.dayBonusBps));
        if (userEff == 0) {
            emit Claim(msg.sender, epochId, 0, 0, totalEff);
            return;
        }

        // Pro-rata payout (rounded down).
        uint256 payout = (pool * userEff) / totalEff;

        // Ensure we never exceed remaining pool due to rounding edge-cases.
        uint256 remaining = pool - ep.claimedEth;
        if (payout > remaining) payout = remaining;

        // Update epoch + global accounting.
        ep.claimedEth += payout;
        totalClaimedEth += payout;

        if (payout != 0) {
            (bool ok,) = payable(msg.sender).call{value: payout}("");
            if (!ok) revert ClaimTransferFailed();
        }

        emit Claim(msg.sender, epochId, payout, userEff, totalEff);
    }

    /// @notice Claims multiple epochs in one call.
    /// @dev Convenience helper for UX; each epoch is validated individually.
    /// @param epochIds Array of epoch ids to claim.
    function claimMany(uint32[] calldata epochIds) external {
        // `_syncEpoch()` is called in `claim` for each epoch; doing it once here is cheaper and safe.
        _syncEpoch();
        for (uint256 i = 0; i < epochIds.length; i++) {
            // Call internal logic for each epoch (avoid re-sync).
            _claimNoSync(epochIds[i]);
        }
    }

    /// @dev Internal claim used by `claimMany` to avoid repeated `_syncEpoch()` cost.
    function _claimNoSync(uint32 epochId) internal {
        if (epochId >= currentEpochId) revert EpochNotClaimable();
        if (currentEpochId > uint32(CLAIMABLE_EPOCHS)) {
            if (epochId < currentEpochId - uint32(CLAIMABLE_EPOCHS)) revert EpochNotClaimable();
        }

        uint8 slot = _epochSlot(epochId);
        EpochSnap storage ep = _epochs[slot];
        if (ep.epochId != epochId) revert EpochNotFound();

        UserEpoch storage ue = _userEpoch[slot][msg.sender];
        if (ue.epochId != epochId) revert NothingToClaim();
        if ((ue.flags & 0x01) != 0) revert AlreadyClaimed();

        ue.flags |= 0x01;

        uint256 pool = ep.poolEth;
        uint256 totalEff = ep.totalEff;
        if (pool == 0 || totalEff == 0) {
            emit Claim(msg.sender, epochId, 0, 0, totalEff);
            return;
        }

        uint256 userEff = ue.points * (uint256(BASE_BPS) + uint256(ue.activeDays) * uint256(ep.dayBonusBps));
        if (userEff == 0) {
            emit Claim(msg.sender, epochId, 0, 0, totalEff);
            return;
        }

        uint256 payout = (pool * userEff) / totalEff;
        uint256 remaining = pool - ep.claimedEth;
        if (payout > remaining) payout = remaining;

        ep.claimedEth += payout;
        totalClaimedEth += payout;

        if (payout != 0) {
            (bool ok,) = payable(msg.sender).call{value: payout}("");
            if (!ok) revert ClaimTransferFailed();
        }

        emit Claim(msg.sender, epochId, payout, userEff, totalEff);
    }

    // Rewards tracking (override ERC20 hook)

    /// @notice Central token movement hook (mint, burn, transfer).
    /// @dev Required override because ERC20Pausable and ERC20Votes both extend the transfer lifecycle.
    ///      We also piggyback to record eligible spend-to-earn activity:
    ///      - eligible spend is recorded only when `to` is allowlisted and `msg.sender == to`.
    ///      - this pattern matches contract-driven `transferFrom(user, contract, amount)` pulls.
    /// @param from Sender (zero on mint).
    /// @param to Recipient (zero on burn).
    /// @param value Amount moved.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        // First run the canonical OZ flow:
        // - enforces pause rules (reverts if paused)
        // - updates balances
        // - updates vote checkpoints
        super._update(from, to, value);

        // Only attempt rewards tracking for normal transfers (not mint/burn).
        if (from == address(0) || to == address(0) || value == 0) return;

        // Quick eligibility test before paying the cost of epoch sync.
        uint16 w = spendWeightBps[to];
        if (w == 0) return;

        // Critical anti-farming rule: only count if the recipient contract initiated the transferFrom pull.
        if (msg.sender != to) return;

        // Ensure epoch math is correct at boundary transitions.
        _syncEpoch();

        // Record points + active-day progress for the spender's weight.
        _recordEligibleSpend(from, w, value);
    }

    /// @dev Records eligible spend for a user:
    /// - tracks raw (uncapped) day spend to qualify active days
    /// - tracks counted spend subject to dailyCap/epochCap to earn points
    /// - updates epoch total effective points incrementally without user iteration
    function _recordEligibleSpend(address user, uint16 weightBps, uint256 amount) internal {
        uint32 eid = currentEpochId;
        uint8 slot = _epochSlot(eid);

        // Load user state for this epoch slot; if stale, reset for current epoch.
        EpochSnap storage ep = _epochs[slot];
        UserEpoch storage ue = _userEpoch[slot][user];
        if (ue.epochId != eid) {
            // Reset per-epoch counters for this user (new epoch or slot reuse).
            ue.epochId = eid;
            ue.lastDayIndex = 255; // force day reset on first touch
            ue.activeDays = 0;
            ue.activeBitmap = 0;
            ue.flags = 0;
            ue.countedDaySpend = 0;
            ue.rawDaySpend = 0;
            ue.countedEpochSpend = 0;
            ue.points = 0;
        }

        // Compute day index in [0..29] (safe because EPOCH_LENGTH=30 days).
        uint8 dayIndex = uint8((block.timestamp - uint256(currentEpochStart)) / 1 days);

        // On a new day, reset day counters (raw and counted).
        if (dayIndex != ue.lastDayIndex) {
            ue.lastDayIndex = dayIndex;
            ue.countedDaySpend = 0;
            ue.rawDaySpend = 0;
        }

        // --- Active day qualification (raw/uncapped spend) ---
        // We keep this separate from counted spend so active-day multiplier can continue to grow
        // even after the user hits daily/epoch point caps.
        {
            uint256 newRaw = uint256(ue.rawDaySpend) + amount;
            if (newRaw > type(uint128).max) newRaw = type(uint128).max;
            ue.rawDaySpend = uint128(newRaw);

            // If raw spend crosses minDailySpend, mark this day active once.
            if (uint256(ue.rawDaySpend) >= minDailySpend && ue.activeDays < ep.maxActiveDays) {
                uint32 mask = uint32(1) << dayIndex;
                if ((ue.activeBitmap & mask) == 0) {
                    ue.activeBitmap |= mask;
                    ue.activeDays += 1;

                    // Tricky part solved:
                    // Increasing activeDays increases the user's multiplier for the whole epoch.
                    // We increment epoch.totalEff by (existingPoints * dayBonusBps) to reflect that delta,
                    // without iterating or recomputing over the user's history.
                    if (ue.points != 0) {
                        ep.totalEff += ue.points * uint256(ep.dayBonusBps);
                    }
                }
            }
        }

        // --- Counted spend (capped) -> points ---
        // Apply dailyCap and epochCap to counted spend.
        uint256 dailyRemain = dailyCap > uint256(ue.countedDaySpend) ? (dailyCap - uint256(ue.countedDaySpend)) : 0;
        uint256 epochRemain = epochCap > uint256(ue.countedEpochSpend) ? (epochCap - uint256(ue.countedEpochSpend)) : 0;

        uint256 counted = _min3(amount, dailyRemain, epochRemain);
        if (counted == 0) return;

        // Update counted spend counters
        ue.countedDaySpend = uint128(uint256(ue.countedDaySpend) + counted);
        ue.countedEpochSpend = uint128(uint256(ue.countedEpochSpend) + counted);

        // Points are scaled by weight bps; we do not divide by 10,000 here to avoid precision loss.
        uint256 deltaPoints = counted * uint256(weightBps);
        ue.points += deltaPoints;

        // Increase epoch total effective points by deltaPoints * current multiplier.
        uint256 multBps = uint256(BASE_BPS) + uint256(ue.activeDays) * uint256(ep.dayBonusBps);
        ep.totalEff += deltaPoints * multBps;
    }

    // Epoch sync + sweep-forward logic (no trapped ETH)

    /// @notice Advances epochs and performs sweep-forward logic if enough time has elapsed.
    /// @dev Permissionless maintenance function. Very cheap; safe to call anytime.
    function syncEpoch() external {
        _syncEpoch();
    }

    /// @dev Advances epochs as needed so `currentEpochId`/`currentEpochStart` match `block.timestamp`.
    ///      Handles long inactivity by advancing multiple epochs in a single call.
    function _syncEpoch() internal {
        // How many full epochs have elapsed since currentEpochStart?
        uint256 elapsed = block.timestamp - uint256(currentEpochStart);
        uint32 steps = uint32(elapsed / uint256(EPOCH_LENGTH));
        if (steps == 0) return;

        // If the gap is "reasonable", advance normally (preserves detailed sweep events).
        // If it's huge, do an O(STORED_EPOCHS) fast-forward.
        //
        // Threshold choice: once steps is greater than STORED_EPOCHS + CLAIMABLE_EPOCHS,
        // every stored epoch is certainly unclaimable and intermediate simulation is unnecessary.
        if (steps <= uint32(STORED_EPOCHS + CLAIMABLE_EPOCHS)) {
            for (uint32 i = 0; i < steps; i++) _advanceEpoch();
        } else {
            _fastForwardEpochs(steps);
        }
    }

    /// @dev Fast-forwards epoch state when the contract has been inactive for a long period, avoiding an
    ///      unbounded `_advanceEpoch()` loop that could exceed the block gas limit.
    ///      This function is intended for *large* time gaps where simulating each intermediate epoch is unnecessary
    ///      because any stored epochs are far outside the claim window and therefore unclaimable.
    ///      Safety/Correctness properties:
    ///      - Preserves the "no trapped ETH" invariant by sweeping any remaining ETH from all currently stored
    ///        epoch snapshots into the new current epoch's pool.
    ///      - Resets the ring buffer to represent the most recent `STORED_EPOCHS` epochs ending at the computed
    ///        new current epoch, ensuring `epochId % STORED_EPOCHS` slot mapping remains valid.
    ///      - Clears per-epoch totals (`poolEth`, `claimedEth`, `totalEff`) for reinitialized epochs; per-user
    ///        epoch data becomes stale automatically via `UserEpoch.epochId` mismatch (lazy reset on next activity).
    ///      - Snapshots epoch-level reward parameters (e.g., `dayBonusBps`, `maxActiveDays`) into each new epoch,
    ///        ensuring claim math remains consistent within an epoch.
    ///      Gas complexity is O(STORED_EPOCHS) with bounded storage writes, preventing DoS due to long inactivity.
    /// @param steps Number of full epochs elapsed since `currentEpochStart` (must be > 0).
    function _fastForwardEpochs(uint32 steps) internal {
        uint32 fromId = currentEpochId;

        // Compute the new "current" epoch based on time jump.
        uint32 toId = fromId + steps;
        uint32 toStart = currentEpochStart + uint32(uint256(steps) * uint256(EPOCH_LENGTH));

        // 1) Sweep ALL remaining ETH from currently stored epoch slots.
        // These epochs are far beyond the claim window in a huge jump scenario,
        // so rolling/sweeping intermediate epochs individually is unnecessary.
        uint256 swept;
        for (uint256 i = 0; i < STORED_EPOCHS; i++) {
            EpochSnap storage ep = _epochs[i];

            // Only sweep if this slot is populated (epochId set) and has remaining ETH.
            // (If you initialize epochId for all slots always, the extra check is harmless.)
            uint256 rem = ep.poolEth > ep.claimedEth ? (ep.poolEth - ep.claimedEth) : 0;
            if (rem != 0) {
                swept += rem;
                // Mark remaining as swept so it can’t be double-counted.
                ep.poolEth = ep.claimedEth;
            }
        }

        // 2) Reinitialize ring buffer to represent the last STORED_EPOCHS epochs ending at `toId`.
        // Important: epochId must match slot = epochId % STORED_EPOCHS, so claims and lookups work.
        // We overwrite all 12 slots (bounded cost).
        for (uint32 k = 0; k < STORED_EPOCHS; k++) {
            uint32 eid = toId - k;
            uint8 slot = _epochSlot(eid);

            EpochSnap storage ep = _epochs[slot];
            ep.epochId = eid;
            ep.startTime = toStart - uint32(uint256(k) * uint256(EPOCH_LENGTH));

            // Snapshot the epoch parameters (per your previous critical fix).
            ep.dayBonusBps = dayBonusBps;
            ep.maxActiveDays = maxActiveDays;

            // Clear accounting. (Old userEpoch structs become stale via epochId mismatch.)
            ep.poolEth = 0;
            ep.claimedEth = 0;
            ep.totalEff = 0;
        }

        // 3) Update pointers to the new current epoch.
        currentEpochId = toId;
        currentEpochStart = toStart;

        // 4) Credit swept ETH into the new current epoch pool.
        if (swept != 0) {
            _epochs[_epochSlot(toId)].poolEth += swept;
        }

        emit EpochFastForward(fromId, toId, swept);
    }

    /// @dev Advances the epoch by 1 and performs sweep-forward policies:
    /// 1) If the epoch that just ended had no participants (`totalEff == 0`), roll its remaining pool forward immediately.
    /// 2) When an epoch becomes unclaimable (older than CLAIMABLE_EPOCHS), sweep any remaining pool forward,
    ///    ensuring ETH is never trapped/unclaimable.
    function _advanceEpoch() internal {
        uint32 prevId = currentEpochId;
        uint8 prevSlot = _epochSlot(prevId);
        EpochSnap storage prev = _epochs[prevSlot];

        // Move to next epoch.
        uint32 newId = prevId + 1;
        uint32 newStart = currentEpochStart + uint32(EPOCH_LENGTH);

        currentEpochId = newId;
        currentEpochStart = newStart;

        // Initialize/overwrite the new epoch slot (slot reuse occurs after 12 epochs).
        uint8 newSlot = _epochSlot(newId);
        EpochSnap storage cur = _epochs[newSlot];
        cur.epochId = newId;
        cur.startTime = newStart;
        // Snapshot current global reward parameters into this epoch.
        cur.dayBonusBps = dayBonusBps;
        cur.maxActiveDays = maxActiveDays;
        cur.poolEth = 0;
        cur.claimedEth = 0;
        cur.totalEff = 0;

        emit EpochAdvance(newId, newStart);

        // --- Policy 1: ended epoch with no participants -> roll forward ---
        // If totalEff==0, nobody can ever claim from that epoch, so we roll it forward immediately.
        if (prev.epochId == prevId) {
            uint256 remPrev = prev.poolEth > prev.claimedEth ? (prev.poolEth - prev.claimedEth) : 0;
            if (remPrev != 0 && prev.totalEff == 0) {
                cur.poolEth += remPrev;
                // Mark as fully swept: remaining becomes 0.
                prev.poolEth = prev.claimedEth;
                emit RolledForwardNoParticipants(prevId, remPrev, newId);
            }
        }

        // --- Policy 2: sweep newly unclaimable epoch forward ---
        // Once we enter epoch `newId`, the first epoch that becomes unclaimable is:
        // expiredId = newId - (CLAIMABLE_EPOCHS + 1)
        if (newId > uint32(CLAIMABLE_EPOCHS)) {
            uint32 expiredId = newId - uint32(CLAIMABLE_EPOCHS + 1);
            uint8 expiredSlot = _epochSlot(expiredId);
            EpochSnap storage exp = _epochs[expiredSlot];

            // Only sweep if the slot actually corresponds to that epoch id.
            if (exp.epochId == expiredId) {
                uint256 rem = exp.poolEth > exp.claimedEth ? (exp.poolEth - exp.claimedEth) : 0;
                if (rem != 0) {
                    cur.poolEth += rem;
                    // Mark remaining as swept to prevent trapping/ double-sweeps.
                    exp.poolEth = exp.claimedEth;
                    emit SweptUnclaimable(expiredId, rem, newId);
                }
            }
        }
    }

    /// @dev Returns the ring buffer slot for an epoch id.
    function _epochSlot(uint32 epochId) internal pure returns (uint8) {
        return uint8(epochId % STORED_EPOCHS);
    }

    /// @dev Returns the minimum of three values.
    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    // Read-only helpers (useful for UI/analytics)

    /// @notice Returns the stored snapshot for `epochId`.
    /// @dev Reverts if the epoch is not stored in the current ring buffer window.
    /// @param epochId Epoch to fetch.
    function getEpoch(uint32 epochId) external view returns (EpochSnap memory) {
        uint8 slot = _epochSlot(epochId);
        EpochSnap memory ep = _epochs[slot];
        if (ep.epochId != epochId) revert EpochNotFound();
        return ep;
    }

    /// @notice Returns the caller's per-epoch data for `epochId`.
    /// @dev Reverts if the caller has no data for that epoch (never earned points) or the epoch is not stored.
    /// @param user Address to fetch.
    /// @param epochId Epoch to fetch.
    function getUserEpoch(address user, uint32 epochId) external view returns (UserEpoch memory) {
        uint8 slot = _epochSlot(epochId);
        UserEpoch memory ue = _userEpoch[slot][user];
        if (ue.epochId != epochId) revert NothingToClaim();
        return ue;
    }

    /// @notice Previews the claimable ETH amount for `user` in `epochId` (view-only estimate).
    /// @dev This does not check claim window or claimed flag; it is for UI display.
    /// @param user User to preview.
    /// @param epochId Epoch to preview.
    function previewClaim(address user, uint32 epochId) external view returns (uint256) {
        uint8 slot = _epochSlot(epochId);
        EpochSnap memory ep = _epochs[slot];
        if (ep.epochId != epochId) return 0;

        UserEpoch memory ue = _userEpoch[slot][user];
        if (ue.epochId != epochId) return 0;

        uint256 pool = ep.poolEth;
        uint256 totalEff = ep.totalEff;
        if (pool == 0 || totalEff == 0) return 0;

        uint256 userEff = ue.points * (uint256(BASE_BPS) + uint256(ue.activeDays) * uint256(ep.dayBonusBps));
        if (userEff == 0) return 0;

        uint256 payout = (pool * userEff) / totalEff;

        uint256 remaining = pool - ep.claimedEth;
        if (payout > remaining) payout = remaining;

        return payout;
    }

    // ERC6372 clock (Votes/Governor compatibility)

    /// @notice ERC6372 clock used by ERC20Votes/Governor for snapshots.
    /// @dev Timestamp-based clock ensures Governor proposals/votes operate in time units.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice ERC6372 clock mode descriptor.
    /// @dev Signals to off-chain tooling and OZ internals that `clock()` is timestamp-based.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // Required overrides

    /// @notice Returns the current nonce for `owner` used by ERC2612 permit signatures.
    /// @dev Required override because both ERC20Permit and Nonces define `nonces`.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
