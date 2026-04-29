// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

// Import OpenZeppelin contracts for standard ERC721 functionality, ownership, safe transfers, counters, ERC20 interfacing, and reentrancy protection.
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20Mintable} from "contracts/IERC20Mintable.sol";

import {DigilFlags} from "contracts/DigilFlags.sol";
import {DigilAppearance} from "contracts/DigilAppearance.sol";

/// @title Digital Sigils (NFT)
/// @author gSOLO
/// @notice NFT contract used for the creation, charging, and activation of Digital Sigils ("Digils")
/// @dev Digital Sigils are powered by the Digil Coin ERC20 (symbol: DIGIL).
/// @custom:security-contact security@digil.co.in
contract DigilToken is ERC721, Ownable, IERC721Receiver, ReentrancyGuard {
    // Immutable contract-level variables set during construction
    IERC20Mintable private immutable _coins;    // The ERC20 token used for coin transfers within the contract
    uint256 private immutable _coinMultiplier;  // Multiplier based on the ERC20 token's decimals to handle calculations correctly
    
    // Coin rate and bonus rate
    uint256 private _coinRate;                                  // Mutable coin rate for various operations, set by the owner
    uint256 private constant BONUS_RATE_DIVISOR = 100;          // Divisor for calculating bonus coins when value is added
    uint256 private constant MIN_COIN_RATE = 10;                // The minimum coin rate for operations
    uint256 private constant MAX_COIN_RATE = 1000000000;        // The maximum coin rate for operations

    // Constants for bonus interval and multiplier
    uint256 private constant YIELD_PERIOD = 7;                  // Number of days required for a holder to earn 100% of their NFT balance in bonus coins (denominator for holder-yield sizing).
    uint256 private constant BONUS_INTERVAL = 15 minutes;       // Collector-yield interval. Each full interval earns 1% of the checkpoint cap; yield saturates at the cap until the next checkpoint.
    uint256 private constant VALUE_MULTIPLIER = 1000 gwei;      // A base unit to simplify setting minimum value

    // Configuration values for incremental and transfer values
    uint256 private constant MAX_INCREMENTAL_VALUE = 1 ether;   // Upper bound on the global incremental value
    uint256 private _incrementalValue = 100 * VALUE_MULTIPLIER; // Minimum incremental ETH value required for charging
    uint256 private _transferValue = 95 * VALUE_MULTIPLIER;     // The portion of incremental value distributed to users

    // Planar token policy
    uint256 private constant PLANAR_MAX_ID = 18;                // Highest user-alignable plane ID.
    uint256 private constant PLANAR_TRANSFER_MAX_ID = 20;       // Highest minted/admin planar ID. The planar set is [0 .. PLANAR_TRANSFER_MAX_ID] inclusive.
    bool private _planarTransferActive;                         // When true, a temporary transfer window is open to move planar tokens from the current owner to the new owner during `transferOwnership`.

    // Batch operations limiter
    uint16 private _batchSize = 128;                            // Configurable batch size for distribution or discharge operations
    uint256 private constant MIN_BATCH_SIZE = 32;               // Minimum number of items to process in a single batch operation
    uint256 private constant MAX_BATCH_SIZE = 1024;             // Maximum number of items to process in a single batch operation
    uint256 private constant KEEPER_BOUNTY_DIVISOR = 100;       // Divisor for the inflationary bounty minted to Keepers (100 = 1% of batch volume)

    // Define the inactivity period for reclaiming contributions
    uint256 private constant INACTIVITY_PERIOD = 90 days;       // A short timeout to reclaim contributions from tokens after inactivity

    // Max link and affinity bonus scale
    uint256 private constant MAX_LINKS = 10;                    // Maximum number of links a token can have
    uint256 private constant AFFINITY_BOOST = 2;                // Multiplier for strong affinity bonuses
    uint256 private constant AFFINITY_REDUCTION = 2;            // Divisor for weak affinity bonuses and charge-balancing penalties

    // Buff configuration
    uint256 private constant MAX_BUFF_BONUS = 100;               // Maximum temporary bonus
    uint256 private constant MAX_BUFF_DURATION_MIN = 7 * 24 * 60;// Maximum duration of buffs (7 days)
    uint256 private constant LINK_BUFF_COST_FACTOR = 24 * 60;    // Minutes per pricing unit; 1440 means one magnitude-point-day per link costs _coinRate.

    // Mappings for token data, blacklisted addresses, distributions, and contract tokens
    mapping(uint256 => Token) private _tokens;                                      // Mapping from token ID to its detailed Token struct
    mapping(address => bool) private _blacklisted;                                  // Mapping for addresses that have opted out of the system
    mapping(address => Distribution) private _distributions;                        // Mapping for pending distributions of coins and ETH value per address
    mapping(address => mapping(uint256 => ContractToken)) private _contractTokens;  // Stores data for vaulted external ERC721 tokens
    /// @dev address(0)    = Unvaulted
    ///      address(this) = Fully Vaulted (attached to a Digil)
    ///      User Address  = Pending Vault (deposited by user, waiting for fee payment)
    mapping(address => mapping(uint256 => address)) private _contractTokenAddresses;// Tracks the current owner of an external ERC721 token in the vault. (externalContract, externalTokenId).
    /// @dev (externalContract, externalTokenId) => digilTokenId. 0 means no active wrapper.
    ///      Used by {recallToken} to resolve the Digil that currently wraps a vaulted external token.
    mapping(address => mapping(uint256 => uint256)) private _vaultedTokenIds;       // Reverse index for external ERC721 tokens that are fully vaulted in this contract.      



    /// @dev Structure to hold pending coin and value distributions for a user, and
    ///      the timestamp of the last bonus accrual checkpoint (used by {withdraw}).
    struct Distribution {
        uint256 time;   // Collector-yield checkpoint timestamp. Resets on yield checkpoints, even if no bonus is accrued.
        uint256 coins;  // Pending ERC20 coins to be withdrawn
        uint256 value;  // Pending Ether value to be withdrawn
    }

    /// @dev Contribution/accounting state for one contributor on one token.
    struct TokenContribution {
        uint256 charge;     // Coins contributed to the token's charge, including coins from affinity bonus
        uint256 discharge;  // Coins contributed to the token's charge, excluding coins from affinity bonus
        uint256 value;      // Ether value contributed
        uint256 epoch;      // Logical contribution epoch for the token
        bool exists;        // True if the contributor exists (has contributed)
        bool whitelisted;   // True if the contributor is whitelisted
    }

    /// @dev Structure to represent a vaulted external ERC721 token
    struct ContractToken {
        uint256 tokenId;    // The token ID of the external ERC721
        bool recallable;    // True if the owner can recall the token
    }

    /// @dev Structure to represent link efficiency between tokens
    struct LinkEfficiency {
        uint8 base;             // The base efficiency percentage for coin transfer (e.g., 100 = 100%)
        uint256 affinityBonus;  // Additional bonus efficiency generated from planar affinity
    }

    /// @dev State for a temporary buff on a token.
    ///      - The buff is considered "active" if `block.timestamp < expiresAt`.
    ///      - `appearance` is NOT temporary: this contract preserves it across full discharges
    ///        (see {dischargeToken}), so UI can treat it as an identity/skin payload.
    ///      - `magnitude` is the precomputed “power score” used for pricing:
    ///          * It is NOT just `efficiencyBonus` — it includes amplification, attunement tiering,
    ///            requested flags, and a small appearance-tagging weight (see {buffToken}).
    struct BuffState {
        uint120 appearance;     // Packed style/cosmetics/colors (see masks above). Persisted across discharges.

        uint40 expiresAt;       // Unix timestamp (seconds) when the temporary buff expires (0 means inactive/never set)
        uint16 magnitude;       // Precomputed pricing magnitude used by {_buffCost} and charged for new-link additions
        uint16 flags;           // Bitmask: STABILIZED/ANCHORED/PRIMED/REVERBERATED + tier tags

        uint8 efficiencyBonus;  // Added to outgoing link base efficiency while buff is active (0–100 typical; capped by input rules)
        uint8 attunement;       // Planar ID to *mimic* for affinity calculations while buff is active (1–17; 0 = none)
        uint8 amplification;    // Incoming active-charge multiplier (percentage). 20 => +20% boost; 100 => +100% (double)
    }

    struct Token {
        // --- SLOTS 0-6: Core Economic Properties ---
        uint256 charge;             // Accumulated charge from direct contributions
        uint256 distributionCharge; // Charge reserved for distributions
        uint256 activeCharge;       // Charge accumulated from active token operations and links
        uint256 value;              // Intrinsic value accumulated by the token
        uint256 distributionValue;  // Value reserved for distributions
        uint256 incrementalValue;   // Incremental value used for charging computations
        uint256 activationThreshold;// Required charge to activate the token (Lifecycle Property)

        // --- SLOTS 7-9: Batch & Logic State (Cannot pack uint256) ---
        uint256 distributionIndex;  // Current index for batch distribution processing
        uint256 contributionEpoch;  // Logical epoch for contributions on this token
        uint256 lastActivity;       // Timestamp of the last significant action

        // --- SLOT 10: State Flags & Buffs (Packed) ---
        // 4 bytes (bools) + 27 bytes (BuffState) = 31 bytes total.
        bool active;                // True if the token has been activated
        bool activating;            // A lock flag, true if the token is currently in the process of being activated
        bool discharging;           // A lock flag, true if the token is currently in the process of being discharged
        bool restricted;            // True if contributions are restricted to a whitelist
        BuffState buff;             // Temporary buff applied to this token.

        // --- SLOT 11: External Data ---
        // 20 bytes used. 12 bytes REMAINING.
        address contractTokenAddress; // External ERC721 contract address attached (if any)

        // --- SLOTS 12+: Dynamic Data ---
        // Must be at the end to avoid breaking the packing of Slot 10 & 11
        
        // Contributor Data
        address[] contributors;                                 // List of contributor addresses that have charged this token
        mapping(address => TokenContribution) contributions;    // Mapping from contributor to their contribution details

        // Linking Properties
        uint256[] links;                                    // Array of token IDs or plane IDs the token is linked to
        mapping(uint256 => LinkEfficiency) linkEfficiency;  // Mapping of link ID to its efficiency settings

        // Metadata
        string uri;                 // Token metadata URI
        bytes data;                 // Arbitrary data stored with the token
    }

    // Counter for generating unique token IDs
    uint256 private _nextTokenId;

    // Events and Errors

    /// @notice Emitted when the contract configuration is updated.
    /// @param  coinRate The new coin rate
    /// @param  incrementalValue The new minimum incremental value
    /// @param  transferValue The new transfer value
    /// @param  batchSize The new batch size
    event Configure(uint256 coinRate, uint256 incrementalValue, uint256 transferValue, uint16 batchSize);

    /// @notice Emitted when an address toggles opt-out status.
    /// @param  account The address whose status changed
    /// @param  optOut  True if the account is now opted out
    event OptStatus(address indexed account, bool optOut);

    /// @notice Emitted when an address is added to a token’s whitelist.
    /// @param  account The address of the account that was whitelisted
    /// @param  tokenId The ID of the token whose whitelist was updated
    event Whitelist(address indexed account, uint256 indexed tokenId);

    /// @notice Emitted when a token is restricted.
    /// @param  tokenId The ID of the token that was restricted
    event Restrict(uint256 indexed tokenId);

    /// @notice Emitted when a token is updated.
    /// @param  tokenId The ID of the token that was updated
    event Update(uint256 indexed tokenId);

    /// @notice Emitted when a batch operation (activation or discharge) makes partial progress.
    /// @param  tokenId The ID of the token being processed.
    event Batch(uint256 indexed tokenId);

    /// @notice Emitted when a token is activated.
    /// @dev    Check with tokenData to get an idea of its completion progress
    /// @param  tokenId The ID of the token that was or is being activated
    event Activate(uint256 indexed tokenId);

    /// @notice Emitted when a token is deactivated.
    /// @param  tokenId The ID of the token that was deactivated
    event Deactivate(uint256 indexed tokenId);

    /// @notice Emitted when a token is charged.
    /// @param  addr The address attributed with charging the token
    /// @param  tokenId The ID of the token being charged
    /// @param  coins The number of coins the token was charged with
    /// @param  value The value attributed to this charge
    event Charge(address indexed addr, uint256 indexed tokenId, uint256 coins, uint256 value);

    /// @notice Emitted when an active token is charged.
    /// @param  tokenId The ID of the token being charged
    /// @param  coins The number of coins the token was charged with
    event ActiveCharge(uint256 indexed tokenId, uint256 coins);

    /// @notice Emitted when a token is discharged.
    /// @dev    Check with tokenData to get an idea of its completion progress
    /// @param  tokenId The ID of the token that was or is being discharged
    event Discharge(uint256 indexed tokenId);

    /// @notice Emitted when a token is linked with efficiency details.
    /// @param  tokenId The ID of the token that was linked
    /// @param  linkId The ID of the token that was linked to
    /// @param  efficiency The efficiency of the link
    /// @param  affinityBonus The affinity bonus generated for the link
    event Link(uint256 indexed tokenId, uint256 indexed linkId, uint8 efficiency, uint256 affinityBonus);

    /// @notice Emitted when a token is unlinked.
    /// @param  tokenId The ID of the token that was unlinked
    /// @param  linkId The ID of the token that was unlinked from
    event Unlink(uint256 indexed tokenId, uint256 indexed linkId);

    /// @notice Emitted when a token's buff state changes.
    /// @dev Emitted for temporary buffs, stabilization, and priming.
    ///      Consumers can inspect {tokenBuff} after this event to determine the
    ///      current flags, expiry, appearance, and temporary buff parameters.
    /// @param tokenId The token whose buff state changed.
    event Buff(uint256 indexed tokenId);

    /// @notice Emitted when value is reclaimed from a token.
    /// @dev    This event is specifically tied to the reclaiming of a contribution after a period of inactivity. 
    ///         It records the portion of value contributed by a user that was used to "charge" the token—
    ///         think of this as satisfying a minimum requirement for charging the token.
    /// @param  addr The address this event is attributed to
    /// @param  tokenId The ID of the token whose value decreased
    /// @param  value The value that was added to pending distribution
    event Reclaim(address indexed addr, uint256 indexed tokenId, uint256 value);

    /// @notice Records additional value contributed to a token during charging
    ///         beyond the minimum required to satisfy its incremental value.
    /// @dev    This value is added directly to the token's intrinsic `value` and
    ///         does *not* increase the contributor's reclaimable stake (`c.value`).
    /// @param  addr     The address this event is attributed to (logical contributor).
    /// @param  tokenId  The ID of the token whose value increased.
    /// @param  value    The amount of surplus value credited to the token.
    event Contribute(address indexed addr, uint256 indexed tokenId, uint256 value);

    /// @notice Emitted when additional value is added to or created for a token.
    /// @dev    This event records general value additions to a token that occur outside the charging process.
    ///         It’s emitted in scenarios like token creation, restriction, or other operations
    ///         where value is added to the token without being tied to a specific charging action.
    /// @param  tokenId The ID of the token whose value increased
    /// @param  value The amount the token's value increased
    event Enrich(uint256 indexed tokenId, uint256 value);

    /// @notice Error thrown when insufficient funds are sent.
    /// @param  required The value required for the transaction
    error InsufficientFunds(uint256 required);

    /// @notice Error thrown when a coin transfer fails.
    /// @param  coins The number of coins required for the transaction that failed to transfer
    error CoinTransferFailed(uint256 coins);

    /// @notice Error thrown when a token's active coin count is insufficient to execute an operation.
    /// @param  required The activeCharge required for the transaction
    error InsufficientActiveCharge(uint256 required);

    /// @notice Contract constructor. Initializes state variables, mints initial planar tokens, and sets up contract parameters.
    /// @param  initialOwner The address that will own the contract and initial tokens
    /// @param  coins The address of the ERC20 token used as the system's currency
    /// @param  coinDecimals The number of decimals for the coin token
    constructor(address initialOwner, address coins, uint256 coinDecimals) ERC721("Digital Sigils", "DIGILS") Ownable(initialOwner) {
        _coins = IERC20Mintable(coins);
        _coinMultiplier = 10 ** coinDecimals;
        _coinRate = 100 * _coinMultiplier;
        _coins.approve(address(this), type(uint256).max); // Approve this contract to spend its own coins for distributions.
        
        string memory baseURI = "https://digil.co.in/token/";
        
        // Define an array of plane names for the initial tokens
        string[21] memory plane;
        plane[0] =  "";
        plane[1] =  "void";
        plane[2] =  "karma";
        plane[3] =  "kaos";
        plane[4] =  "fire";
        plane[5] =  "air";
        plane[6] =  "earth";
        plane[7] =  "water";
        plane[8] =  "ice";
        plane[9] =  "lightning";
        plane[10] = "metal";
        plane[11] = "nature";
        plane[12] = "harmony";
        plane[13] = "discord";
        plane[14] = "entropy";
        plane[15] = "exergy";
        plane[16] = "magick";
        plane[17] = "aether";
        plane[18] = "world";
        plane[19] = "virtual";
        plane[20] = "ilxr";

        // Define planar affinity data for each plane. This is used for calculating link bonuses
        // The format encodes strong and weak affinities for compact storage
        // 0:       identifier
        // 1:       strong affinity
        // 2:       strong affinity
        // 3:       moderate affinity
        // 4:       weak affinity
        // 5:       delimiter
        // 6-10:    simplified name
        bytes[21] memory data;
        data[0] =  bytes("     |     "); // null
        data[1] =  bytes("xrotk|X    "); // void
        data[2] =  bytes("roxyh|K.N  "); // karma
        data[3] =  bytes("orxyd|K.S  "); // kaos
        data[4] =  bytes("falym|X.S  "); // fire
        data[5] =  bytes("aflyn|X.E  "); // air
        data[6] =  bytes("ewnyf|X.N  "); // earth
        data[7] =  bytes("wenyi|X.W  "); // water
        data[8] =  bytes("im-yw|X.NW "); // ice
        data[9] =  bytes("lfaye|X.NE "); // lightning
        data[10] = bytes("mi-yl|X.NNE"); // metal
        data[11] = bytes("newya|X.NNW"); // nature
        data[12] = bytes("hrdyg|X.SE "); // harmony
        data[13] = bytes("dohyp|X.SW "); // discord
        data[14] = bytes("podty|K.W  "); // entropy
        data[15] = bytes("grhty|K.E  "); // negentropy/exergy
        data[16] = bytes("kpgtx|K    "); // magick/kosmos
        data[17] = bytes("txy--|K.X  "); // aether
        data[18] = bytes("yxt--|X.R  "); // external reality/world
        data[19] = bytes("-----|.XR  "); // extended reality
        data[20] = bytes("-----|.ILXR"); // digil reality
        
        // Mint the initial 21 "Plane" tokens (IDs 0-20)
        // Unchecked block used to mint the initial tokens without overflow checks (safe here due to known bounds)
        unchecked {
            // Loop until tokens 0 through 20 are minted
            while (_nextTokenId <= PLANAR_TRANSFER_MAX_ID) {
                // Get current ID and increment for next time
                uint256 tokenId = _nextTokenId++;

                _mint(initialOwner, tokenId);

                // Set token data for each minted token.
                Token storage t = _tokens[tokenId];
                // Set last activity
                t.lastActivity = block.timestamp;
                // Set active state
                t.active = true;
                // Set the token URI using the base URI concatenated with the plane name.
                t.uri = string(abi.encodePacked(baseURI, plane[tokenId]));
                // Store the planar data with the token.
                t.data = data[tokenId];
            }
        }

        // Token 0 is a special, restricted plane
        _tokens[0].restricted = true;
    }

    /// @dev    Internal helper to return the greater of two values.
    ///         Used to enforce floors on costs and incremental values.
    /// @param  a The first value.
    /// @param  b The second value.
    /// @return The greater of the two values.
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @inheritdoc ERC721
    /// @dev    For planar tokens, only the contract owner or this contract itself
    ///         is authorized to operate. Operator approvals and per-token approvals
    ///         are intentionally ignored for these IDs.
    function _isAuthorized(address owner_, address spender, uint256 tokenId) internal view override returns (bool) {
        if (tokenId <= PLANAR_TRANSFER_MAX_ID) {
            // Only the contract owner (admin) or this contract can operate planar tokens
            return (spender == owner()) || (spender == address(this));
        }
        return super._isAuthorized(owner_, spender, tokenId);
    }

    /// @inheritdoc Ownable
    /// @dev    Transfers ownership of the contract and planar tokens to a new account.
    ///         During this call, we briefly enable a "transfer window" that allows
    ///         planar tokens (IDs 0..20) currently held by the caller (current admin)
    ///         to be transferred to `newOwner`. This preserves the invariant that the
    ///         admin always controls planar tokens (and thus the base-URI token #0),
    ///         without seizing tokens from third parties (which is forbidden by ERC-721).
    /// @param  newOwner the address to transfer ownership to
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        // Before transferring contract ownership, also transfer all foundational Plane tokens.
        address caller = _msgSender();

        // Open the planar transfer window: planar tokens may move away from the current admin.
        _planarTransferActive = true;

        // Move only the planar tokens the caller actually holds (0..20 inclusive).
        // This respects ERC-721 authorization and avoids reverting if some tokens
        // have been purposefully sent elsewhere (which shouldn't happen under policy).
        for (uint256 tokenId; tokenId <= PLANAR_TRANSFER_MAX_ID; ) {
            if (_ownerOf(tokenId) == caller) {
                _transfer(caller, newOwner, tokenId);
            }
            unchecked { ++tokenId; } // gas: safe because tokenId <= PLANAR_TRANSFER_MAX_ID
        }

        // Close transfer window *before* changing admin to avoid accidental extra moves.
        _planarTransferActive = false;
        
        super.transferOwnership(newOwner);
    }

    // Configuration

    /// @notice Updates the core economic parameters of the contract.
    /// @dev    Only callable by the owner. This function controls the global
    ///         economic scale for the system:
    ///         - `coinRate` defines how many ERC20 Coins are minted / required
    ///           for key operations.
    ///         - `_incrementalValue` defines the global minimum ETH-per-coin
    ///           used by charging and other value-based flows and also acts as
    ///           a lower bound for per-token incrementalValue.
    ///         - `_transferValue` defines what portion of the incremental
    ///           value is routed back to users vs. retained as a protocol fee.
    ///         - `_batchSize` controls how many contributors are processed per
    ///           transaction during batch activation / discharge.
    ///
    ///         Reverts if:
    ///         - `coins` is outside the inclusive
    ///           `[MIN_COIN_RATE, MAX_COIN_RATE]` range.
    ///         - `incrementalValue` is not strictly greater than
    ///           `VALUE_MULTIPLIER` or exceeds `MAX_INCREMENTAL_VALUE`.
    ///         - `transferValue` is not between 90% and 99% of
    ///           `incrementalValue` (inclusive), ensuring a protocol fee of
    ///           between 1% and 10%.
    ///         - `batchSize` is outside the `[MIN_BATCH_SIZE, MAX_BATCH_SIZE]`
    ///           range.
    ///
    /// @param  coins             Base coin rate (unscaled), later multiplied by
    ///                           `_coinMultiplier` to produce `_coinRate`. This
    ///                           rate is used to:
    ///                           - Cap time-based bonus Coins in {withdraw}.
    ///                           - Price Token URI updates.
    ///                           - Price link creation and upgrades.
    ///                           - Price opt-in / opt-out.
    /// @param  incrementalValue  Global minimum incremental value (in wei) used
    ///                           when charging, activating, or updating Tokens.
    ///                           Must be strictly greater than `VALUE_MULTIPLIER`
    ///                           and less than or equal to `MAX_INCREMENTAL_VALUE`.
    /// @param  transferValue     Value (in wei) paid out per incremental unit
    ///                           when creating distributions. Must remain within
    ///                           [90%, 99%] of `incrementalValue` so that the
    ///                           protocol fee stays between 1% and 10%.
    /// @param  batchSize         Number of contributors processed per batch
    ///                           step, within `[MIN_BATCH_SIZE, MAX_BATCH_SIZE]`.
    function configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize) external onlyOwner {
        // Validate configuration parameters.
        require(
            coins >= MIN_COIN_RATE &&
            coins <= MAX_COIN_RATE &&
            incrementalValue > VALUE_MULTIPLIER &&
            incrementalValue <= MAX_INCREMENTAL_VALUE &&
            transferValue >= (incrementalValue * 9 / 10) &&          // ≥ 90% to user (≤ 10% fee)
            transferValue <= (incrementalValue * 99 / 100) &&        // ≤ 99% to user (≥ 1% fee)
            batchSize >= MIN_BATCH_SIZE &&
            batchSize <= MAX_BATCH_SIZE,
            "DIGIL: Invalid Configuration"
        );
        
        _coinRate = coins * _coinMultiplier;

        _incrementalValue = incrementalValue;
        _transferValue = transferValue;

        _batchSize = batchSize;
        
        emit Configure(_coinRate, _incrementalValue, _transferValue, batchSize);
    }

    // Coin Transfers

    /// @dev    Internal function that attempts to transfer coins from the message sender to this contract.
    ///         Reverts with a CoinTransferFailed error if the transfer fails.
    /// @param  coins The number of coin units to transfer.
    function _coinsFromSender(uint256 coins) internal {
        if (!_transferCoinsFrom(_msgSender(), address(this), coins)) revert CoinTransferFailed(coins);
    }

    /// @dev    Internal function to transfer coins using the ERC20 transferFrom method.
    /// @param  from The address to transfer coins from.
    /// @param  to The address to transfer coins to.
    /// @param  coins The number of coin units to transfer.
    /// @return success True if the transfer was successful.
    function _transferCoinsFrom(address from, address to, uint256 coins) internal returns(bool success) {
        try _coins.transferFrom(from, to, coins) returns (bool _success) {
            success = _success;
        } catch { }
    }

    // Receive and Withdraw

    /// @notice Accepts native Ether payments.
    /// @dev    When Ether is sent directly to this contract, it is credited to the
    ///         contract’s own pending distribution bucket (`_distributions[address(this)]`).
    receive() external payable {
        _addValue(msg.value);
    }

    /// @dev Checkpoints collector-yield for `account` using the supplied eligible
    ///      Digil balance, then restarts the account's yield timer.
    ///
    ///      This helper is used in two contexts:
    ///      - During {_update}, it is called before the ERC721 balance changes, so
    ///        `balance` is the account's pre-transfer balance.
    ///      - During {withdraw}, it is called with the sender's current balance.
    ///
    ///      Only accounts with a nonzero eligible Digil balance accrue collector-yield.
    ///      A zero-balance account may still have its timer reset, but it does not earn
    ///      the base `_coinRate` bonus.
    ///
    ///      If `welcome` is true and this is a first-time zero-balance recipient,
    ///      the account receives the one-coin welcome credit before its timer is
    ///      initialized.
    ///
    ///      Partial intervals are intentionally discarded on every checkpoint. This
    ///      keeps the invariant simple: an elapsed yield timer only applies to the
    ///      balance supplied for that checkpoint.
    ///
    /// @param account The account to checkpoint. Must not be address(0).
    /// @param balance The eligible Digil balance for the period being settled.
    /// @param welcome True only when checkpointing a transfer/mint recipient.
    function _checkpointYield(address account, uint256 balance, bool welcome) internal {
        Distribution storage d = _distributions[account];

        uint256 nowTs = block.timestamp;
        uint256 oldTime = d.time;

        if (oldTime == 0) {
            if (welcome && balance == 0) {
                d.coins += _coinMultiplier;
            }
            d.time = nowTs;
            return;
        }

        unchecked {
            uint256 intervals = (nowTs - oldTime) / BONUS_INTERVAL;

            if (intervals != 0 && balance != 0) {
                uint256 checkpointCap = _coinRate + (balance * _coinMultiplier / YIELD_PERIOD);
                uint256 bonus = intervals * checkpointCap / BONUS_RATE_DIVISOR;

                d.coins += bonus < checkpointCap ? bonus : checkpointCap;
            }
        }

        d.time = nowTs;
    }

    /// @notice Withdraws pending native-value and Coin distributions for the sender.
    /// @dev    ETH and Coin withdrawals are handled through the same user-facing
    ///         function, but with different participation rules.
    ///
    ///         ETH path:
    ///         - Pending native value is always withdrawable, even if the account
    ///           has opted out.
    ///         - The ETH amount is zeroed before the external call.
    ///
    ///         Coin path:
    ///         - Opted-out accounts cannot withdraw Coins.
    ///         - For non-opted-out accounts, this function first checkpoints
    ///           collector-yield using the sender's current unchanged-balance period.
    ///         - Then it attempts to pay all pending Coins.
    ///
    ///         Collector-yield:
    ///         - Calling {withdraw} is itself a checkpoint. If fewer than
    ///           `BONUS_INTERVAL` seconds have elapsed since the previous checkpoint,
    ///           no collector-yield is credited and that partial interval is
    ///           discarded because the timer is reset at checkpoint time.
    ///         - For each full `BONUS_INTERVAL`, the account accrues 1% of its
    ///           checkpoint cap (`_coinRate + balance * _coinMultiplier / YIELD_PERIOD`).
    ///         - Accrual saturates at the checkpoint cap for that checkpoint.
    ///         - `_checkpointYield` always resets the timer to `block.timestamp`,
    ///           even when no bonus is accrued (including zero-balance checkpoints).
    ///         - Yield is checkpoint-based (transfer/withdraw), preventing old elapsed
    ///           time from being retroactively applied to a newly increased balance.
    ///
    ///         Coin payout behavior:
    ///         - If the contract does not hold enough Coins, it attempts to mint the
    ///           shortfall.
    ///         - If minting or transfer fails, the Coin withdrawal fails softly:
    ///             * pending Coins are restored;
    ///             * the function still succeeds for the ETH path;
    ///             * returned `coins` is 0.
    ///         - This preserves the existing best-effort Coin payout model.
    ///
    /// @return coins The number of Coin units successfully transferred to the sender.
    /// @return value The native ETH value transferred to the sender.
    function withdraw() external nonReentrant returns (uint256 coins, uint256 value) {
        address addr = _msgSender();
        bool optedOut = _blacklisted[addr];

        Distribution storage distribution = _distributions[addr];

        // --- ETH accounting path ---
        //
        // ETH is always withdrawable, even by opted-out accounts.
        // Zero it before the external call to prevent re-withdrawal.
        value = distribution.value;
        distribution.value = 0;

        // --- Coin + collector-yield accounting path ---
        //
        // Snapshot and clear Coin state before performing the ETH external call.
        // This prevents a receiver hook from changing NFT balances mid-withdraw
        // and affecting the current Coin calculation.
        if (!optedOut) {
            _checkpointYield(addr, balanceOf(addr), false);

            coins = distribution.coins;
            distribution.coins = 0;
        }

        // --- ETH interaction ---
        //
        // Perform the ETH transfer after all local accounting has been snapshotted.
        if (value > 0) {
            (bool ok, ) = payable(addr).call{value: value}("");
            if (!ok) revert();
        }

        // Opted-out accounts cannot receive Coins or collector-yield.
        if (optedOut) {
            return (0, value);
        }

        // Nothing to pay in Coins.
        if (coins == 0) {
            return (0, value);
        }

        // Ensure this contract has enough Coins. If not, try to mint the shortfall.
        uint256 contractBalance = _coins.balanceOf(address(this));
        if (contractBalance < coins) {
            uint256 needed = coins - contractBalance;

            // Best-effort mint; failure is tolerated so the ETH path can still
            // succeed. If minting fails and the later transfer fails, pending Coins
            // are restored below.
            try _coins.mint(address(this), needed) {
                // Mint succeeded.
            } catch {
                // Mint failed; continue to attempt transfer with available balance.
            }
        }

        // Attempt to transfer Coins.
        //
        // This uses the existing `_transferCoinsFrom` helper so behavior remains
        // consistent with the rest of the contract.
        if (!_transferCoinsFrom(address(this), addr, coins)) {
            // Restore the snapshotted Coin amount without overwriting any Coins that
            // may have been credited to this account during the ETH receiver callback.
            unchecked {
                distribution.coins += coins;
            }
            coins = 0;
        }

        return (coins, value);
    }

    // Add Value and Distributions

    /// @dev    Reverts with {InsufficientFunds} using the caller-provided required amount.
    /// @param  required The exact native-value amount expected for the operation (in wei).
    function _revertInsufficientFunds(uint256 required) private pure {
        revert InsufficientFunds(required);
    }

    /// @dev    Internal helper that adds native value to the contract’s own pending distribution bucket.
    /// @param  value The amount of Ether (in wei) to add.
    function _addValue(uint256 value) internal {
        _addValue(address(this), value, 0);
    }

    /// @dev    Internal function to add native value and coins to a given address's pending distribution.
    /// @param  addr The address to credit the distribution.
    /// @param  value The amount of native value (in wei) to add.
    /// @param  coins The number of coin units to add.
    function _addValue(address addr, uint256 value, uint256 coins) internal {
        if (value > 0 || coins > 0) {
            Distribution storage distribution = _distributions[addr];
            unchecked {
                distribution.value += value;
                distribution.coins += coins;
            }
        }
    }

    /// @dev    Internal function that calculates and assigns distribution amounts between the contract and a specified address.
    ///         It correctly calculates fees based on the entire value provided, preventing precision loss from integer division.
    ///         Adds a percentage of the value to be distributed to the contract, and the rest to the address specified.
    ///         Adds a number of bonus coins based on the value to be distributed to "reward" the contributor for contributing value to the contract.
    ////         Example:
    ///             If `_incrementalValue = 0.0001 ETH`, `_transferValue = 0.000095 ETH`,
    ///             `_coinRate = 100 * _coinMultiplier`, and `value = 1 ETH`, then:
    ///             - 5% (0.05 ETH) is added to the contract's distribution.
    ///             - 95% (0.95 ETH) is added to `addr`'s distribution.
    ///             - `value / _incrementalValue = 10,000` full increments are counted,
    ///               so `10,000 * (_coinRate / BONUS_RATE_DIVISOR)` coin units are
    ///               credited to `addr`.
    /// @param  addr The address to credit the distribution.
    /// @param  value The amount of native value (in wei) to add.
    function _addDistributedValue(address addr, uint256 value) internal {
        uint256 contractFee;
        uint256 userValue;
        uint256 bonusCoins;

        unchecked {

            // 1. Calculate the contract's fee based on the total value.
            // We multiply first to maintain precision before dividing.
            // This correctly calculates the fee even if `value` is less than `_incrementalValue`.
            // Formula: fee = value * ((_incrementalValue - _transferValue) / _incrementalValue)
            contractFee = (value * (_incrementalValue - _transferValue)) / _incrementalValue;

            // 2. Calculate the value that goes to the user.
            // This is simply the original value minus the fee we just calculated.
            userValue = value - contractFee;

            // 3. Calculate bonus coins based on full `_incrementalValue` steps in the original `value`.
            // Only complete increments earn rewards; partial increments are ignored by design.
            bonusCoins = (_coinRate / BONUS_RATE_DIVISOR) * (value / _incrementalValue);

        }
        
        // 4. Add the calculated amounts to their respective distributions.
        // The contract gets its fee.
        _addValue(contractFee);

        // The user gets the remaining value and any bonus coins.
        _addValue(addr, userValue, bonusCoins);
    }

    /// @dev    Internal function that adds value to a token.
    /// @param  tokenId The token to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function _createValue(uint256 tokenId, uint256 value) internal {
        if (value > 0) {
            unchecked {
                _tokens[tokenId].value += value;
            }
            emit Enrich(tokenId, value);
        }
    }

    /// @notice Creates Value for a Token using the contract's available balance.
    /// @dev    Requires that the contract has enough value; deducts the amount from the contract distribution.
    /// @param  tokenId The token ID to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function createValue(uint256 tokenId, uint256 value) external payable onlyOwner {
        _checkTokenExists(tokenId);
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        _requireNoBatch(t);

        _addValue(msg.value);

        // Ensure the contract has sufficient available value.
        if (_distributions[address(this)].value < value) _revertInsufficientFunds(value);

        _distributions[address(this)].value -= value;

        _createValue(tokenId, value);

        // Update last activity
        t.lastActivity = block.timestamp;
    }

    // ERC721 Updates

    /// @inheritdoc ERC721
    /// @dev    Overrides the ERC721 {_update} function to perform Digil-specific
    ///         transfer accounting and policy checks.
    ///
    ///         Responsibilities:
    ///         1. Enforce opt-out restrictions for the caller and recipient.
    ///         2. Enforce planar-token custody rules.
    ///         3. Prevent transfers while a token-level batch operation is active.
    ///         4. Checkpoint collector-yield for sender and recipient before the
    ///            ERC721 balance change occurs.
    ///         5. Maintain first-time holder welcome-coin behavior.
    ///         6. Update token activity and automatically whitelist the new owner.
    ///
    ///         Collector-yield checkpointing:
    ///         - Yield must be settled before balances change.
    ///         - Non-opted-out senders earn yield on their old balance before losing
    ///           the token.
    ///         - Recipients earn yield on their old balance before receiving the token.
    ///         - Opted-out previous owners do not accrue collector-yield during the
    ///           transfer checkpoint.
    ///         - After checkpointing, both accounts' timers restart from now.
    ///         - This prevents temporary NFT concentration immediately before
    ///           {withdraw}.
    ///
    ///         Planar token policy:
    ///         - Planar tokens cannot be freely moved.
    ///         - Outside the temporary ownership-transfer window, planar tokens must
    ///           remain with the current contract owner.
    ///         - During {transferOwnership}, `_planarTransferActive` allows the old
    ///           owner to transfer planar custody to the new owner.
    ///
    /// @param  to      The address receiving the token.
    /// @param  tokenId The token ID being minted, transferred, or burned.
    /// @param  auth    The authorization address passed through to OpenZeppelin ERC721.
    /// @return from    The previous owner address.
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        _notOnBlacklist(_msgSender());
        _notOnBlacklist(to);

        Token storage t = _tokens[tokenId];
        address prev = _ownerOf(tokenId);

        if (prev != address(0)) {
            _requireNoBatch(t);

            if (tokenId <= PLANAR_TRANSFER_MAX_ID && !_planarTransferActive) {
                require(to == owner(), "DIGIL: Planar Locked to Owner");
            }

            // If you keep the current "approved operators may act for opted-out owners"
            // policy, skip yield accrual for opted-out owners.
            if (!_blacklisted[prev]) {
                _checkpointYield(prev, balanceOf(prev), false);
            }
        }

        if (to != address(0)) {
            // Recipient is already known not blacklisted from _notOnBlacklist(to).
            // Called before super._update, so balanceOf(to) is the old balance.
            _checkpointYield(to, balanceOf(to), true);
        }

        address from = super._update(to, tokenId, auth);

        t.lastActivity = block.timestamp;
        // Auto-whitelist the current owner address for future restricted charging.
        t.contributions[to].whitelisted = true;

        return from;
    }

    /// @dev    Internal function that ensures the caller is approved to operate on the token.
    /// @param  tokenId The token ID for which approval is required.
    function _checkApproved(uint256 tokenId) internal view {
        address account = _msgSender();
        _notOnBlacklist(account);
        require(_isAuthorized(ownerOf(tokenId), account, tokenId), "DIGIL: Not Approved");
    }

    /// @dev    Internal function to ensure an account is not blacklisted.
    /// @param  account The address to check.
    function _notOnBlacklist(address account) internal view {
        require(!_blacklisted[account], "DIGIL: Opted Out");
    }

    // Opt In / Opt Out

    /// @notice Allows the sender to opt out or opt in to Digil participation.
    ///         Requires sending a value equal to the current incremental value at the coin rate.
    ///         For example, at 0.0001 ETH incremental value and 100 coin rate, this requires 0.01 ETH.
    /// @dev    This function only toggles the account's blacklist status and routes the paid ETH
    ///         into the protocol value pool via {_addValue}. It does not reset or modify any
    ///         pending distribution timestamps or Coin bonus accrual checkpoints.
    ///         While opted out, the account cannot directly transfer Digils, receive Digils,
    ///         charge tokens, be attributed as a contributor, or withdraw Coin distributions.
    ///         Opting out does not revoke ERC-721 approvals. A non-opted-out approved operator
    ///         may still operate Digils owned by the opted-out account unless approvals are
    ///         revoked before opting out.
    /// @param  optOut True to opt out, false to opt back in.
    function setOptStatus(bool optOut) external payable {
        address account = _msgSender();
        require(_blacklisted[account] != optOut, "DIGIL: No Change");
        require(account != owner(), "DIGIL: Owner Cannot Opt Out");

        // Calculate required minimum funds for opting in/out.
        // This ties the opt decision to the current economic scale of the system.
        uint256 required = _incrementalValue * _coinRate / _coinMultiplier;        
        if (msg.value != required) _revertInsufficientFunds(required);
        
        // Add the sent value to the contract’s distribution (not to any specific token).
        _addValue(required);

        // Update the accounts blacklist status.
        _blacklisted[account] = optOut;

        emit OptStatus(account, optOut);
    }

    /// @notice Allows a contributor to reclaim their own unprocessed contribution
    ///         from an inactive token after a period of inactivity, in exchange
    ///         for paying a penalty into the system.
    /// @dev    This is a non-custodial escape hatch for contributors:
    ///
    ///         Eligibility:
    ///         - The token must be inactive (`active == false`) and not in the middle
    ///           of an activation or discharge batch (`distributionIndex == 0`).
    ///         - A minimum inactivity window must have passed since the token’s last
    ///           meaningful activity (`block.timestamp >= lastActivity + INACTIVITY_PERIOD`).
    ///         - The caller must have a recorded contribution (`c.value > 0` or
    ///           `c.charge > 0`) in the current contribution epoch.
    ///
    ///         Penalty:
    ///         - The caller must send one unit of "penalty" value:
    ///               required = max(token.incrementalValue, _incrementalValue)
    ///           If `msg.value` is not exactly this value, the call reverts with
    ///           {InsufficientFunds}.
    ///         - The penalty is added to the protocol’s value pool via {_addValue}
    ///           and is not returned to the contributor.
    ///
    ///         Effects:
    ///         - The contributor’s recorded `charge` (if any) is subtracted from
    ///           the token’s `charge` (clamped at zero to avoid underflow).
    ///         - The contributor’s recorded `value` is removed from their
    ///           per-token contribution state and returned to them via the
    ///           distribution system:
    ///             * `value` is credited to `_distributions[caller].value` using
    ///               {_addValue}, to be withdrawn later via {withdraw}.
    ///         - The per-contributor record for the current epoch is cleared:
    ///             * `c.value`, `c.charge`, and `c.discharge` are zeroed.
    ///           The contributor remains logically present only via the current epoch record,
    ///           and cannot reclaim the same contribution twice because the value/charge are removed.
    ///
    ///         Scope:
    ///         - This function never moves the token itself and never touches any
    ///           other contributor’s stake. It only allows the caller to reclaim
    ///           their own locked contribution after prolonged inactivity of the token,
    ///           at the cost of paying a penalty back into the system.
    ///
    /// @param  tokenId The token ID from which the caller is reclaiming their contribution.
    function reclaimContribution(uint256 tokenId) external payable {
        _checkTokenExists(tokenId);

        address addr = _msgSender();
        Token storage t = _tokens[tokenId];

        // Token must be inactive and not mid-batch.
        require(!t.active, "DIGIL: Cannot Reclaim On Active Token");
        _requireNoBatch(t);

        // Enforce inactivity window before contributors can reclaim their contribution.
        require(block.timestamp >= t.lastActivity + INACTIVITY_PERIOD, "DIGIL: Token Cannot Be Reclaimed");

        // Penalty: require one incremental unit of ETH.
        // Use the greater of the token's incrementalValue or the global minimum
        uint256 required = _max(t.incrementalValue, _incrementalValue);
        if (msg.value != required) _revertInsufficientFunds(required);

        // Route the penalty into the system’s value pool.
        _addValue(required);

        TokenContribution storage c = t.contributions[addr];
        _touchContribution(t, c);

        uint256 value = c.value;
        uint256 charge = c.charge;
        require(value > 0 || charge > 0, "DIGIL: No Contribution");

        if (charge > 0) {
            if (t.charge >= charge) {
                t.charge -= charge;
            } else {
                t.charge = 0;
            }
        }

        // NOTE: We intentionally do NOT update lastActivity here.
        //       Once a token has become reclaimable (after INACTIVITY_PERIOD
        //       of inactivity), multiple contributors should be able to
        //       reclaim in the same window until the owner performs a
        //       new, meaningful operation on the token.

        // Clear this epoch’s contribution record
        c.value = 0;
        c.charge = 0;
        c.discharge = 0;

        emit Reclaim(addr, tokenId, value);

        // Refund their recorded contribution through the normal distribution pipeline.
        _addValue(addr, value, 0);
    }

    // ERC721 Receiver

    /// @inheritdoc IERC721Receiver
    /// @dev Records a pending vault deposit for
    ///      (`msg.sender` = external contract, `tokenId` = external tokenId)
    ///      when this contract receives an NFT via `safeTransferFrom`.
    ///      Direct ERC721 safe-mint-to-vault is intentionally unsupported and rejected,
    ///      because minted callbacks use `from == address(0)` and do not represent a
    ///      depositor who can later finalize or cancel the pending vault.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external nonReentrant returns (bytes4) {
        address account = _msgSender();
        
        // Ensure the token isn't already fully vaulted or pending by someone else
        require(_contractTokenAddresses[account][tokenId] == address(0), "DIGIL: Token Already Vaulted"); 
        
         // Reject direct mint-to-vault deposits; only safeTransferFrom deposits are supported.
        require(from != address(0), "DIGIL: Mint-To-Contract Unsupported");

        // Securely record the user as the pending depositor
        _contractTokenAddresses[account][tokenId] = from;
        
        return this.onERC721Received.selector;
    }

    /// @notice Finalizes a pending external ERC721 vault deposit by minting a new Digil wrapper.
    /// @dev
    ///  Vault lifecycle:
    ///  1) User deposits an external ERC721 via `safeTransferFrom(..., address(this), externalTokenId, ...)`.
    ///     Direct safe-mint to this contract is not supported.
    ///     The ERC721 callback {onERC721Received} records the depositor as:
    ///         _contractTokenAddresses[account][externalTokenId] = depositor
    ///     This is the "Pending Vault" state.
    ///
    ///  2) The depositor calls this function to finalize the vault:
    ///     - Requires the caller is the recorded depositor.
    ///     - Requires the caller is not opted out (blacklisted).
    ///     - Charges a Coin vault fee (`vaultFee = _coinRate * 10`) from the caller.
    ///     - Marks the external token as fully vaulted:
    ///         _contractTokenAddresses[account][externalTokenId] = address(this)
    ///     - Mints a new Digil to the caller and attaches provenance:
    ///         _contractTokens[account][digilTokenId].tokenId = externalTokenId
    ///         _tokens[digilTokenId].contractTokenAddress    = account
    ///     - The wrapper is created with `activationThreshold = 0`.
    ///     - Updates the Digil URI with a `?ct=1` marker for front-end discovery.
    ///     - Populates the reverse index:
    ///         _vaultedTokenIds[account][externalTokenId] = digilTokenId
    ///
    ///  Canceling:
    ///  - Cancel is no longer performed here. A depositor cancels a pending vault by calling
    ///    {recallToken(account, externalTokenId)} while the token is still in the "Pending Vault"
    ///    state (i.e. `_contractTokenAddresses[account][externalTokenId] == depositor`).
    ///
    ///  Reverts if:
    ///  - The caller is not the recorded depositor.
    ///  - The caller is opted out (blacklisted).
    ///  - The external token is not currently held by this contract.
    ///  - The Coin vault fee cannot be collected.
    ///
    ///  Note:
    ///  - Because the wrapper is created with a zero activation threshold, it can satisfy
    ///    the normal activation threshold check without requiring additional inactive charge.
    ///    Any later recallability is governed by the attachment's stored `recallable` flag,
    ///    which is updated during distribution processing elsewhere in the lifecycle.
    ///
    /// @param  account The external ERC721 contract address.
    /// @param  externalTokenId The external ERC721 tokenId being vaulted.
    /// @param  data    Optional data to store with the newly minted Digil token.
    function vaultToken(address account, uint256 externalTokenId, bytes calldata data) external nonReentrant {
        address user = _msgSender();

        // Cache nested mapping to reduce repeated keccak(base) work.
        mapping(uint256 => address) storage vaulters = _contractTokenAddresses[account];

        // Authenticate the caller as the recorded pending depositor
        require(vaulters[externalTokenId] == user, "DIGIL: Not The Depositor");

        _notOnBlacklist(user);

        // Transfer rights to the contract (mark as permanently vaulted)
        vaulters[externalTokenId] = address(this);

        uint256 vaultFee = _coinRate * 10;
        if (!_transferCoinsFrom(user, address(this), vaultFee)) revert CoinTransferFailed(vaultFee);

        require(IERC721(account).ownerOf(externalTokenId) == address(this), "DIGIL: Contract Token Not Received");

        uint256 tokenId = _createToken(user, _incrementalValue, 0, data);   
        _contractTokens[account][tokenId].tokenId = externalTokenId;
        // Reverse index used by recall lookup.
        _vaultedTokenIds[account][externalTokenId] = tokenId;

        Token storage t = _tokens[tokenId];
        t.uri = string(abi.encodePacked(tokenURI(tokenId), "?ct=1"));
        t.contractTokenAddress = account;
    }

    /// @notice Cancels a pending external ERC721 vault deposit or recalls a vaulted external ERC721 from its Digil.
    /// @dev Unified exit for external NFTs held by this contract:
    ///
    ///  State detection:
    ///  - `holder = _contractTokenAddresses[account][externalTokenId]`
    ///  - `holder == address(0)`      => not in vault (revert)
    ///  - `holder != address(this)`   => pending deposit (cancel)
    ///  - `holder == address(this)`   => fully vaulted + attached to a Digil (recall)
    ///
    ///  Case 1: Pending deposit (Cancel)
    ///  - Preconditions:
    ///      * `holder == msg.sender` (only the recorded depositor may cancel)
    ///  - Effects:
    ///      * Clears `_contractTokenAddresses[account][externalTokenId]` to `address(0)`
    ///      * Clears `_vaultedTokenIds[account][externalTokenId]` to `0` (defensive / no-op if unset)
    ///  - Interaction:
    ///      * Transfers the external ERC721 back to the depositor:
    ///          IERC721(account).safeTransferFrom(address(this), msg.sender, externalTokenId)
    ///  - Note: No blacklist check is applied so users can always cancel and recover a pending deposit.
    ///
    ///  Case 2: Fully vaulted (Recall)
    ///  - Resolves the wrapping Digil:
    ///      * `digilTokenId = _vaultedTokenIds[account][externalTokenId]` (must be non-zero)
    ///  - Preconditions:
    ///      * Caller must be approved for `digilTokenId` via {_checkApproved}
    ///      * Token must not be mid-batch via {_requireNoBatch}
    ///      * `account == _tokens[digilTokenId].contractTokenAddress`
    ///      * `_contractTokens[account][digilTokenId].tokenId == externalTokenId`
    ///      * `_contractTokens[account][digilTokenId].recallable == true`
    ///  - Recallability semantics:
    ///      * Recallability is not derived directly inside this function.
    ///      * It is a stored attachment flag that is updated during the token's
    ///        activation/distribution/discharge lifecycle.
    ///      * This function only enforces the current stored value.
    ///  - Effects (performed before the external call):
    ///      * Clears `recallable` for this Digil’s attachment
    ///      * Clears `_contractTokenAddresses[account][externalTokenId]` to `address(0)` (unvault)
    ///      * Clears `_vaultedTokenIds[account][externalTokenId]` to `0`
    ///      * Applies thematic bleed to the Digil via {_applyActiveChargeBleed}
    ///      * Leaves provenance (`contractTokenAddress`, `externalTokenId`) intact on the Digil for {tokenAttachment}
    ///  - Interaction:
    ///      * Transfers the external ERC721 back to the current Digil owner:
    ///          IERC721(account).safeTransferFrom(address(this), ownerOf(digilTokenId), externalTokenId, t.data)
    ///
    /// @param  account          The external ERC721 contract address.
    /// @param  externalTokenId  The external ERC721 tokenId to cancel/recall.
    function recallToken(address account, uint256 externalTokenId) external nonReentrant {
        address caller = _msgSender();

        // Cache nested mappings to avoid repeated keccak(base) work.
        mapping(uint256 => address) storage vaulters = _contractTokenAddresses[account];
        mapping(uint256 => uint256) storage internalTokens = _vaultedTokenIds[account];

        address addr = vaulters[externalTokenId];
        require(addr != address(0), "DIGIL: Token Not In Vault");

        // --- Case 1: Pending deposit (cancel) ---
        if (addr != address(this)) {
            require(addr == caller, "DIGIL: Not The Depositor");

            // effects
            vaulters[externalTokenId] = address(0);
            // Defensive: clear reverse index if set (no-op for pure pending deposits)
            internalTokens[externalTokenId] = 0;

            // interaction
            IERC721(account).safeTransferFrom(address(this), caller, externalTokenId);
            return;
        }

        // --- Case 2: Fully vaulted / attached to a Digil (recall) ---
        uint256 tokenId = internalTokens[externalTokenId];
        require(tokenId != 0, "DIGIL: No Digil For Token");

        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];

        _requireNoBatch(t);

        // Safety check: enforce that the supplied account matches the attached contract.
        require(account == t.contractTokenAddress, "DIGIL: Invalid Contract Account");

        mapping(uint256 => ContractToken) storage cts = _contractTokens[account];
        ContractToken storage contractToken = cts[tokenId];

        uint256 contractTokenId = contractToken.tokenId;
        require(contractTokenId == externalTokenId, "DIGIL: Wrong External Token");
        require(contractToken.recallable, "DIGIL: Contract Token Is Not Recallable");

        // --- Effects: clear all "attached contract" state first ---
        contractToken.recallable = false;
        vaulters[contractTokenId] = address(0);
        internalTokens[contractTokenId] = 0;
        // DO NOT clear contractToken.tokenId or t.contractTokenAddress.
        // They serve as immutable provenance metadata for this Digil.
        //contractToken.tokenId = 0;
        //t.contractTokenAddress = address(0);

        address owner = ownerOf(tokenId);

        // Thematic bleed: lose 1 / AFFINITY_REDUCTION of activeCharge when recalled.
        _applyActiveChargeBleed(t);

        // --- Interaction: external call happens after state updates ---
        // Safely transfer the external ERC721 token back to the current owner of the Digil token.
        IERC721(account).safeTransferFrom(address(this), owner, contractTokenId, t.data);
    }

    // Token Information

    /// @dev    Internal function to ensure a token exists.
    /// @param  tokenId The token ID to check.
    function _checkTokenExists(uint256 tokenId) internal view {
        require(tokenId < _nextTokenId, "DIGIL: Token Does Not Exist");
    }

    /// @inheritdoc ERC721
    /// @dev    Returns the base URI used by the ERC721 token.
    /// @return The base URI string.
    function _baseURI() internal view override returns (string memory) {
        // Use first token's URI as base
        return _tokens[0].uri;
    }

    /// @notice Retrieves the URI for a given token.
    /// @dev    If the token URI is explicitly set, it is returned; otherwise, the default ERC721 token URI is returned.
    /// @param  tokenId The token ID to retrieve the URI for.
    /// @return The token URI string.
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        // If the token does not exist, _tokens[tokenId].uri returns an empty string.
        // The code then falls through to super.tokenURI(tokenId).
        // OpenZeppelin's ERC721.tokenURI already reverts if the token does not exist.
        //_checkTokenExists(tokenId);

        string storage uri = _tokens[tokenId].uri;

        if (bytes(uri).length > 0) {
            return string(abi.encodePacked(uri));
        }

        return super.tokenURI(tokenId);
    }

    /// @notice Retrieves charge and value related information for a token.
    /// @dev    The value and charged value can be added together to give the token's total value.
    ///         The charged value is derived from the token's charge and incremental value (charge (decimals excluded) * incremental value)
    /// @param  tokenId The token ID to query.
    /// @return charge The total accumulated charge.
    /// @return activeCharge The charge generated from linked activity.
    /// @return value The current token value (in wei).
    /// @return incrementalValue The incremental value for charging.
    /// @return activationThreshold The threshold required to activate the token.
    function tokenCharge(uint256 tokenId) external view returns(uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId]; 
        return (t.charge, t.activeCharge, t.value, t.incrementalValue, t.activationThreshold);
    }

    /// @notice Retrieves status and additional data for a token.
    /// @param  tokenId The token ID to query.
    /// @return active Whether the token is active.
    /// @return activating Whether the token is being activated.
    /// @return discharging Whether the token is being discharged.
    /// @return restricted Whether the token is restricted.
    /// @return links The number of links associated with the token.
    /// @return contributors The number of contributor addresses.
    /// @return contributionEpoch The logical epoch for contributions on this token.
    /// @return distributionIndex The current distribution index.
    /// @return data Arbitrary data stored with the token.
    function tokenData(uint256 tokenId) external view returns(bool active, bool activating, bool discharging, bool restricted, uint256 links, uint256 contributors, uint256 contributionEpoch, uint256 distributionIndex, bytes memory data) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];

        return (t.active, t.activating, t.discharging, t.restricted, t.links.length, t.contributors.length, t.contributionEpoch, t.distributionIndex, t.data);
    }

    /// @notice Retrieves buff and appearance information for a token.
    /// @dev    The buff is considered active iff `block.timestamp < expiresAt`.
    ///         `appearance` is stored in `BuffState.appearance` as persistent rendering metadata
    ///         and is intentionally preserved across full discharges (see {dischargeToken}),
    ///         even though the temporary buff fields themselves are cleared.
    /// @return expiresAt        Unix timestamp when the current temporary buff expires (0 if inactive/never set).
    /// @return efficiencyBonus  Temporary bonus added to outgoing link base efficiency while buff is active.
    /// @return attunement       Planar ID mimicked for affinity while buff is active (1–17, or 0 for none).
    /// @return amplification    Incoming active-charge multiplier percent (e.g., 20 => +20%; 100 => +100%).
    /// @return flags            Bitmask of STABILIZED/ANCHORED/PRIMED/REVERBERATED plus tier tags.
    /// @return appearance       Packed appearance payload (style/cosmetics/colors).
    function tokenBuff(uint256 tokenId) external view returns (uint40 expiresAt, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance) {
        _checkTokenExists(tokenId);
        BuffState storage b = _tokens[tokenId].buff;
        return (b.expiresAt, b.efficiencyBonus, b.attunement, b.amplification, b.flags, b.appearance);
    }

    /// @notice Retrieves contribution details for a specific address on a given token.
    /// @dev    Returns the raw contribution state as currently stored, without mutating it.
    ///         The returned `epoch` can be compared against the token's current
    ///         `contributionEpoch` to determine whether this contribution is from the
    ///         current logical epoch or from a previous one that has been logically reset.
    ///         Note that this function does not call `_touchContribution`, so the values
    ///         may represent pre-reset state until a write operation occurs for that contributor.
    /// @param  tokenId The ID of the token to query.
    /// @param  contributor The address whose contribution details are being requested.
    /// @return charge The amount of coin units this address has contributed to the token's charge, including affinity bonuses.
    /// @return discharge The amount of coin units this address has contributed to the token's charge, excluding affinity bonuses.
    /// @return value The amount of native value (in wei) attributed to this contributor on this token.
    /// @return exists True if a contribution record currently exists for this contributor.
    /// @return whitelisted True if this contributor is whitelisted for this token (relevant when the token is restricted).
    /// @return epoch The logical contribution epoch this record belongs to.
    function tokenContribution(uint256 tokenId, address contributor) external view returns (uint256 charge, uint256 discharge, uint256 value, bool exists, bool whitelisted, uint256 epoch) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];
        TokenContribution storage c = t.contributions[contributor];
        return (c.charge, c.discharge, c.value, c.exists, c.whitelisted, c.epoch);
    }

    /// @notice Retrieves link information for a token at a specific index.
    /// @param  tokenId The ID of the source token whose link is being queried.
    /// @param  index The zero-based index into the token's `links` array.
    /// @return linkId The ID of the linked token (or plane) at the given index.
    /// @return baseEfficiency The stored base efficiency percentage for this link.
    /// @return affinityBonus The additional affinity-based efficiency for this link.
    function tokenLinkAt(uint256 tokenId, uint256 index) external view returns (uint256 linkId, uint8 baseEfficiency, uint256 affinityBonus) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];

        linkId = t.links[index];
        LinkEfficiency storage efficiency = t.linkEfficiency[linkId];

        baseEfficiency = efficiency.base;
        affinityBonus = efficiency.affinityBonus;

        return (linkId, baseEfficiency, affinityBonus);
    }

    /// @notice Returns lifecycle information about any external ERC721 token
    ///         that has been wrapped (vaulted) by this Digil.
    /// @dev
    ///  This view reports the attachment state for `tokenId` using:
    ///   - `_tokens[tokenId].contractTokenAddress` (which external ERC721 contract is associated),
    ///   - `_contractTokens[contractTokenAddress][tokenId]` (which external tokenId is associated + recallable flag),
    ///   - `_contractTokenAddresses[contractTokenAddress][externalTokenId]` (whether the external token is currently held here),
    ///   - `_vaultedTokenIds[contractTokenAddress][externalTokenId]` (reverse index: which Digil currently wraps it).
    ///
    ///  Note:
    ///  - `externalTokenId` may legitimately be 0 for ERC721 collections that use
    ///    token ID 0. The absence of provenance is indicated by
    ///    `contractTokenAddress == address(0)`, not by `externalTokenId == 0` alone.
    ///
    ///  Lifecycle states (as observed through this view):
    ///
    ///  1. Never wrapped / no provenance
    ///     - `contractTokenAddress == address(0)`
    ///     - `externalTokenId == 0`
    ///     - `recallable == false`
    ///     - `vaulted == false`
    ///     Interpretation: this Digil has never wrapped an external ERC721.
    ///
    ///  2. Wrapped historically, but not currently vaulted (recalled or otherwise unvaulted)
    ///     - `contractTokenAddress != address(0)`
    ///     - `externalTokenId` may be any value, including 0
    ///     - `_contractTokenAddresses[contractTokenAddress][externalTokenId] != address(this)`
    ///       ⇒ `vaulted == false`
    ///     - `recallable == false` (typically; may be stale only if state was never updated, but recall clears it)
    ///     Interpretation:
    ///       - {recallToken} has transferred the external ERC721 out of this contract (or it is otherwise
    ///         not held here), so the token is not currently vaulted.
    ///       - Provenance (`contractTokenAddress`, `externalTokenId`) is intentionally retained on the Digil
    ///         for historical/audit/indexing purposes.
    ///
    ///  3. Vaulted, not yet recallable
    ///     - `contractTokenAddress != address(0)`
    ///     - `_contractTokenAddresses[contractTokenAddress][externalTokenId] == address(this)`
    ///       ⇒ `vaulted == true`
    ///     - `recallable == false`
    ///     Interpretation:
    ///       - The external ERC721 is currently held (“vaulted”) by this contract under this Digil.
    ///       - Recallability has not yet been granted for this attachment (e.g., activation distribution
    ///         has not completed while active/activating).
    ///
    ///  4. Vaulted and recallable
    ///     - `contractTokenAddress != address(0)`
    ///     - `_contractTokenAddresses[contractTokenAddress][externalTokenId] == address(this)`
    ///       ⇒ `vaulted == true`
    ///     - `recallable == true`
    ///     Interpretation:
    ///       - The external ERC721 is still held by this contract and may be reclaimed by an approved
    ///         operator via {recallToken(contractTokenAddress, externalTokenId)}.
    ///
    ///  Invariants:
    ///  - `vaulted` is derived strictly from:
    ///        `_contractTokenAddresses[contractTokenAddress][externalTokenId] == address(this)`
    ///    i.e., whether this contract currently holds the external token.
    ///  - `recallable` is derived strictly from:
    ///        `_contractTokens[contractTokenAddress][tokenId].recallable`
    ///    and is typically:
    ///      * set true when a full activation distribution cycle completes while the Digil is active/activating
    ///        and the external token is still vaulted, and
    ///      * cleared by {recallToken} and by batch settlement paths that finalize while inactive.
    ///  - `_vaultedTokenIds` is a reverse index for *currently vaulted* external tokens:
    ///        `_vaultedTokenIds[contractTokenAddress][externalTokenId] == tokenId`
    ///    and is cleared by {recallToken}. This view does not rely on `_vaultedTokenIds` to compute `vaulted`,
    ///    but it should remain consistent for any fully vaulted token.
    ///
    /// @param  tokenId The internal Digil token ID being queried.
    /// @return contractTokenAddress The ERC721 contract address of the attached token (zero if none).
    /// @return externalTokenId      The external ERC721 tokenId attached to this Digil.
    ///                              Meaningful only when `contractTokenAddress != address(0)`;
    ///                              may legitimately be 0 for collections that use token ID 0.
    /// @return recallable           True if the attached token can currently be recalled via {recallToken}.
    /// @return vaulted              True if the external token is still held (“vaulted”) in this contract.
    function tokenAttachment(uint256 tokenId) external view	returns (address contractTokenAddress, uint256 externalTokenId,	bool recallable, bool vaulted) {
        _checkTokenExists(tokenId);

        Token storage t = _tokens[tokenId];
        contractTokenAddress = t.contractTokenAddress;

        // If contractTokenAddress is zero, this is just a default/empty mapping read.
        ContractToken storage ct = _contractTokens[contractTokenAddress][tokenId];
        externalTokenId = ct.tokenId;
        recallable      = ct.recallable;

        // If contractTokenAddress or externalTokenId is zero, this also just reads defaults.
        vaulted = _contractTokenAddresses[contractTokenAddress][externalTokenId] == address(this);
    }

    // Token Creation

    /// @dev    Internal function to create a new token.
    /// @param  creator The address that the token is being created for.
    /// @param  incrementalValue The incremental value associated with the token.
    /// @param  activationThreshold The activation threshold for the token.
    /// @param  data Optional data to store with the token.
    /// @return tokenId The newly created token ID.
    function _createToken(address creator, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data) internal returns(uint256) {      
        // Get current ID and increment
        uint256 tokenId = _nextTokenId++;
        
        // Mint the token to the creator.
        _mint(creator, tokenId);

        Token storage t = _tokens[tokenId];

        // Record initial last activity as "now" (creation event).
        t.lastActivity = block.timestamp;
        
        // Set the token parameters.
        t.incrementalValue = incrementalValue;
        t.activationThreshold = activationThreshold;

        // Persist any arbitrary data passed at creation time.
        t.data = data;

        return tokenId;
    }

    /// @notice Creates a new token.
    ///         The `plane` chosen here becomes the token's foundational planar identity
    ///         and is permanently attached for the lifetime of the token.
    ///         This foundational link:
    ///         - Is stored as the first entry in the token's `links` array.
    ///         - Is used to compute planar affinity bonuses when linking to other tokens.
    ///         - Cannot be removed or re-assigned later (see {unlinkToken} restrictions).
    ///
    ///         Linking to a plane other than the 4 elemental planes (4–7; fire, air, earth, water)
    ///         requires a Coin transfer at the current coin rate:
    ///             - Void / karmic / kaotic planes (1–3; void, karma, kaos): 5x coin rate
    ///             - Paraelemental planes (8–11; ice, lightning, metal, nature): 1x coin rate
    ///             - Energy planes (12–16; harmony, discord, entropy, exergy, magick): 25x coin rate
    ///             - Ethereal planes (17–18; aether, world): 100x coin rate
    ///
    /// @param  incrementalValue The incremental value (in wei) required with each coin used for charging.
    ///                          Must be 0 or at least the global minimum incremental value.
    ///                          Creation always requires at least the global floor (`_incrementalValue`).
    ///                          If `restricted == true` and this value is higher than the global floor,
    ///                          creation requires at least this higher value; otherwise unrestricted
    ///                          creation keeps the global floor minimum even when this value is higher.
    ///                          Token creation accepts excess ETH above the minimum required deposit;
    ///                          all supplied ETH is added to the token's intrinsic value.
    /// @param  activationThreshold The number of coins required for token activation.
    /// @param  restricted Whether the token is restricted to whitelisted addresses for charging.
    /// @param  plane The chosen user-alignable plane ID. This becomes the immutable foundational
    ///               plane for this token. Must be 0 (no plane) or in the user alignment range
    ///               [1 .. PLANAR_MAX_ID]. Foundational plane choice cannot be changed later.
    /// @param  data Optional arbitrary data to store with the token.
    /// @return tokenId The ID of the newly created token.
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes calldata data) external payable returns(uint256) {
        // 1. INPUT VALIDATION
        // Ensure if they set a value, it isn't below the global floor (unless it's 0).
        if (incrementalValue > 0 && incrementalValue < _incrementalValue) {
            // Use a short string or custom error to save bytes
            revert("DIGIL: Invalid Incremental Value");
        }

        // 2. CALCULATE DEPOSIT REQUIREMENT
        // Start with the Global Floor (Sybil Defense)
        uint256 required = _incrementalValue;

        // If Restricted, we must match the Token's Incremental Value if it is higher than the floor.
        // This preserves your original logic: max(incrementalValue, _incrementalValue)
        if (restricted && incrementalValue > required) {
            required = incrementalValue;
        }

        // 3. CHECK FUNDS
        if (msg.value < required) _revertInsufficientFunds(required);
        
        // 4. CREATE TOKEN & SET STATE
        uint256 tokenId = _createToken(_msgSender(), incrementalValue, activationThreshold, data);
        Token storage t = _tokens[tokenId];

        if (restricted) {
            t.restricted = true;
            emit Restrict(tokenId);
        }

        // 5. ACCRUE VALUE
        // We add the ENTIRE msg.value to the token. 
        _createValue(tokenId, msg.value);

        // If a plane is specified (plane > 0), process the coin fee and link the token to the plane.
        if (plane > 0) {
            require(plane <= PLANAR_MAX_ID, "DIGIL: Invalid Plane");

            // Different fee structures based on plane index, pricing rarer planes higher.
            uint256 tier;
            if (plane < 4) {
                // Void / karmic / kaotic planes (1–3): 5× coinRate
                tier = 5;
            } else if (plane > 16) {
                // Ethereal planes (17–18): 100× coinRate
                tier = 100;
            } else if (plane > 11) {
                // Energy planes (12–16): 25× coinRate
                tier =  25;
            } else if (plane > 7) {
                // Paraelemental planes (8–11): 1× coinRate
                tier = 1;
            }
            if (tier != 0) {
                _coinsFromSender(tier * _coinRate);
            }

            // Record the plane link as the immutable foundational plane (index 0 in links[]).
            t.links.push(plane);
            t.linkEfficiency[plane] = LinkEfficiency(100, 0);
            emit Link(tokenId, plane, 100, 0);
        }
        
        return tokenId;
    }

    /// @dev    Internal helper to enforce that no batch operation (activation or discharge)
    ///         is currently in progress for the given token.
    ///         Reverts with "DIGIL: Batch Operation In Progress" if `distributionIndex > 0`.
    /// @param  t The storage reference to the Token being checked.
    function _requireNoBatch(Token storage t) internal view {
        if (t.distributionIndex != 0) {
            revert("DIGIL: Batch Operation In Progress");
        }
    }

    /// @dev    Validates that the caller is authorized to operate `tokenId`,
    ///         requires that the token is not in an activation/discharge batch,
    ///         and records the current block timestamp as token activity.
    ///         
    ///         This helper combines the common precondition pattern used by
    ///         user-facing token operations:
    ///         - {_checkApproved}: caller must be the token owner, an approved
    ///           operator, or otherwise authorized under the planar-token policy.
    ///         - {_requireNoBatch}: token must not have a batch operation in
    ///           progress (`distributionIndex == 0`).
    ///         - activity touch: `lastActivity` is updated on successful validation.
    ///         
    ///         Reverts with:
    ///         - "DIGIL: Opted Out" if the caller is blacklisted.
    ///         - "DIGIL: Not Approved" if the caller is not authorized.
    ///         - "DIGIL: Batch Operation In Progress" if the token is mid-batch.
    ///         
    /// @param  tokenId The token ID being operated on.
    /// @param  t       Storage reference to the token being operated on.
    function _authorizeIdleAndTouch(uint256 tokenId, Token storage t) internal {
        _checkApproved(tokenId);
        _requireNoBatch(t);
        t.lastActivity = block.timestamp;
    }

    /// @notice Adds addresses to a token's whitelist.
    ///         Once an address has been whitelisted, it cannot be removed.
    ///         If no addresses are supplied, the token is switched to unrestricted mode
    ///         (if it was previously restricted). No addresses are ever removed from the
    ///         one-way whitelist mapping.
    ///         Requires a value sent greater than or equal to the larger of the token's incremental value or the minimum incremental value. 
    /// @param  tokenId The token ID to update.
    /// @param  whitelisted An array of addresses to whitelist.
    function restrictToken(uint256 tokenId, address[] memory whitelisted) external payable {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        _authorizeIdleAndTouch(tokenId, t);

        uint256 value = msg.value;

        // Determine if the token should be restricted based on provided addresses.
        bool restrict = whitelisted.length > 0;
        bool wasRestricted = t.restricted;
        if (restrict != wasRestricted) {
            t.restricted = restrict;
            if (restrict) {
                // Switching into restricted mode requires paying at least the higher
                // of token.incrementalValue or the global minimum.
                uint256 required = _max(t.incrementalValue, _incrementalValue);
                if (value < required) _revertInsufficientFunds(required);
                emit Restrict(tokenId);
            }
            // If restricting is being disabled, no additional payment is required.
        }

        // Add any sent Ether as token value (even if toggle did not change).
        _createValue(tokenId, value);
        
        // Loop through the provided addresses and whitelist them.
        mapping(address => TokenContribution) storage contributions = t.contributions;
        uint256 accountsLength = whitelisted.length;
        for (uint256 accountIndex; accountIndex < accountsLength; accountIndex++) {
            address account = whitelisted[accountIndex];
            // Whitelisting is a one-way operation: once set, it is never cleared.
            contributions[account].whitelisted = true;
            emit Whitelist(account, tokenId);
        }        
    }

    /// @notice Updates an existing Token. Caller must be approved for this Token.
    /// @dev    Batch safety:
    ///         - Reverts if a batch activation/discharge distribution is in progress
    ///           (`distributionIndex != 0`).
    ///
    ///         Economic parameter update restrictions:
    ///         - If the token currently has pending inactive `charge > 0`, then
    ///           `incrementalValue` and `activationThreshold` are frozen for this call
    ///           and must exactly match the stored values.
    ///         - If `charge == 0`, these values may be changed even if the token
    ///           was previously used in an earlier lifecycle.
    ///         - For planar tokens (IDs 0..PLANAR_TRANSFER_MAX_ID), `incrementalValue` and
    ///           `activationThreshold` must remain 0.
    ///
    ///         Incremental value rules:
    ///         - `incrementalValue` may be 0 (meaning “use global minimum where applicable”),
    ///           otherwise it must be >= `_incrementalValue`.
    ///
    ///         URI / Data update fees:
    ///         - Updating `uri` (non-empty string) charges `1000 * _coinRate` coins.
    ///         - Updating `data` (non-empty bytes) charges `1000 * _coinRate` coins.
    ///           If both are updated in the same call, both fees are charged.
    ///         - For planar tokens (IDs 0..PLANAR_TRANSFER_MAX_ID), `data` must have length
    ///           >= 5 to preserve planar affinity encoding.
    ///
    ///         ETH requirement:
    ///         - If neither `uri` nor `data` is updated (both empty), required ETH is exactly 0.
    ///         - If either `uri` or `data` is updated, the call must send exactly:
    ///               minimumValue = max(t.incrementalValue, incrementalValue, _incrementalValue)
    ///           The required ETH is routed into the protocol value pool via {_addValue}
    ///           rather than being stored directly on the token.
    ///
    ///         State updates:
    ///         - Updates `t.incrementalValue` and `t.activationThreshold` after validation.
    ///         - Overwrites `t.uri` only if `uri` is non-empty.
    ///         - Overwrites `t.data` only if `data` is non-empty.
    ///         - Updates `t.lastActivity` on success and emits {Update}.
    ///
    /// @param  tokenId The ID of the Token to update.
    /// @param  incrementalValue New incremental value (wei) required per `_coinMultiplier` of charge.
    ///                          Must be 0 or >= `_incrementalValue` (and must be 0 for planar tokens).
    /// @param  activationThreshold New activation threshold in coin units (must be 0 for planar tokens).
    /// @param  data New token data (applied only if `data.length > 0`).
    /// @param  uri New token URI (applied only if `bytes(uri).length > 0`).
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data, string calldata uri) external payable {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        _authorizeIdleAndTouch(tokenId, t);

        // If token already has charge, its incremental value and activation threshold cannot be modified.
        if (t.charge > 0) {
            require(t.incrementalValue == incrementalValue && t.activationThreshold == activationThreshold, "DIGIL: Cannot Update Charged Token");
        }

        if (tokenId <= PLANAR_TRANSFER_MAX_ID) {
            require(incrementalValue == 0, "DIGIL: Invalid Incremental Value");
            require(activationThreshold == 0, "DIGIL: Invalid Activation Threshold");
        }

        // Require minimum incremental value
        if (incrementalValue > 0) {
            require(incrementalValue >= _incrementalValue, "DIGIL: Invalid Incremental Value");
        }

        bool overwriteUri = bytes(uri).length > 0;
        if (overwriteUri) {
            // Updating the URI requires a coin fee to ensure token integrity.
            _coinsFromSender(_coinRate * 1000);
        }

        bool overwriteData = bytes(data).length > 0;
        if (overwriteData) {
            if (tokenId <= PLANAR_TRANSFER_MAX_ID) {
                // Planar tokens must preserve at least 5 bytes of data to keep affinity encoding valid.
                require(bytes(data).length >= 5, "DIGIL: Invalid Data Length");
            }
            // Updating data requires a coin fee to preserve the token's original intention.
            _coinsFromSender(_coinRate * 1000);
        }

        // Calculate the minimum required Ether value based on whether data or URI is updated.
        uint256 minimumValue = 0;
        if (overwriteData || overwriteUri) {
            // base = max(old, new, _incrementalValue)
            minimumValue = _max(t.incrementalValue, _max(incrementalValue, _incrementalValue));
        }
        if (msg.value != minimumValue) _revertInsufficientFunds(minimumValue);

        // Add any sent Ether to the contract's distribution (not directly to this token).
        _addValue(minimumValue);

        // Update token parameters.
        t.incrementalValue = incrementalValue;
        t.activationThreshold = activationThreshold;

        if (overwriteUri) {
            t.uri = uri;
        }

        if (overwriteData) {
            t.data = data;
        }

        emit Update(tokenId);
    }

    // Charging

    /// @dev    Computes the effective base efficiency for a given link, taking into account
    ///         any temporary buff applied via {buffToken}. If no buff is active or the buff
    ///         has expired, this returns the stored base efficiency.
    /// @param  linkId The destination token ID (or plane ID) for this link.
    /// @param  t The source token storage reference.
    /// @return effectiveBase The effective base efficiency for this link, including any active buff, capped at uint8::max (255).
    function _effectiveBaseEfficiency(uint256 linkId, Token storage t) internal view returns (uint256 effectiveBase) {
        unchecked {
            uint256 boosted = uint256(t.linkEfficiency[linkId].base) + _activeBuffBonus(t);
            return boosted > type(uint8).max ? type(uint8).max : boosted;
        }
    }

    /// @dev    Internal helper to increase a token's active charge and emit the event.
    ///         Centralizing this logic saves significant bytecode by deduplicating
    ///         the `LOG` opcodes and memory setup required for event emission.
    /// @param  tokenId The ID of the token receiving charge.
    /// @param  t The storage reference to the token.
    /// @param  amount The amount of active charge to add.
    function _addActiveCharge(uint256 tokenId, Token storage t, uint256 amount) internal {
        unchecked {
            t.activeCharge += amount;
        }
        emit ActiveCharge(tokenId, amount);
    }

    /// @dev Internal function to charge an active token.
    ///      Propagation Behavior:
    ///      - When a user directly charges an active token (link == false), any sent charge is distributed
    ///        across the token's outgoing links (if any) according to each link's effective efficiency
    ///        (base + temporary buff bonus + affinity bonus).
    ///      - Charge reaching a linked token is always treated as "linked" charge (link == true).
    ///      - Linked charge is added directly to the destination token's `activeCharge` (after applying
    ///        any amplification buff on the destination) and does **not** propagate further downstream.
    ///      - This design intentionally limits propagation to **one level deep** from the original charged
    ///        token, preventing unbounded recursion, deep call stacks, or issues with cycles in the link
    ///        graph while still enabling meaningful network effects.
    ///      - The `if (linksLength == 0 || link)` guard explicitly ensures that only direct user-initiated
    ///        charges can trigger distribution to links; propagated charges always terminate at the first hop.
    /// @param contributor The address making the charge.
    /// @param tokenId The token ID to charge.
    /// @param coins The number of coin units used.
    /// @param bonusCoins Additional coin units applied as active charge (e.g., from affinity bonuses).
    /// @param value The native Ether value (in wei) sent.
    /// @param link A flag indicating if the charge is coming via a link
    ///             (true = one-level propagation already occurred; no further distribution).
    function _chargeActiveToken(address contributor, uint256 tokenId, uint256 coins, uint256 bonusCoins, uint256 value, bool link) internal {
        Token storage t = _tokens[tokenId];

        uint256[] storage links = t.links;
        uint256 linksLength = links.length;

        // If there are no links or the charge is directly linked, add the coins to the active charge.
        if (linksLength == 0 || link) {
            
            uint256 totalIncoming = coins + bonusCoins;
            
            // Check for Amplifier Buff
            // bonusCoins here includes Affinity Bonuses from upstream
            BuffState storage buff = t.buff;
            if (buff.amplification > 0 && block.timestamp < buff.expiresAt) {
                // Calculate bonus: (Total * Multiplier) / 100
                totalIncoming += (totalIncoming * buff.amplification) / 100;
            }
            
            _addActiveCharge(tokenId, t, totalIncoming);

        } else {    
            // Distribute the value and coins among all linked tokens.
            uint256 linkedValue = value / linksLength; // Distribute ETH evenly  
            for (uint256 linkIndex; linkIndex < linksLength; linkIndex++) {                
                uint256 linkId = links[linkIndex];

                // Set linkedCoins to the maximum allowed.
                // Calculate linkedCoins based on base efficiency applied to the coins split evenly amongst the links
                // Effective base efficiency (including any temporary buff)
                uint256 linkedCoins = coins / linksLength;
                // Calculate bonus coins based on affinity bonus applied to the full coins
                uint256 linkedBonusCoins = (coins * t.linkEfficiency[linkId].affinityBonus) / 100;

                {
                    uint256 computedCoins = (coins * _effectiveBaseEfficiency(linkId, t)) / linksLength / 100;
                    
                    if (computedCoins > linkedCoins) {
                        // Exceeds the max! Shift the excess into bonus coins.
                        // linkedCoins is already set to the max, so we leave it alone.
                        linkedBonusCoins += (computedCoins - linkedCoins);
                    } else {
                        // Within limits, update linkedCoins to the actual computed value.
                        linkedCoins = computedCoins;
                    }
                }

                // Attempt to charge the linked token.
                // If successful, reduce remaining value and check for reverberation.
                if (_chargeToken(contributor, linkId, linkedCoins, linkedBonusCoins, linkedValue, true)) {
                    unchecked {
                        // Subtract the successfully distributed value
                        value -= linkedValue;
                    } 

                    // If REVERBERATED buff is active, reflect a fraction of the
                    // *successfully propagated* coins back into this token as fresh activeCharge.
                    if (DigilFlags.has(t.buff.flags, DigilFlags.REVERBERATED) && block.timestamp < t.buff.expiresAt) {
                        uint256 echo;
                        // Treat both base and affinity bonus as outbound “signal”
                        unchecked {
                            // Cap bonusCoins at 4× linkedCoins for controlled “planar drama”
                            uint256 maxBonus = linkedCoins * (AFFINITY_BOOST  * AFFINITY_BOOST); 
                            // We can safely mutate linkedBonusCoins here as it isn't used again in this iteration
                            if (linkedBonusCoins > maxBonus) {
                                linkedBonusCoins = maxBonus;
                            }
                            echo = (linkedCoins + linkedBonusCoins) / AFFINITY_REDUCTION;
                        }
                        if (echo > 0) {
                            _addActiveCharge(tokenId, t, echo);
                        }
                    }
                } else if (linkedCoins != 0) {
                    // If linked token could not be charged, add the coins to the source's active charge.
                    _addActiveCharge(tokenId, t, linkedCoins);
                }
            }
        }

        // Any remaining value is added to the owner's pending distribution.
        if (value > 0) {
            _addDistributedValue(ownerOf(tokenId), value);
        }
    }

    /// @dev    Ensure a contribution struct is in sync with the token's logical contribution epoch.
    ///         When the token's epoch has advanced (e.g. after a full discharge), all previous
    ///         contributions are treated as reset without explicitly zeroing storage for each
    ///         contributor in a loop.
    function _touchContribution(Token storage t, TokenContribution storage c) internal {
        if (c.epoch != t.contributionEpoch) {
            c.epoch = t.contributionEpoch;
            c.charge = 0;
            c.discharge = 0;
            c.value = 0;
            c.exists = false;
            // NOTE: c.whitelisted is intentionally preserved across epochs.
        }
    }

    /// @dev    Internal function to process token charging.
    /// @param  contributor The address contributing to the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The coin units used.
    /// @param  bonusCoins Additional bonus coin units.
    /// @param  value The native Ether value (in wei) provided.
    /// @param  link Flag indicating if the charge is via a link.
    /// @return True if the token was successfully charged.
    function _chargeToken(address contributor, uint256 tokenId, uint256 coins, uint256 bonusCoins, uint256 value, bool link) internal returns(bool) {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        if (t.distributionIndex > 0) {
            if (link) {
                // Linked charges quietly fail while a batch op is in progress,
                // so upstream links can skip this target without reverting the whole call chain.
                return false;
            }
            // Direct charges are not allowed during batch operations.
            revert("DIGIL: Batch Operation In Progress");
        }

        // Proxy contributions require a value contribution
        if (!link && contributor != _msgSender()) {
            // Determine the minimum required value for a proxy contribution.
            uint256 requiredValue = _max(t.incrementalValue, _incrementalValue);

            // For direct proxy calls, we revert if funds are insufficient.
            if (value < requiredValue) _revertInsufficientFunds(requiredValue);
        }
        
        TokenContribution storage c = t.contributions[contributor];
        _touchContribution(t, c);
        
        // Check if contribution is allowed (if restricted, the contributor must be whitelisted).
        bool whitelisted = !t.restricted || c.whitelisted;

        uint256 incrementalValue = t.incrementalValue;
        // Calculate minimum required value for the given number of coins (scaled by _coinMultiplier).
        uint256 minimumValue = incrementalValue * coins / _coinMultiplier;

        // Determine minimum coins required; if incrementalValue is nonzero, derive from provided value.
        uint256 realCoins = coins;
        uint256 minimumCoins = coins;
        if (incrementalValue > 0) {
            minimumCoins = value < incrementalValue || value == 0 ? coins : value / incrementalValue * _coinMultiplier;

            // Ensure minimumValue is at least the token’s incremental value.
            if (minimumValue < incrementalValue) {
                minimumValue = incrementalValue;
            }
        }

        // Ensure at least one coin unit is counted.
        if (minimumCoins < _coinMultiplier) {
            minimumCoins = _coinMultiplier;
        }

        if (link) {
            
            // Linked charging can use active coins to meet the requirements of the minimum charge  
            // If the contributor isn't whitelisted, or not enough coins or value are supplied by the link, the token will not be charged
            if (!whitelisted || minimumCoins > (coins + bonusCoins) || value < minimumValue) {
                 // Fail softly so upstream link logic can continue.
                return false;
            }
            // In linked charging, use the entire provided value.
            minimumValue = value;
            if (coins < minimumCoins) {
                // Top up `coins` logically from the bonusCoins budget.
                // delta is paid from bonus budget
                unchecked {
                    bonusCoins -= (minimumCoins - coins);
                }
                coins = minimumCoins;
            }

        } else {

            // For non-linked charging, enforce whitelisting and minimum value.
            require(whitelisted, "DIGIL: Restricted");

            if (value < minimumValue) _revertInsufficientFunds(minimumValue);
            
            // Transfer coins from the caller (sponsor) to this contract.
            _coinsFromSender(coins);

        }

        // Update last activity
        t.lastActivity = block.timestamp;

        // If the token is active, route the charge accordingly.
        if (t.active) {

            _chargeActiveToken(contributor, tokenId, coins, bonusCoins, value, link);

        } else {

            // For inactive tokens, record contributions.
            if (!c.exists) {
                // New contributor for this epoch
                c.exists = true;
                t.contributors.push(contributor);
            }

            // Coins + required value are tied together at the Charge level
            unchecked {
                c.charge += coins;
                c.discharge += realCoins;
                t.charge += coins;
                c.value += minimumValue;
            }
            emit Charge(contributor, tokenId, coins, minimumValue);

            // minimumValue -> affects c.value and reclaimContribution
            // surplus -> goes to t.value and is logged as Contribute
            if (value > minimumValue) {
                unchecked {
                    uint256 surplus = value - minimumValue;
                    t.value += surplus;
                    emit Contribute(contributor, tokenId, surplus);
                }
            }

        }

        return true;
    }

    /// @notice Charges a token.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    ///         If token.incrementalValue == 0, direct charging (`chargeToken`) does not require ETH;
    ///         any ETH sent is treated as surplus value (credited as token value or distributed per
    ///         the active/inactive path). If token.incrementalValue > 0, ETH must satisfy the
    ///         per-charge minimum derived from incrementalValue.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The number of coin units to use.
    /// @return True if the token was successfully charged.
    function chargeToken(uint256 tokenId, uint256 coins) external payable returns(bool) {
        // Delegate to chargeTokenAs.
        return chargeTokenAs(_msgSender(), tokenId, coins);
    }

    /// @notice Charges a token on behalf of another contributor.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    /// @dev    Requires that both the caller and `contributor` are not blacklisted,
    ///         and the token exists. Participation attribution is based on
    ///         `contributor`.
    ///         Proxy contributions (`contributor != msg.sender`) always require at least one
    ///         incremental-value unit of ETH:
    ///             max(token.incrementalValue, globalIncrementalValue).
    ///         This sponsored-charge floor applies even when token.incrementalValue == 0.
    ///         For self-attributed charging (`contributor == msg.sender`), ETH minimum is derived
    ///         from token.incrementalValue as documented on {chargeToken}.
    /// @param  contributor The address contributing the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The coin units used in the charge.
    /// @return True if the token was successfully charged.
    function chargeTokenAs(address contributor, uint256 tokenId, uint256 coins) public payable returns(bool) {
        _notOnBlacklist(_msgSender());
        _notOnBlacklist(contributor);
        _checkTokenExists(tokenId);
        
        require(contributor != address(0), "DIGIL: Invalid Contributor");
        require(coins >= _coinMultiplier, "DIGIL: Insufficient Charge");
        return _chargeToken(contributor, tokenId, coins, 0, msg.value, false);
    }

    // Token Distribution and Discharge

    /// @dev Core batch distribution routine used by both {activateToken} and
    /// {dischargeToken}.
    ///
    /// High-level behavior (post-Fusaka optimized version):
    /// - Captures the full remaining `charge` and `value` into `distributionCharge`
    ///   and `distributionValue` **once per cycle** (on the very first call).
    /// - Processes contributors in fixed-size batches using cached storage
    ///   references for the contributors array and contribution mapping.
    /// - Activation path: pays proportional value to each contributor and
    ///   accumulates the remainder for the final owner distribution.
    /// - Discharge path: returns the contributor’s full recorded value and
    ///   discharge coins.
    /// - Uses `distributionIndex` as a persistent cursor so the operation can
    ///   safely span multiple transactions.
    /// - When the final batch completes: resets all batch state, converts
    ///   captured charge to `activeCharge` (activation), marks attached
    ///   contract tokens recallable (while active/activating), and distributes remaining value.
    /// - When this function returns `true`, the caller is expected to clear the
    ///   contributors array and bump `contributionEpoch` to complete the logical reset.
    ///
    /// @param tokenId The ID of the token whose contributions are being processed.
    /// @param discharge True = discharge mode (full unwind to contributors),
    ///                  false = activation mode (proportional value + activeCharge).
    /// @return completed True if this call finished the entire distribution cycle,
    ///                   false if more calls are required to process remaining contributors.
    function _distribute(uint256 tokenId, bool discharge) internal returns (bool completed) {
        Token storage t = _tokens[tokenId];

        // Capture full remaining charge/value at start of cycle (only once).
        // This is safe because direct charges are blocked while distributionIndex > 0.
        if (t.distributionCharge == 0) {
            t.distributionCharge = t.charge;
            t.charge = 0;
        }
        if (t.distributionValue == 0) {
            t.distributionValue = t.value;
        }

        // Cache expensive external call once
        address tokenOwner = ownerOf(tokenId);

        uint256 distributionIndex = t.distributionIndex;
        uint256 contributorsCount = t.contributors.length;

        // Determine how many contributors to process in this batch
        uint256 currentBatchSize = _batchSize;
        if (distributionIndex + currentBatchSize > contributorsCount) {
            currentBatchSize = contributorsCount - distributionIndex;
        }

        // incrementalValue is only needed for the activation path
        uint256 incrementalValuePerCharge;
        if (!discharge && t.distributionCharge > 0) {
            incrementalValuePerCharge = (t.distributionValue * _coinMultiplier) / t.distributionCharge;
        }

        // Process the batch via helper (separate stack frame → avoids stack too deep)
        (uint256 ownerDistributionAmount, uint256 batchVolume) = _processBatch(t, distributionIndex, currentBatchSize, incrementalValuePerCharge, discharge);

        // Advance cursor for next call (if any)
        distributionIndex += currentBatchSize;
        t.distributionIndex = distributionIndex;

        // === FINAL BATCH COMPLETED? ===
        if (distributionIndex >= contributorsCount) {
            // Reset all batch state
            t.distributionIndex = 0;
            uint256 capturedCharge = t.distributionCharge;
            t.distributionCharge = 0;
            t.distributionValue = 0;

            uint256 remainingTokenValue = t.value;
            t.value = 0;

            if (discharge) {
                _addDistributedValue(tokenOwner, remainingTokenValue);
            } else {
                if (capturedCharge > 0) {
                    _addActiveCharge(tokenId, t, capturedCharge);
                }
                _addDistributedValue(tokenOwner, ownerDistributionAmount + remainingTokenValue);
            }

            // Contract-token recallable logic
            if (t.contractTokenAddress != address(0)) {
                ContractToken storage ct = _contractTokens[t.contractTokenAddress][tokenId];
                if (_contractTokenAddresses[t.contractTokenAddress][ct.tokenId] == address(this)) {
                    ct.recallable = (t.active || t.activating);
                }
            }

            return true;   // cycle complete
        }

        // Partial progress (activation path only)
        if (!discharge && ownerDistributionAmount > 0) {
            _addDistributedValue(tokenOwner, ownerDistributionAmount);
        }

        // KEEPER BOUNTY: 1% of the volume processed in this batch
        // Incentivizes external gas payment for batch processing
        if (contributorsCount > _batchSize) {
            _addValue(_msgSender(), 0, batchVolume / KEEPER_BOUNTY_DIVISOR);
        }

        // Emit the batch progress event
        emit Batch(tokenId);

        return false;   // more calls needed
    }

    /// @dev Processes one batch of contributors directly from storage.
    /// @param t Storage reference to the Token being processed.
    /// @param startIndex Starting index in the contributors array for this batch.
    /// @param toProcess Number of contributors to process in this batch.
    /// @param incrementalValuePerCharge Value per coin unit (activation path only).
    /// @param discharge True = discharge mode, false = activation mode.
    /// @return ownerDistributionAmount Total value accumulated for the token owner
    ///                                 in activation mode; always 0 in discharge mode.
    /// @return batchVolume Total charge/discharge volume processed in this batch,
    ///                     used to size the keeper bounty.
    function _processBatch(Token storage t, uint256 startIndex, uint256 toProcess, uint256 incrementalValuePerCharge, bool discharge) private returns (uint256 ownerDistributionAmount, uint256 batchVolume) {
        // Cache both storage references once at the function entry.
        // This eliminates repeated slot derivations inside the hot loop.
        address[] storage contributors = t.contributors;
        mapping(address => TokenContribution) storage contributions = t.contributions;

        ownerDistributionAmount = 0;
        batchVolume = 0;

        uint256 cachedTokenValue = t.value; 

        // === HOT LOOP - DIRECT STORAGE READS (fully cached) ===
        for (uint256 i = 0; i < toProcess; ++i) {
            address contributor = contributors[startIndex + i];
            TokenContribution storage contribution = contributions[contributor];

            uint256 value = contribution.value;

            if (discharge) {
                uint256 charge = contribution.discharge;
                // Discharge: full unwind back to contributor
                _addValue(contributor, value, charge);

                unchecked { 
                    // Accumulate volume
                    batchVolume += charge;
                }
            } else {
                uint256 charge = contribution.charge;
                // Activation: accumulate for final owner payout
                uint256 distributableValue;

                unchecked {
                    ownerDistributionAmount += value;

                    distributableValue = incrementalValuePerCharge * charge / _coinMultiplier;

                    if (distributableValue > cachedTokenValue) {
                        distributableValue = cachedTokenValue;
                    }
                    cachedTokenValue -= distributableValue;

                    // Accumulate volume
                    batchVolume += charge;
                }

                _addDistributedValue(contributor, distributableValue);

                
            }
        }

        t.value = cachedTokenValue;

        return (ownerDistributionAmount, batchVolume);
    }

    /// @dev    Resets the token's contributor array and advances the contribution epoch.
    ///         Uses inline assembly to set the array length to 0, which avoids the
    ///         gas cost of iterating over elements to delete them.
    ///         Incrementing `contributionEpoch` logically invalidates all existing
    ///         `TokenContribution` structs for this token without needing to zero them out.
    /// @param  t The storage reference to the Token struct.
    function _clearContributors(Token storage t) internal {
        address[] storage contributors = t.contributors;
        assembly {
            sstore(contributors.slot, 0)
        }
        // Advance the contribution epoch so all existing TokenContribution entries
        // are treated as reset the next time they are touched. Logically wipes old contribution records.
        t.contributionEpoch += 1;
    }

    /// @notice Discharges a token, settling contributions and redistributing any remaining
    ///         active charge into its link graph.
    /// @dev    This is a multi-transaction batch operation with "owner starts, anyone can continue":
    ///
    ///         Call permissions:
    ///         - On the **first** call of a discharge cycle (`discharging == false`),
    ///           the caller must be the token owner or an approved operator. At this
    ///           point the token must have non-zero `charge`, `value`, `activeCharge`,
    ///           or already be in `discharging` mode.
    ///         - Once discharge has started (`discharging == true`), **any address**
    ///           may continue calling {dischargeToken} to advance distribution until
    ///           completion. This ensures long-running discharges cannot become
    ///           permanently stuck if the owner disappears.
    ///
    ///         Fee behavior:
    ///         - On the first call only, the caller must provide exactly the required
    ///           amount of ETH proportional to the token’s complexity:
    ///               required = max(_incrementalValue, token.incrementalValue)
    ///                          × max(1, links.length)
    ///           If `msg.value` is not exactly this amount, the call reverts.
    ///         - Subsequent calls in the same discharge cycle must send exactly 0 ETH.
    ///         - All ETH supplied is routed into the protocol’s value pool via {_addValue}.
    ///
    ///         Distribution behavior:
    ///         - Internally, discharge uses {_distribute} with:
    ///             * `discharge = true` for inactive tokens (full unwind of contributions),
    ///             * `discharge = false` for active tokens (activation-style settlement
    ///               that can move charge into `activeCharge`).
    ///         - Contributions are processed in batches up to `_batchSize` per call.
    ///         - On partial progress, the function returns false and leaves distributionIndex > 0,
    ///           allowing subsequent calls to continue the operation.
    ///         - After the final batch:
    ///             * For discharge mode (`discharge = true`), contributors receive back
    ///               their recorded value/charge via the distribution system and any
    ///               remaining token value is sent to the token owner.
    ///             * For non-discharge mode (`discharge = false`, active token),
    ///               contributors receive proportional value and the remaining
    ///               `distributionCharge` is converted to `activeCharge`.
    ///
    ///         Active charge redistribution:
    ///         - After all contributions and intrinsic value have been settled, any
    ///           remaining `activeCharge` is redistributed into linked tokens:
    ///             * If the ANCHORED flag is active and unexpired, a portion of
    ///               `activeCharge` is retained on this token and the remainder is
    ///               spread across links proportional to their base efficiencies.
    ///             * If ANCHORED is not active, 100% of remaining `activeCharge` is
    ///               redistributed to linked tokens (subject to integer rounding).
    ///         - The token’s own `activeCharge` is updated to the retained remainder.
    ///
    ///         Epoch and state cleanup:
    ///         - After a full discharge cycle:
    ///             * `distributionIndex`, `distributionCharge`, and `distributionValue`
    ///               are reset to zero.
    ///             * `value` is swept into distributions as described above.
    ///             * The contributors array is cleared and `contributionEpoch` is
    ///               incremented, logically resetting per-contributor state on
    ///               next touch without looping over all mappings.
    ///             * Any temporary buff state is cleared, while `buff.appearance`
    ///               is preserved as persistent appearance metadata.
    ///             * If a contract token is attached, recallability is refreshed by
    ///               {_distribute}: active/activating settlement can make it recallable,
    ///               while inactive settlement clears recallability.
    ///         - Completing discharge clears the `discharging` flag but does not
    ///           automatically deactivate an active token. Callers who want the token
    ///           powered down must use {deactivateToken} separately.
    ///
    ///         This function never transfers ownership of the token itself; it only
    ///         settles contributions and redistributes value/active charge according
    ///         to the protocol rules.
    ///
    /// @param  tokenId The token ID to discharge.
    /// @return completed True if this call finished the discharge; false if more
    ///                   calls are required to process remaining contributors.
    function dischargeToken(uint256 tokenId) external payable returns (bool) {
        Token storage t = _tokens[tokenId];

        // First call: require ownership/approval.
        if (!t.discharging) {
            _checkApproved(tokenId);
        } else {
            _notOnBlacklist(_msgSender());
        }

        require(t.charge > 0 || t.value > 0 || t.activeCharge > 0 || t.discharging, "DIGIL: Nothing to Discharge");
        require(!t.activating, "DIGIL: Activation In Progress");
        
        // On the first call of a discharge cycle, enforce the fee.
        if (!t.discharging) {
            // Determine the required minimum value for discharge, scaled by number of links.
            // This scales the "fee" with the complexity of the token's graph.
            uint256 required = _max(t.incrementalValue, _incrementalValue) * _max(t.links.length, 1);
            if (msg.value != required) _revertInsufficientFunds(required);
             _addValue(msg.value);
        } else {
            if (msg.value != 0) _revertInsufficientFunds(0);
        }
        
        // Update last activity
        t.lastActivity = block.timestamp;

        // Mark the token as being in a discharge operation.
        t.discharging = true;
        
        // Run the distribution phase based on mode (may require multiple calls).
        if (!_distribute(tokenId, !t.active)) {
            return false;
        }

        // Redistribute this sigil's remaining activeCharge into its links
        uint256 ac = t.activeCharge;
        if (ac > 0) {
            uint256 retained = 0;
            // Check flag AND expiry
            if (DigilFlags.has(t.buff.flags, DigilFlags.ANCHORED) && block.timestamp < t.buff.expiresAt) {
                retained = ac / (AFFINITY_REDUCTION * AFFINITY_REDUCTION); // Keep 25%
                unchecked {
                    // retained = ac / 4 can’t exceed ac.
                    ac -= retained;                                        // Distribute the rest
                }
            }

            uint256[] storage links = t.links;
            uint256 linkLength = links.length;

            if (linkLength > 0) {
                // 1) Sum efficiencies (weights)
                uint256 sumOfEfficiencies;
                for (uint256 i = 0; i < linkLength; ++i) {
                    uint256 lId = links[i];
                    uint8 baseEfficiency = t.linkEfficiency[lId].base;
                    if (baseEfficiency > 0) {
                        sumOfEfficiencies += baseEfficiency;
                    }
                }

                // 2) Distribute proportionally to base efficiency
                if (sumOfEfficiencies > 0) {
                    for (uint256 i = 0; i < linkLength; ++i) {
                        uint256 linkId = links[i];
                        uint8 baseEfficiency = t.linkEfficiency[linkId].base;
                        if (baseEfficiency == 0) continue;

                        uint256 share = (ac * baseEfficiency) / sumOfEfficiencies;
                        if (share == 0) continue;
                        
                        Token storage linkedToken = _tokens[linkId];

                        // Do not mutate a linked token while it is in an activation/discharge batch.
                        // Preserve the skipped share on the source token instead of burning it.
                        if (linkedToken.distributionIndex == 0) {
                            _addActiveCharge(linkId, linkedToken, share);
                        } else {
                            unchecked {
                                retained += share;
                            }
                        }
                    }

                    // Any rounding remainder from proportional integer division is left undistributed.
                }
            }

            // Update the original token's active charge.
            t.activeCharge = retained;
        }

        // At this point, all contributions for the current epoch have been fully processed.
        // Clear the contributor list and logically reset all contribution state via epoch bump.
        _clearContributors(t);

        // Clear any temporary buff state, but preserve persistent appearance (style/cosmetics/colors).
        uint120 persistedAppearance = t.buff.appearance;
        delete t.buff;
        t.buff.appearance = persistedAppearance;

        // Clear flag on completion
        t.discharging = false;
        emit Discharge(tokenId);
        return true;
    }

    /// @notice Activates a token once its accumulated charge meets the activation threshold.
    /// @dev    This is a multi-transaction batch operation:
    ///         - On the **first** call of an activation cycle (`activating == false`), the
    ///           caller must be the token owner or an approved operator. At this point
    ///           the token must be inactive and `charge >= effectiveThreshold`.
    ///         - Once activation has started (`activating == true`), **any address**
    ///           may continue calling {activateToken} to advance distribution until
    ///           completion. This allows the community to finish long-running activations
    ///           even if the owner goes offline.
    ///
    ///         Threshold behavior:
    ///         - The effective activation threshold is normally `activationThreshold`.
    ///         - If the token has been primed (PRIMED flag set in `buff.flags`), the
    ///           effective threshold is temporarily halved for this activation only.
    ///         - After a successful activation, the PRIMED flag is consumed.
    ///
    ///         Distribution behavior:
    ///         - Internally, activation uses {_distribute} with `discharge = false`.
    ///         - Contributions are processed in batches up to `_batchSize` per call.
    ///         - On partial progress, a {Batch} event is emitted and the function
    ///           returns `false`, indicating more calls are required.
    ///         - Once all contributors have been processed in the current epoch:
    ///             * The token’s `active` flag is set to true.
    ///             * Any captured `distributionCharge` is moved into `activeCharge`.
    ///             * Pending value is distributed to contributors and the token owner
    ///               according to the distribution rules.
    ///
    ///         No Ether is required for activation itself; all ETH-related costs occur
    ///         during charging and other value-manipulating operations.
    ///
    /// @param  tokenId The ID of the token to activate.
    /// @return completed True if this call finished the activation; false if more
    ///                   calls are required to process remaining contributors.
    function activateToken(uint256 tokenId) external returns(bool) {
        Token storage t = _tokens[tokenId];
        
        // First call: require ownership/approval.
        if (!t.activating) {
            _checkApproved(tokenId);
        } else {
            _notOnBlacklist(_msgSender());
        }

        uint256 threshold = t.activationThreshold;
        bool primed = DigilFlags.has(t.buff.flags, DigilFlags.PRIMED);
        if (primed) {
            // Temporarily halve the required activation threshold when PRIMED.
            threshold /= AFFINITY_REDUCTION;
        }

        require(!t.active && (t.charge >= threshold || t.activating), "DIGIL: Token Cannot Be Activated");
        require(!t.discharging, "DIGIL: Discharge In Progress");

        // Update last activity
        t.lastActivity = block.timestamp;
        
        // Set flag at start
        t.activating = true;
        
        if (!_distribute(tokenId, false)) {
            return false;
        }
        
        t.active = true;
        // Clear flag on completion
        t.activating = false;

        // Clear the contributor list to prevent gas bloat ("Ghost Contributors")
        _clearContributors(t);

        // Consume PRIMED after a successful activation, if present.
        if (primed) {
            t.buff.flags = DigilFlags.clear(t.buff.flags, DigilFlags.PRIMED);
        }

        emit Activate(tokenId);
        return true;
    }

    /// @dev Applies thematic "bleed" to a token's active charge:
    ///      - If the token is STABILIZED (STABILIZED bit set in `buff.flags`), consume that
    ///        protection and skip the bleed for this call.
    ///      - Otherwise, burn `activeCharge / AFFINITY_REDUCTION`.
    ///        With AFFINITY_REDUCTION = 2, this burns ~50% (integer-rounded down).
    /// @param t The token whose activeCharge will be reduced.
    function _applyActiveChargeBleed(Token storage t) internal {
        uint256 ac = t.activeCharge;
        if (ac == 0) return;

        if (DigilFlags.has(t.buff.flags, DigilFlags.STABILIZED)) {
            // Consume the protection, but skip the bleed
            t.buff.flags = DigilFlags.clear(t.buff.flags, DigilFlags.STABILIZED); // Clear flag
            return;
        }

        uint256 lost = ac / AFFINITY_REDUCTION; // e.g., half
        unchecked {
            // lost = ac / 2 can’t exceed ac.
            t.activeCharge = ac - lost;
        }
    }

    /// @notice Deactivates an active token.
    /// @dev    Deactivation is a purely stateful operation:
    ///         - No ETH is required.
    ///         - The token must have zero `charge` but may hold non-zero `activeCharge`.
    ///         - On deactivation, {_applyActiveChargeBleed} is invoked:
    ///               * If the token is STABILIZED, the stabilization is consumed and
    ///                 no bleed occurs.
    ///               * Otherwise, roughly 50% of `activeCharge` is burned
    ///                 (AFFINITY_REDUCTION = 2).
    ///         - The token cannot be in the middle of a batch activation/discharge
    ///           operation (`distributionIndex` must be zero).
    /// @param  tokenId The ID of the token to deactivate.
    function deactivateToken(uint256 tokenId) external {
        Token storage t = _tokens[tokenId];
        require(t.active && t.charge == 0, "DIGIL: Token Cannot Be Deactivated");
        // Make sure the token isn't currently being discharged or activated
        _authorizeIdleAndTouch(tokenId, t);

        // Thematic bleed: lose 1 / AFFINITY_REDUCTION of activeCharge on each deactivation.
        _applyActiveChargeBleed(t);

        t.active = false;
        emit Deactivate(tokenId);
    }

    // Token Links

    /// @dev    Computes the coin cost for creating/updating a link with a given
    ///         efficiency and current link count, including early-link discounts.
    ///         - Base cost is still derived from efficiency and link count
    ///           (using the existing triangular scale logic).
    ///         - If this is a brand-new link and the token has no more than two
    ///           stored links after insertion, the cost is reduced by 50%.
    ///           A foundational planar link counts toward this stored-link count.
    /// @param  efficiency  The link efficiency (percentage).
    /// @param  linkCount   The total number of links on the token *after* this call.
    /// @param  isNewLink   True if this is the first time linking to `linkId`.
    /// @param  buffBonus   The current active buff bonus (0 if inactive).
    /// @return cost The ERC20 coin amount to charge (in full token units, scaled by
    ///              the underlying ERC20 decimals), after applying early-link
    ///              discounts and any active buff discount.
    function _linkCoinCost(uint8 efficiency, uint256 linkCount, bool isNewLink, uint8 buffBonus) internal view returns (uint256 cost) {
        // Scaling logic: efficiency plus triangular escalation.
        uint256 linkScale = 200 / linkCount;
        uint256 e = efficiency > linkScale ? efficiency - linkScale : 0;
        cost = (uint256(efficiency) + (e * (e + 1) / 2)) * _coinRate;

        // Apply buff discount first
        if (buffBonus > 0) {
            cost = cost * 100 / (100 + uint256(buffBonus));
        }

        if (isNewLink && linkCount <= 2) {
            // Discount applies only when this new link leaves the token with
            // no more than two stored links total. A foundational planar link
            // counts toward that total.
            cost = cost / AFFINITY_REDUCTION;
        }
    }

    /// @notice Links two tokens together to facilitate coin generation or transfers.
    ///         A token can have no more than 10 links.
    ///         Requires a value greater than or equal to:
    ///             source.incrementalValue + destination.incrementalValue
    ///         Any value contributed is split between and added to the source and
    ///         destination token.
    ///         The coin cost for linking scales with efficiency and number of links,
    ///         with the following discounts applied:
    ///             - Early-link: A brand-new link receives a 50% discount when the
    ///               token has no more than two stored links after insertion. A
    ///               foundational planar link counts toward this total.
    ///             - Community Expansion: after new-link or upgrade pricing is
    ///               calculated, linking to a token owned by a different address
    ///               receives a 25% discount on the final Coin cost.
    ///         An efficiency of 1 indicates ~1% transfer; 100 indicates 100%; 200
    ///         indicates 200%, etc.
    /// @dev    A token's foundational Plane link (its "element") can only be set at
    ///         creation (in {createToken}) and is immutable. This function is for
    ///         creating peer-to-peer links between Digils, not for changing the
    ///         foundational Plane. The affinity bonus for this link is calculated
    ///         based on the foundational Planes (planar links) of the two Digils
    ///         involved. Cannot link directly to foundational planar tokens
    ///         (IDs 0–PLANAR_MAX_ID).
    ///         If the destination token is restricted, the source token's owner must
    ///         already be whitelisted on the destination before the link can be created.
    ///         This structural check is separate from the runtime contributor whitelist
    ///         enforced during actual charging/propagation into restricted tokens.
    /// @param  tokenId    The source token ID.
    /// @param  linkId     The destination token ID to link to.
    /// @param  efficiency The efficiency of the link (percentage based).
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) external payable {
        Token storage t = _tokens[tokenId];
        // _checkApproved calls ownerOf(tokenId).
        // ownerOf(tokenId) reverts if the token does not exist.
        //_checkTokenExists(tokenId);
        //_checkTokenExists(linkId);        
        _authorizeIdleAndTouch(tokenId, t);

        Token storage d = _tokens[linkId];
        _requireNoBatch(d);

        // Existing link state
        uint8 baseEfficiency = t.linkEfficiency[linkId].base;
        bool isNewLink = (baseEfficiency == 0);
        if (isNewLink) {
            require(t.links.length < MAX_LINKS, "DIGIL: Too Many Links");
        }

        // Validate link: tokens must be different, destination must be non-planar,
        // and the new efficiency must strictly improve on the current base.
        require(tokenId != linkId && linkId > PLANAR_MAX_ID && efficiency > baseEfficiency, "DIGIL: Invalid Link" );

        // If a temporary buff is active, charge additional activeCharge only when
        // adding a brand-new outgoing link. Existing links were already included in
        // the original buff's link-count pricing, so upgrades only pay the normal
        // link-upgrade Coin cost below.
        if (isNewLink) {
            _chargeBuffForNewLink(t);
        }

        address sourceOwner = ownerOf(tokenId);
        address destinationOwner = ownerOf(linkId);
        require(!d.restricted || d.contributions[sourceOwner].whitelisted, "DIGIL: Restricted");

        uint256 value = msg.value;
        uint256 requiredValue = t.incrementalValue + d.incrementalValue;
        if (value < requiredValue) _revertInsufficientFunds(requiredValue);

        // Split the contributed value evenly between the two tokens.
        uint256 half = value / 2;
        _createValue(tokenId, half);
        uint256 otherHalf;
        unchecked {
            // half = value / 2 guarantees `value - half` cannot underflow.
            otherHalf = value - half;
        }
        _createValue(linkId, otherHalf);

        // Update affinity bonus in storage, if applicable.
        _updateLinkAffinity(t, d, linkId, efficiency);

        // Update base efficiency in storage.
        t.linkEfficiency[linkId].base = efficiency;

        // If this is a brand-new link, add it to the list.
        if (isNewLink) {
            t.links.push(linkId);
        }

        // For the event and cost, read back the final stored efficiency.
        LinkEfficiency storage eff = t.linkEfficiency[linkId];
        emit Link(tokenId, linkId, eff.base, eff.affinityBonus);

        // Determine if a buff is currently active for the a discount.
        uint8 buffBonus = _activeBuffBonus(t);

        // Compute and charge incremental coin cost, including early-link and active buff discounts.
        uint256 coinCost = _linkCoinCost(efficiency, t.links.length, isNewLink, buffBonus);

        if (!isNewLink && baseEfficiency > 0) {
            // Compute cost for the old configuration (same linkCount, no early-link discount).
            uint256 oldCost = _linkCoinCost(baseEfficiency, t.links.length, false, buffBonus);

            if (coinCost > oldCost) {
                coinCost -= oldCost;
            } else {
                coinCost = 0; // If rounding makes newCost <= oldCost, treat the upgrade as free.
            }
        }

        // Community Expansion: 25% discount if the destination token has a different owner
        // than the source token.
        // Discount = 1 / (Reduction^2) = 1/4 = 25%.
        if (destinationOwner != sourceOwner) {
            unchecked {
                coinCost -= coinCost / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
            }
        }

        _coinsFromSender(coinCost);
    }

    /// @dev    Computes the activeCharge cost of a buff given:
    ///         - bonus: temporary bonus effectiveness (0–100)
    ///         - duration: duration in whole minutes
    ///         - linkCount: number of affected links
    ///         Uses the calibrated cost model:
    ///             cost ≈ bonus * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR
    ///         and enforces a minimum cost of `_coinRate`, so tiny buffs are never effectively free.
    /// @param  bonus The temporary buff bonus (0–100).
    /// @param  duration The duration in minutes.
    /// @param  linkCount The number of outgoing links affected.
    /// @return cost The activeCharge cost in coin units.
    function _buffCost(uint256 bonus, uint256 duration, uint256 linkCount) internal view returns (uint256 cost) {
        unchecked {
            cost = bonus * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR;
        }

        // Enforce "minimum cost = _coinRate" rule for any buff.
        if (cost < _coinRate) {
            cost = _coinRate;
        }
    }

    /// @dev    Charges additional activeCharge when a new link is created while a temporary
    ///         buff is active for the given token. Uses the remaining buff duration
    ///         and the same cost model as {buffToken}, but per-link (linkCount = 1).
    ///         No-op if no active buff or the buff has expired.
    /// @param  t The source token storage reference whose buff should be charged.
    function _chargeBuffForNewLink(Token storage t) internal {
        BuffState storage buff = t.buff;
        if (block.timestamp >= buff.expiresAt) {
            // No active buff; adding a new link is free of buff-related costs.
            return;
        }

        uint256 remainingSeconds = uint256(buff.expiresAt) - block.timestamp;
        uint256 remainingMinutes = remainingSeconds / 60;
        if (remainingMinutes == 0) {
            // Always bill at least 1 minute if there is any remaining time.
            remainingMinutes = 1;
        }
        
        // Retrieve pre-calculated magnitude
        uint256 magnitude = uint256(buff.magnitude);

        uint256 cost = _buffCost(magnitude, remainingMinutes, 1);
        if (t.activeCharge < cost) revert InsufficientActiveCharge(cost);
        t.activeCharge -= cost;
    }

    /// @dev    Internal function to calculate the affinity bonus when linking tokens.
    /// @param  sourceId The source token (or plane) ID.
    /// @param  destinationId The destination token (or plane) ID.
    /// @param  efficiency The provided link efficiency.
    /// @return _bonus The calculated bonus value.
    function _affinityBonus(uint256 sourceId, uint256 destinationId, uint8 efficiency) internal view returns (uint256 _bonus) {
        bytes storage s = _tokens[sourceId].data;
        bytes storage d = _tokens[destinationId].data;

        // Cache the destination byte to avoid repeated storage reads
        bytes1 target = d[0];
        uint256 efficiencyBase = uint256(efficiency);

        // Base Bonus Calculation
        if (s[1] == target || s[2] == target) {
            // If the source has strong affinity with the destination, provide a bonus of 2x the efficiency.
            _bonus = efficiencyBase * AFFINITY_BOOST;
        } else if (sourceId == destinationId || sourceId > 16) {
            // If the source is the same as the destination,
            // or the source is an ethereal plane (aether, world), provide a bonus of 1x the efficiency.
            _bonus = efficiencyBase;
        } else if (s[3] == target) {
            // If the source has moderate affinity with the destination, provide a bonus of .5x the efficiency.
            _bonus = efficiencyBase / AFFINITY_REDUCTION;
        } else if (s[4] == target) {
            // If the source has weak affinity with the destination, provide a bonus of .25x the efficiency.
            _bonus = efficiencyBase / AFFINITY_REDUCTION / AFFINITY_REDUCTION;
        }

        // Base Bonus Multipliers
        if (sourceId > 16) {
            // If the source is from an ethereal plane, increase the bonus by 4x.
            _bonus *= AFFINITY_BOOST * AFFINITY_BOOST;
        } else if (sourceId > 11 || destinationId == 18) {
            // If the source is an energy plane (harmony, discord, entropy, exergy, magick),
            // or the destination is the world plane, increase the bonus by 2x.
            _bonus *= AFFINITY_BOOST;
        }

        // Charge Comparison and Adjustment
        if (_tokens[destinationId].activeCharge > _tokens[sourceId].activeCharge) {
            // Prefer linking to "weaker" planes.
            // If the destination's active charge is greater than the source's, decrease the bonus by .5x.
            _bonus /= AFFINITY_REDUCTION;
        }

        return _bonus;
    }

    /// @dev    Updates the stored affinity bonus for a link if the newly computed bonus
    ///         is greater than the existing stored bonus.
    ///         The calculation considers up to two source identities and two destination
    ///         identities:
    ///         - each token's foundational planar link, if present; and
    ///         - each token's active attunement, if present and unexpired.
    ///         The function keeps the maximum bonus found and never lowers an existing
    ///         affinity bonus.
    /// @param  t          Storage reference to the source token.
    /// @param  d          Storage reference to the destination token.
    /// @param  linkId     The destination token ID being linked.
    /// @param  efficiency The proposed base link efficiency.
    function _updateLinkAffinity(Token storage t, Token storage d, uint256 linkId, uint8 efficiency) internal {
        // 1. Get Source Candidates
        uint256 s1 = (t.links.length > 0 && t.links[0] <= PLANAR_MAX_ID) ? t.links[0] : 0;
        // Check attunement/expiry
        uint256 s2 = (t.buff.attunement > 0 && block.timestamp < t.buff.expiresAt) ? t.buff.attunement : 0;

        // 2. Get Destination Candidates
        uint256 d1 = (d.links.length > 0 && d.links[0] <= PLANAR_MAX_ID) ? d.links[0] : 0;
        uint256 d2 = (d.buff.attunement > 0 && block.timestamp < d.buff.expiresAt) ? d.buff.attunement : 0;

        uint256 bestBonus;

        // 3. Manual Unroll (Cheaper than memory allocation + loop overhead)
        // Compare s1 against d1/d2
        if (s1 != 0) {
            if (d1 != 0) bestBonus = _max(bestBonus, _affinityBonus(s1, d1, efficiency));
            if (d2 != 0) bestBonus = _max(bestBonus, _affinityBonus(s1, d2, efficiency));
        }
        // Compare s2 against d1/d2
        if (s2 != 0) {
            if (d1 != 0) bestBonus = _max(bestBonus, _affinityBonus(s2, d1, efficiency));
            if (d2 != 0) bestBonus = _max(bestBonus, _affinityBonus(s2, d2, efficiency));
        }

        if (bestBonus > t.linkEfficiency[linkId].affinityBonus) {
            t.linkEfficiency[linkId].affinityBonus = bestBonus;
        }
    }

    /// @notice Unlinks a token from another token.
    ///         This function is only for removing peer-to-peer Digil links (IDs > PLANAR_MAX_ID).
    ///         The foundational planar link chosen at creation time is immutable and cannot
    ///         be removed or changed:
    ///         - Attempts to unlink a planar ID in the range [0 .. PLANAR_MAX_ID] will revert.
    ///         - The first link in a token's `links` array (when present) is its foundational plane.
    ///           That link is never removed by this function.
    ///
    /// @dev    When a non-planar link is removed:
    ///         - The corresponding `linkEfficiency[linkId]` entry is reset to (0, 0).
    ///         - The link ID is removed from the `links` array using swap-and-pop to avoid gaps.
    ///         - A {Unlink} event is emitted for off-chain consumers.
    ///
    /// @param  tokenId The source token ID initiating the unlink.
    /// @param  linkId The destination token ID to unlink. 
    function unlinkToken(uint256 tokenId, uint256 linkId) external {
        Token storage t = _tokens[tokenId];
        // _checkApproved calls ownerOf(tokenId).
        // ownerOf(tokenId) reverts if the token does not exist.
        //_checkTokenExists(tokenId);
        _authorizeIdleAndTouch(tokenId, t);

        // Disallow unlinking foundational planes (IDs 0..PLANAR_MAX_ID)
        // so the token's elemental identity cannot be removed.
        require(linkId > PLANAR_MAX_ID && t.linkEfficiency[linkId].base > 0, "DIGIL: Invalid Link");

        // Reset the link efficiency for the specified link.
        t.linkEfficiency[linkId] = LinkEfficiency(0, 0);

        uint256[] storage links = t.links;
        uint256 linksLength = links.length;
        // Loop through links to remove the specified link.
        for (uint256 linkIndex; linkIndex < linksLength; linkIndex++) {
            uint256 lId = links[linkIndex];
            if (lId == linkId) {
                // To remove an element from an array without leaving a gap,
                // swap it with the last element and then pop.
                links[linkIndex] = links[linksLength - 1];
                links.pop();
                emit Unlink(tokenId, linkId);
                break;
            }
        }
    }

    // Buffs

    /// @dev    Returns the active buff bonus, or 0 if expired/inactive.
    function _activeBuffBonus(Token storage t) internal view returns (uint8) {
        // If inactive, expiresAt is 0, so block.timestamp < expiresAt is false.
        if (block.timestamp < t.buff.expiresAt) {
            return t.buff.efficiencyBonus;
        }
        return 0;
    }

    /// @dev    Emits the unified buff-state-change event.
    ///         Used by {buffToken}, {primeToken}, and {stabilizeToken}. Consumers should
    ///         inspect {tokenBuff} after this event if they need to distinguish the
    ///         resulting buff flags, expiry, appearance, or temporary effect values.
    /// @param  tokenId The token whose buff state changed.
    function _emitBuff(uint256 tokenId) internal {
        emit Buff(tokenId);
    }

    /// @notice Applies/updates a temporary buff on an **active** token.
    /// @dev    Buff effects while active (`block.timestamp < expiresAt`):
    ///         - Outgoing link efficiency: `efficiencyBonus` is added to each link's stored base efficiency
    ///           when computing propagation splits (see {_effectiveBaseEfficiency}).
    ///         - Incoming amplification: if `amplification > 0`, any incoming linked charge that lands on this
    ///           token is increased by `(incoming * amplification) / 100` (see {_chargeActiveToken}).
    ///         - Attunement: if `attunement > 0`, affinity calculations may treat this token as if it were linked
    ///           to that plane for bonus selection (see {_updateLinkAffinity}).
    ///         - ANCHORED: if set and unexpired, {dischargeToken} retains a fraction of remaining activeCharge.
    ///         - REVERBERATED: if set and unexpired, a fraction of *successfully propagated* link charge
    ///           “echoes” back into this token as fresh activeCharge.
    ///
    ///         Pricing / payment model:
    ///         - This function charges the token’s `activeCharge` (not ERC20 coins).
    ///         - A precomputed `magnitude` score is calculated from requested parameters:
    ///             * `efficiencyBonus + amplification`
    ///             * + tiered attunement weight (scaled by attunement plane and short-duration boost)
    ///               and reduced by 25% when the chosen attunement has strong affinity with the token's
    ///               primary planar link (Synergy Discount)
    ///             * + costs for requested flags and tier tags
    ///             * + a small flat weight if `appearance` tags are provided
    ///         - Cost uses {_buffCost(magnitude, duration, linkCount)} where:
    ///             * duration is in minutes
    ///             * linkCount is `max(1, t.links.length)`
    ///             * minimum cost is `_coinRate` (so non-zero buffs are never free)
    ///
    ///         Flag rules:
    ///         - Callers cannot set STABILIZED or PRIMED via this function (they are masked off).
    ///         - STABILIZED is managed by {stabilizeToken}; PRIMED is managed by {primeToken}/{activateToken}.
    ///
    ///         Appearance behavior:
    ///         - `appearance` is stored in `t.buff.appearance`.
    ///         - If the caller supplies `appearance == 0`, the existing stored appearance is left unchanged.
    ///         - Appearance is preserved across full discharges (see {dischargeToken}) even though the rest
    ///           of the temporary buff state is cleared.
    ///
    /// @param tokenId         The token to buff.
    /// @param efficiencyBonus Temporary bonus added to outgoing link base efficiency (0–100).
    /// @param attunement      Planar ID to mimic for affinity (1–17, or 0 for none).
    /// @param amplification   Incoming charge multiplier percent (0–100; 20 => +20%).
    /// @param flags           Requested buff flags/tier tags. STABILIZED/PRIMED are ignored here.
    /// @param appearance      Packed style/cosmetics/colors payload (uint120). 0 means “don’t change”.
    /// @param duration        Buff duration in whole minutes (1 .. 10080).
    function buffToken(uint256 tokenId, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance, uint256 duration) external {
        Token storage t = _tokens[tokenId];

        require(t.active, "DIGIL: Token Not Active");
        _authorizeIdleAndTouch(tokenId, t);

        // Sanitize input: Only allow user flags (remove Stabilized/Primed if user tried to sneak them in)
        uint16 requestedFlags = flags & DigilFlags.USER_FLAGS_MASK;

        require(
            efficiencyBonus <= MAX_BUFF_BONUS &&
            attunement < PLANAR_MAX_ID &&
            amplification <= MAX_BUFF_BONUS &&
            (
                efficiencyBonus > 0 ||
                attunement > 0 || 
                amplification > 0 ||
                requestedFlags > 0 ||
                appearance != 0
            ),
            "DIGIL: Invalid Buff"
        );
        
        require(duration > 0 && duration <= MAX_BUFF_DURATION_MIN, "DIGIL: Invalid Buff Duration");

        // Calculate Magnitude
        {
            unchecked {
                uint256 magnitude = uint256(efficiencyBonus) + uint256(amplification);

                // 1. Attunement Cost
                if (attunement > 0) {
                    uint256 tier;
                    if (attunement < 4) tier = 4;         // void/karma/kaos
                    else if (attunement < 8) tier = 1;    // elements
                    else if (attunement < 12) tier = 2;   // para
                    else if (attunement < 17) tier = 8;   // energy
                    else tier = 16;                       // aether

                    if (duration <= 15) {
                        tier *= AFFINITY_BOOST;
                    }

                    uint256 attunementCost = tier * 50;

                    // --- Synergy Discount ---
                    uint256 baseLink = t.links.length > 0 ? t.links[0] : 0;
                    if (baseLink > 0 && baseLink <= PLANAR_MAX_ID) {
                        bytes storage s = _tokens[baseLink].data;
                        bytes storage d = _tokens[attunement].data;
                        bytes1 target = d[0];
                        if (s[1] == target || s[2] == target) {
                            // 25% off magnitude for strong affinity 
                            attunementCost -= attunementCost / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
                        }
                    }

                    magnitude += attunementCost;
                }
                // 2. Flag Cost (The "Payment" Logic)
                // Check each allowed user flag. If set, increase magnitude.
                if (DigilFlags.has(requestedFlags, DigilFlags.ANCHORED))      magnitude += 50;
                if (DigilFlags.has(requestedFlags, DigilFlags.REVERBERATED))  magnitude += 50;
                if (DigilFlags.has(requestedFlags, DigilFlags.ELEMENTAL))     magnitude += 5;
                if (DigilFlags.has(requestedFlags, DigilFlags.PARAELEMENTAL)) magnitude += 10;
                if (DigilFlags.has(requestedFlags, DigilFlags.VOIDIC))        magnitude += 25;
                if (DigilFlags.has(requestedFlags, DigilFlags.KARMIC))        magnitude += 50;
                if (DigilFlags.has(requestedFlags, DigilFlags.KAOTIC))        magnitude += 50;
                if (DigilFlags.has(requestedFlags, DigilFlags.AETHERIAL))     magnitude += 100;
                if (DigilFlags.has(requestedFlags, DigilFlags.CELESTIAL))     magnitude += 200;
                // --- Appearance tagging cost (style/cosmetics/colors in `appearance`) ---
                // Light flat magnitude so appearance tagging isn't completely free.
                if (DigilAppearance.hasStyle(appearance))     magnitude += 5;
                if (DigilAppearance.hasCosmetics(appearance)) magnitude += 5;
                if (DigilAppearance.hasColors(appearance))    magnitude += 5; // includes mainRgb + gradients

                // Save the magnitude
                t.buff.magnitude = uint16(magnitude);

                // Calculate link count (min 1)
                uint256 linkCount = t.links.length;
                if (linkCount == 0) linkCount = 1;

                // Cost is proportional to magnitude, duration, and number of affected links.
                uint256 cost = _buffCost(magnitude, duration, linkCount);
                if (t.activeCharge < cost) revert InsufficientActiveCharge(cost);
                t.activeCharge -= cost;
            }
        }

        // Compute expiry timestamp in seconds
        uint256 expiry = block.timestamp + (duration * 1 minutes);
        t.buff.expiresAt = uint40(expiry);
        t.buff.efficiencyBonus = efficiencyBonus;
        t.buff.amplification = amplification;
        t.buff.attunement = attunement;

        // Preserve internal flags (STABILIZED + PRIMED), apply requested user flags.
        uint16 preservedInternal = t.buff.flags & DigilFlags.INTERNAL_ONLY_MASK;
        t.buff.flags = preservedInternal | requestedFlags;

        // Appearance is persistent across discharges; only overwrite if caller provides nonzero payload.
        if (appearance != 0) {
            t.buff.appearance = appearance;
        }

        _emitBuff(tokenId);
    }

    /// @notice Primes an inactive token to temporarily reduce its activation threshold
    ///         for the next successful activation.
    /// @dev    - Token must be inactive and not in an activation/discharge batch.
    ///         - Caller must be approved for the token.
    ///         - Cost scales with activationThreshold.
    ///         - Sets the PRIMED flag in the token's BuffState.
    ///         - PRIMED is consumed (cleared) after the token is successfully activated once.
    /// @param  tokenId The ID of the token to prime.
    function primeToken(uint256 tokenId) external {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];
        require((t.buff.flags & DigilFlags.PRIMED) == 0, "DIGIL: Already Primed");

        // Compact guard: inactive, not mid-batch, not already primed, has threshold.
        require(!t.active && t.distributionIndex == 0 && t.activationThreshold > 0, "DIGIL: Token Cannot Be Primed");

        // Charge a coin fee for priming.
        uint256 cost = t.activationThreshold / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
        _coinsFromSender(cost);

        // Mark token as primed.
        t.buff.flags = DigilFlags.set(t.buff.flags, DigilFlags.PRIMED);

        // Update last activity
        t.lastActivity = block.timestamp;

        _emitBuff(tokenId);
    }

    /// @notice Pays ERC20 Coins to protect the token from "bleed" during the next
    ///         deactivation or recall.
    /// @dev    Base Cost is 25% of the current activeCharge, payable in Coins.
    ///         (This allows the user to pay a smaller fee to save the 50% bleed).
    ///         If a buff is active, cost is further reduced by: cost * 100 / (100 + bonus).
    ///         Sets the `stabilized` flag to true.
    /// @param  tokenId The token ID to stabilize.
    function stabilizeToken(uint256 tokenId) external {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];
        require((t.buff.flags & DigilFlags.STABILIZED) == 0, "DIGIL: Already Stabilized");
        
        uint256 ac = t.activeCharge;
        require(ac > 0, "DIGIL: Token Cannot Be Stabilized");

        // Calculate Insurance Cost.
        // Bleed is 50% (ac / 2). We set insurance cost to 25% (ac / 4).
        // This makes paying the fee mathematically rational.
        // We enforce a minimum floor of 10 * coinRate to prevent dust spam.
        uint256 floor = 10 * _coinRate;
        uint256 calculatedCost = ac / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
        
        uint256 cost = _max(calculatedCost, floor);

        // Apply Discount if Buff is active
        uint8 bonus = _activeBuffBonus(t);
        if (bonus > 0) {
            // Active buffs reduce stabilization cost: cost *= 100 / (100 + bonus).
            cost = cost * 100 / (100 + uint256(bonus));
        }

        // Transfer Coins from the user to the contract
        _coinsFromSender(cost);

        // Set protection
        t.buff.flags = DigilFlags.set(t.buff.flags, DigilFlags.STABILIZED);

        // Update last activity
        t.lastActivity = block.timestamp;
        
        _emitBuff(tokenId);
    }

    /// @notice Overcharges an active token by converting ETH directly into activeCharge.
    /// @dev    Only an approved operator for the token may call this function.
    ///         This includes the token owner, an address approved for this token,
    ///         or an operator approved via {setApprovalForAll}. 
    ///         - No ERC20 Coins are moved.
    ///         - No contribution records are created.
    ///         - All ETH sent is treated as system value and assigned to the
    ///           contract’s own distribution via {_addValue}.
    ///
    ///         The cost per `_coinMultiplier` units of `coins` is:
    ///             cost = 2x * max(token.incrementalValue, _incrementalValue)
    ///
    ///         where `2x` is provided by the AFFINITY_BOOST constant.
    ///
    /// @param  tokenId The ID of the token to overcharge.
    /// @param  coins   The amount of activeCharge to add, in coin units (scaled by `_coinMultiplier`).
    function overchargeToken(uint256 tokenId, uint256 coins) external payable {
        require(coins >= _coinMultiplier, "DIGIL: Insufficient Charge");

        Token storage t = _tokens[tokenId];

        // Do not interfere with batch operations or activation/discharge flows.
        _authorizeIdleAndTouch(tokenId, t);
        require(t.active, "DIGIL: Token Not Active");

        // Use the greater of the token's incremental value or the global minimum.
        uint256 iv = _max(t.incrementalValue, _incrementalValue);

        // Premium cost: 2x the normal ETH-per-coin-unit rate.
        // `coins` is in "coin units" (scaled by _coinMultiplier), so we normalize by _coinMultiplier.
        uint256 required = (iv * coins * AFFINITY_BOOST) / _coinMultiplier;
        if (msg.value != required) _revertInsufficientFunds(required);

        // Required ETH becomes contract-level value / system fuel.
        _addValue(required);

        // Grant raw activeCharge to the token.
        _addActiveCharge(tokenId, t, coins);
    }

}
