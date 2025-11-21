// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

// Import OpenZeppelin contracts for standard ERC721 functionality, ownership, safe transfers, counters, ERC20 interfacing, and reentrancy protection.
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Digil Token (NFT)
/// @author gSOLO
/// @notice NFT contract used for the creation, charging, and activation of Digital Sigils on the Ethereum Blockchain
/// @custom:security-contact security@digil.co.in
contract DigilToken is ERC721, Ownable, IERC721Receiver, ReentrancyGuard {
    // String utils
    using Strings for uint256;  // Allow uint256 values to be converted to strings

    // Immutable contract-level variables set during construction
    IERC20 private immutable _coins;            // The ERC20 token used for coin transfers within the contract
    uint256 private immutable _coinMultiplier;  // Multiplier based on the ERC20 token's decimals to handle calculations correctly
    
    // Coin rate and bonus rate
    uint256 private _coinRate;                                  // Mutable coin rate for various operations, set by the owner
    uint256 private constant BONUS_RATE_DIVISOR = 100;          // Divisor for calculating bonus coins when value is added
    uint256 private constant MAX_COIN_RATE = 1000000000;        // The maximum coin rate for operations

    // Constants for bonus interval and multiplier
    uint256 private constant BONUS_INTERVAL = 15 minutes;       // Time interval for bonus coin accrual upon withdrawal. Allows 100% of bonus coins to be retrieved every 25 hours 
    uint256 private constant VALUE_MULTIPLIER = 1000 gwei;      // A base unit to simplify setting minimum value
    uint256 private constant FIRST_WITHDRAW_MULTIPLIER = 50;    // First withdraw can grant up to 50x the normal coin-rate cap

    // Configuration values for incremental and transfer values
    uint256 private _incrementalValue = 100 * VALUE_MULTIPLIER; // Minimum incremental ETH value required for charging
    uint256 private _transferValue = 95 * VALUE_MULTIPLIER;     // The portion of incremental value distributed to users

    // Planar token policy
    uint256 private constant PLANAR_MAX_ID = 18;                // Highest planar token ID that can be linked.
    uint256 private constant PLANAR_TRANSFER_MAX_ID = 20;       // Highest planar token ID that can be transferred. The planar set is [0 .. PLANAR_TRANSFER_MAX_ID] inclusive.
    bool private _planarTransferActive;                         // When true, a temporary transfer window is open to move planar tokens from the current owner to the new owner during `transferOwnership`.

    // Batch operations limiter
    uint16 private constant DEFAULT_BATCH_SIZE = 256;           // Default number of items to process in a single batch operation
    uint16 private _batchSize = DEFAULT_BATCH_SIZE;             // Configurable batch size for distribution or discharge operations

    // Define the inactivity period for rescuing tokens
    uint256 private constant STALLED_TIMEOUT = 30 days;         // A short timeout to rescue tokens stuck in a batch operation (e.g., activate/discharge)
    uint256 private constant INACTIVITY_PERIOD = 365 days;      // A long timeout to rescue tokens that are truly abandoned but have value

    // Max link and affinity bonus scale
    uint256 private constant MAX_LINKS = 10;                    // Maximum number of links a token can have
    uint256 private constant AFFINITY_BOOST = 2;                // Multiplier for strong affinity bonuses
    uint256 private constant AFFINITY_REDUCTION = 2;            // Divisor for weak affinity bonuses and charge-balancing penalties

    // Buff configuration
    uint8  private constant MAX_BUFF_BONUS = 100;               // Maximum temporary bonus
    uint16 private constant MAX_BUFF_DURATION_MIN = 24 * 60;    // Maximum duration of buffs (24 hours)
    uint256 private constant LINK_BUFF_COST_FACTOR = 24 * 60;   // The cost per bonus-point-hour per link
    uint256 private constant BUFF_COST = 50;                    // The cost of each buff flag

    // Mappings for token data, blacklisted addresses, distributions, and contract tokens
    mapping(uint256 => Token) private _tokens;                                      // Mapping from token ID to its detailed Token struct
    mapping(address => bool) private _blacklisted;                                  // Mapping for addresses that have opted out of the system
    mapping(address => Distribution) private _distributions;                        // Mapping for pending distributions of coins and ETH value per address
    mapping(address => mapping(uint256 => bool)) private _contractTokenExists;      // Tracks if an external ERC721 token has already been vaulted
    mapping(address => mapping(uint256 => ContractToken)) private _contractTokens;  // Stores data for vaulted external ERC721 tokens

    /// @dev Structure to hold pending coin and value distributions for a user, and the time of the last distribution
    struct Distribution {
        uint256 time;   // Timestamp of the last withdrawal, used for bonus calculations
        uint256 coins;  // Pending ERC20 coins to be withdrawn
        uint256 value;  // Pending Ether value to be withdrawn
    }

    /// @dev Structure to represent the efficiency of a link between two tokens
    struct TokenContribution {
        uint256 charge;     // Coins contributed to the token's charge
        uint256 value;      // Ether value contributed
        uint256 epoch;      // Logical contribution epoch for the token
        bool exists;        // True if the contributor exists (has contributed)
        bool distributed;   // True if the contribution has been processed during an activation/discharge
        bool whitelisted;   // True if the contributor is whitelisted
    }

    /// @dev Structure to represent a vaulted external ERC721 token
    struct ContractToken {
        uint256 tokenId;    // The token ID of the external ERC721
        bool recallable;    // True if the original owner can recall the token
    }

    /// @dev Structure to represent link efficiency between tokens
    struct LinkEfficiency {
        uint8 base;             // The base efficiency percentage for coin transfer (e.g., 100 = 100%)
        uint256 affinityBonus;  // Additional bonus efficiency generated from planar affinity
    }

    // Buff Bitmasks
    uint8 private constant STABILIZED = 1;  // 00000001 (Anti-Bleed)
    uint8 private constant ANCHORED   = 2;  // 00000010 (Retain Charge on Discharge)
    uint8 private constant PRIMED     = 4;  // 00000100 (Half Activation Threshold)

    /// @dev State for a temporary buff on a token
    struct BuffState {
        uint64 expiresAt;       // Unix timestamp (in seconds) when the buff expires
        uint8 efficiencyBonus;  // Temporary bonus on top of base efficiency (0–100)
        uint8 attunement;       // ID of the plane to mimic (1-18)
        uint8 amplification;    // Bonus multiplier percentage for incoming charge (e.g. 20 = 1.2x)
        uint8 flags;            // Bitmask: Stabilized, Anchored, Primed
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

        // --- SLOT 10: State Flags (Packed) ---
        // 4 bools = 4 bytes. Uses 1 slot total.
        bool active;                // True if the token has been activated
        bool activating;            // A lock flag, true if the token is currently in the process of being activated
        bool discharging;           // A lock flag, true if the token is currently in the process of being discharged
        bool restricted;            // True if contributions are restricted to a whitelist

        // --- SLOT 11: External Data (Packed) ---
        // 20 bytes (address) + 12 bytes (BuffState) = 32 bytes. Uses 1 slot total.
        address contractTokenAddress; // External ERC721 contract address attached (if any)
        BuffState buff;               // Temporary buff applied to this token.

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

    /// @notice Emitted when an address opts out (added to the blacklist).
    /// @param  account The address of the account that opted out
    event OptOut(address indexed account);

    /// @notice Emitted when an address opts in (removed from the blacklist).
    /// @param  account The address of the account that opted in
    event OptIn(address indexed account);

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

    /// @notice Emitted when a token is activated or is in the process of being activated.
    /// @dev    Check with tokenData to get an idea of its completion progress
    /// @param  tokenId The ID of the token that was or is being activated
    /// @param  complete Indicates whether the process was completed
    event Activate(uint256 indexed tokenId, bool complete);

    /// @notice Emitted when a token is deactivated.
    /// @param  tokenId The ID of the token that was deactivated
    event Deactivate(uint256 indexed tokenId);

    /// @notice Emitted when a token is charged.
    /// @param  addr The address attributed with charging the token
    /// @param  tokenId The ID of the token being charged
    /// @param  coins The number of coins the token was charged with
    /// @param  sender The address that charged the token
    event Charge(address indexed addr, uint256 indexed tokenId, uint256 coins, address sender);

    /// @notice Emitted when an active token is charged.
    /// @param  tokenId The ID of the token being charged
    /// @param  coins The number of coins the token was charged with
    event ActiveCharge(uint256 indexed tokenId, uint256 coins);

    /// @notice Emitted when a token is discharged or is in the process of being discharged.
    /// @dev    Check with tokenData to get an idea of its completion progress
    /// @param  tokenId The ID of the token that was or is being discharged
    /// @param  complete Indicates whether the process was completed
    event Discharge(uint256 indexed tokenId, bool complete);

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

    /// @notice Emitted when a temporary buff is applied to a token.
    /// @param  tokenId The token whose outgoing links were buffed.
    /// @param  efficiencyBonus The temporary bonus applied on top of each link's base efficiency.
    /// @param  attunement The temporary plane this token is attuned with.
    /// @param  amplification The percentage multiplier applied to incoming charge.
    /// @param  flags The flagged buffs.
    /// @param  duration The buff duration, in minutes.
    event Buff(uint256 indexed tokenId, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint8 flags, uint256 duration);

    /// @notice Emitted when a token is stabilized to prevent active charge bleed.
    /// @param  tokenId The ID of the token being stabilized.
    event Stabilize(uint256 indexed tokenId);

    /// @notice Emitted when value is generated for the contract.
    /// @dev    Value can be assigned to a token by using the admin function createValue
    /// @param  value The value added to the pending distributions for this contract
    event ContractDistribution(uint256 value);

    /// @notice Emitted when pending coin and value distributions are created for an address.
    /// @param  addr The address this pending distribution is for
    /// @param  coins The coins added to the pending distributions for this address  
    /// @param  value The value added to the pending distributions for this address
    event PendingDistribution(address indexed addr, uint256 coins, uint256 value);

    /// @notice Emitted when value is added to a token.
    /// @dev    This event is specifically tied to the charging process of a token. 
    ///         It records the portion of value contributed by a user that is used to "charge" the token—
    ///         think of this as satisfying a minimum requirement for charging the token.
    /// @param  addr The address this event is attributed to
    /// @param  tokenId The ID of the token whose value increased
    /// @param  value The value that was contributed
    event Contribute(address indexed addr, uint256 indexed tokenId, uint256 value);

    /// @notice Emitted when contributed value is added directly to a token's value.
    /// @dev    This event logs excess value contributed during the charging process that goes beyond the minimum required for charging.
    ///         Instead of being used for the charge, this excess is added directly to the token’s value.
    /// @param  addr The address this event is attributed to
    /// @param  tokenId The ID of the token whose value increased
    /// @param  value The amount the token's value increased
    event ContributeValueAs(address indexed addr, uint256 indexed tokenId, uint256 value);

    /// @notice Emitted when additional value is added to or created for a token.
    /// @dev    This event records general value additions to a token that occur outside the charging process.
    ///         It’s emitted in scenarios like token creation, restriction, or other operations
    ///         where value is added to the token without being tied to a specific charging action.
    /// @param  tokenId The ID of the token whose value increased
    /// @param  value The amount the token's value increased
    event ContributeValue(uint256 indexed tokenId, uint256 value);

    /// @notice Error thrown when insufficient funds are sent.
    /// @param  required The value required for the transaction
    error InsufficientFunds(uint256 required);

    /// @notice Error thrown when a coin transfer fails.
    /// @param  coins The number of coins required for the transaction that failed to transfer
    error CoinTransferFailed(uint256 coins);

    /// @notice Error thrown when a token's active coin count is insufficienmt to execute an operation.
    /// @param  required The activeCharge required for the transaction
    error InsufficientActiveCharge(uint256 required);

    /// @notice Contract constructor. Initializes state variables, mints initial planar tokens, and sets up contract parameters.
    /// @param  initialOwner The address that will own the contract and initial tokens
    /// @param  coins The address of the ERC20 token used as the system's currency
    /// @param  coinDecimals The number of decimals for the coin token
    constructor(address initialOwner, address coins, uint256 coinDecimals) ERC721("Digil Token", "DDIGIL") Ownable(initialOwner) {
        _coins = IERC20(coins);
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
        // 0:   identifier
        // 1:   strong affinity
        // 2:   strong affinity
        // 3:   weak affinity
        // 4:   delimiter
        // 5-9: simplified name
        bytes[21] memory data;
        data[0] =  bytes("----|");      // null
        data[1] =  bytes("xrot|X");     // void
        data[2] =  bytes("roxy|K.N ");  // karma
        data[3] =  bytes("orxy|K.S");   // kaos
        data[4] =  bytes("faly|X.S");   // fire
        data[5] =  bytes("afly|X.E");   // air
        data[6] =  bytes("ewny|X.N");   // earth
        data[7] =  bytes("weny|X.W");   // water
        data[8] =  bytes("im-y|X.NW");  // ice
        data[9] =  bytes("lfay|X.NE");  // lightning
        data[10] = bytes("mi-y|X.NNE"); // metal
        data[11] = bytes("newy|X.NNW"); // nature
        data[12] = bytes("hrdy|X.SE");  // harmony
        data[13] = bytes("dohy|X.SW");  // discord
        data[14] = bytes("podt|K.W");   // entropy
        data[15] = bytes("grht|K.E");   // negentropy/exergy
        data[16] = bytes("kpgt|K");     // magick/kosmos
        data[17] = bytes("txy-|K.X");   // aether
        data[18] = bytes("yxt-|X.R");   // external reality
        data[19] = bytes("----|.XR");   // extended reality
        data[20] = bytes("----|.ILXR"); // digil reality
        
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

    /// @dev    Returns true if `tokenId` is a planar token.
    /// @param  tokenId The token to check.
    /// @return True for planar IDs 0..20, false otherwise.
    function _isPlanar(uint256 tokenId) internal pure returns (bool) {
        return tokenId <= PLANAR_TRANSFER_MAX_ID;
    }

    /// @inheritdoc ERC721
    /// @dev    For planar tokens, only the contract owner or this contract itself
    ///         is authorized to operate. Operator approvals and per-token approvals
    ///         are intentionally ignored for these IDs.
    function _isAuthorized(address owner_, address spender, uint256 tokenId) internal view override returns (bool) {
        if (_isPlanar(tokenId)) {
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
        for (uint256 tokenId = 0; tokenId <= PLANAR_TRANSFER_MAX_ID; ) {
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

    /// @dev    Updates core economic parameters of the contract. Only callable by the owner.
    /// @param  coins Used to determine a number of values:
    ///                     Maximum number of bonus Coins a user can withdraw.
    ///                     Number of Coins required to Update a Token URI.
    ///                     Number of Coins required to Link a Token.
    ///                     Number of Coins required to Opt-Out.
    /// @param  incrementalValue The minimum value (in wei) used to Charge, Activate a Token, update a Token URI
    /// @param  transferValue The value (in wei) to be distributed when a Token is Activated per incrementalValue
    /// @param  batchSize The multiplier used for batch size for distribute and discharge calls that can be made per transaction 
    function configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize) external onlyOwner {
        // Validate configuration parameters.
        require(coins > 0 && coins <= MAX_COIN_RATE && incrementalValue > 0 && transferValue <= incrementalValue && transferValue >= (incrementalValue * 9 / 10) && batchSize > 0, "DIGIL: Invalid Configuration");

        _coins.approve(address(this), type(uint256).max); // Re-approve coins to allow maximum transfers.
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
    /// @dev    When Ether is sent to this contract, it is added to the contract’s value balance.
    receive() external payable {
        _addValue(msg.value);
    }

    /// @dev    Computes the time-based bonus coins that would be awarded to `addr`
    ///         at `nowTs`, without mutating state. Mirrors the logic used in {withdraw}.
    ///         - Requires the user to hold at least one Digil token or some Coins.
    ///         - On the first qualifying withdrawal (distribution.time == 0), the cap
    ///           is FIRST_WITHDRAW_MULTIPLIER * _coinRate; afterwards it is _coinRate.
    /// @param  addr The address whose bonus is being computed.
    /// @param  distribution The Distribution storage slot for this address.
    /// @param  nowTs The timestamp to use for the calculation (typically block.timestamp).
    /// @return bonus The number of bonus coin units that would be granted.
    function _pendingBonus(address addr, Distribution storage distribution, uint256 nowTs) internal view returns (uint256 bonus) {
        // Must have at least one Digil token or some ERC20 Coins.
        if (balanceOf(addr) == 0 && _coins.balanceOf(addr) == 0) {
            // User must be economically involved in the system to earn time-based bonuses.
            return 0;
        }

        uint256 lastBonusTime = distribution.time;

        // If this is the first time (time == 0), allow a larger cap.
        uint256 cap = _coinRate;
        if (lastBonusTime == 0) {
            // First withdrawal can pull a one-time larger bonus up to FIRST_WITHDRAW_MULTIPLIER × coinRate.
            cap = _coinRate * FIRST_WITHDRAW_MULTIPLIER;
        }

        // If lastBonusTime > nowTs (weird but possible in some edge cases), clamp.
        if (nowTs <= lastBonusTime) {
            // No time elapsed since the last bonus, so nothing to accrue.
            return 0;
        }

        // Each full BONUS_INTERVAL grants _coinMultiplier units, up to the cap.
        uint256 rawBonus = (nowTs - lastBonusTime) / BONUS_INTERVAL * _coinMultiplier;
        bonus = rawBonus < cap ? rawBonus : cap;
    }

    /// @notice Withdraws any pending coin and value distributions for the sender, and optionally provides bonus coins.
    /// @dev    Bonus coins are calculated based on the time since the last distribution.
    ///         On the first qualifying withdrawal (when distribution.time == 0), the user can receive
    ///         up to FIRST_WITHDRAW_MULTIPLIER times the normal coin-rate cap in bonus coins.
    /// @return coins The number of coin units transferred to the sender.
    /// @return value The native Ether value transferred to the sender.
    function withdraw() external nonReentrant returns(uint256 coins, uint256 value) {
        address addr = _msgSender();
        // Ensure the sender is not blacklisted.
        _notOnBlacklist(addr);

        Distribution storage distribution = _distributions[addr];

        // Retrieve and reset the pending value and coin distributions.
        value = distribution.value;
        distribution.value = 0;
        coins = distribution.coins;
        distribution.coins = 0;

        // Compute time-based bonus coins using the shared helper.
        uint256 nowTs = block.timestamp;
        uint256 bonus = _pendingBonus(addr, distribution, nowTs);
        if (bonus > 0) {
            // Record the new "lastBonusTime" only in the real withdrawal path.
            // This ensures preview calls never mutate state.
            distribution.time = nowTs;
            coins += bonus;
        }

        // Transfer any pending native value to the sender.
        if (value > 0) {            
            Address.sendValue(payable(addr), value);
        }

        // Attempt to transfer coins from this contract to the sender; if it fails, reassign the pending coins.
        if (coins > 0 && !_transferCoinsFrom(address(this), addr, coins)) {
            // If the ERC20 transfer fails for any reason (e.g., allowance issues),
            // re-credit the coins back to the user's distribution so they can retry later.
            distribution.coins = coins;
            coins = 0;
        }

        return (coins, value);
    }

    /// @notice Returns a preview of the caller's pending withdrawal, including
    ///         queued distributions and the time-based bonus coins they would
    ///         receive if they called {withdraw} in the current block.
    /// @dev    This is a convenience wrapper around {previewWithdrawOf}, using
    ///         `_msgSender()` as the address. It does not modify state and
    ///         performs no transfers.
    /// @return totalCoins The total coins that would be transferred (base + bonus).
    /// @return baseCoins  The pending distribution coins currently stored.
    /// @return bonusCoins The additional time-based bonus coins that would be granted.
    /// @return value      The pending Ether value that would be transferred.
    function previewWithdraw() external view returns (uint256 totalCoins, uint256 baseCoins, uint256 bonusCoins, uint256 value) {
        return previewWithdrawOf(_msgSender());
    }

    /// @notice Returns a preview of an address's pending withdrawal, including
    ///         queued distributions and the time-based bonus coins they would
    ///         receive if they called {withdraw} in the current block.
    /// @dev    This function:
    ///         - Reuses the shared bonus calculation logic via {_pendingBonus}
    ///           to stay in sync with {withdraw}.
    ///         - Does not modify state and performs no transfers.
    ///         - Reverts if `addr` has opted out via the blacklist.
    /// @param  addr The address whose pending withdrawal is being queried.
    /// @return totalCoins The total coins that would be transferred (base + bonus).
    /// @return baseCoins  The pending distribution coins currently stored for `addr`.
    /// @return bonusCoins The additional time-based bonus coins that would be granted.
    /// @return value      The pending Ether value that would be transferred.
    function previewWithdrawOf(address addr) public view returns (uint256 totalCoins, uint256 baseCoins, uint256 bonusCoins, uint256 value) {
        _notOnBlacklist(addr);
        Distribution storage distribution = _distributions[addr];

        baseCoins = distribution.coins;
        value = distribution.value;

        uint256 nowTs = block.timestamp;
        bonusCoins = _pendingBonus(addr, distribution, nowTs);

        totalCoins = baseCoins + bonusCoins;
    }

    // Add Value and Distributions

    /// @dev    Internal helper that adds native value to the contract’s balance.
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
            distribution.value += value;
            distribution.coins += coins;
            if (addr == address(this)) {
                emit ContractDistribution(value);
            } else {
                emit PendingDistribution(addr, coins, value);
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
        // 1. Calculate the contract's fee based on the total value.
        // We multiply first to maintain precision before dividing.
        // This correctly calculates the fee even if `value` is less than `_incrementalValue`.
        // Formula: fee = value * ((_incrementalValue - _transferValue) / _incrementalValue)
        uint256 contractFee = (value * (_incrementalValue - _transferValue)) / _incrementalValue;

        // 2. Calculate the value that goes to the user.
        // This is simply the original value minus the fee we just calculated.
        uint256 userValue = value - contractFee;

        // 3. Calculate bonus coins based on full `_incrementalValue` steps in the original `value`.
        // Only complete increments earn rewards; partial increments are ignored by design.
        uint256 fullIncrements = value / _incrementalValue;
        uint256 bonusCoins = (_coinRate / BONUS_RATE_DIVISOR) * fullIncrements;
        
        // 4. Add the calculated amounts to their respective distributions.
        // The contract gets its fee.
        _addValue(contractFee);

        // The user gets the remaining value and any bonus coins.
        _addValue(addr, userValue, bonusCoins);
    }

    /// @dev    Internal function that adds contributed value to a token.
    /// @param  tokenId The token to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function _createValue(uint256 tokenId, uint256 value) internal {
        if (value > 0) {
            _tokens[tokenId].value += value;
            emit ContributeValue(tokenId, value);
        }
    }

    /// @notice Creates Value for a Token using the contract's available balance.
    /// @dev    Requires that the contract has enough value; deducts the amount from the contract distribution.
    /// @param  tokenId The token ID to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function createValue(uint256 tokenId, uint256 value) external payable onlyOwner {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        _addValue(msg.value);

        // Ensure the contract has sufficient available value.
        if (_distributions[address(this)].value < value) revert InsufficientFunds(value);

        _distributions[address(this)].value -= value;

        _createValue(tokenId, value);
    }

    // ERC721 Updates

    /// @inheritdoc ERC721
    /// @dev    Overrides the ERC721 _update function to perform additional checks and actions.
    ///         Enforces planar policy:
    ///         - Planar tokens cannot be burned (`to != address(0)`),
    ///          - Outside of transfer ownership, planar tokens must always be held by the admin (`to == owner()`),
    ///          - During transfer ownership (`_planarTransferActive == true`), movement is allowed so the
    ///         current owner can pass custody to the new admin.
    ///         Non-planar tokens are unaffected.
    /// @param  to The address receiving the token.
    /// @param  tokenId The token ID being transferred.
    /// @param  auth Authorization address.
    /// @return The previous owner address.
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        // Ensure neither the sender nor the recipient are blacklisted.
        _notOnBlacklist(_msgSender());
        _notOnBlacklist(to);

        // Pre-transfer planar checks (skip on mint: prev == address(0))
        address prev = _ownerOf(tokenId);
        if (prev != address(0) && _isPlanar(tokenId)) {
            // 1) Planar tokens cannot be burned.
            require(to != address(0), "DIGIL: Planar Non-burnable");
            // 2) Outside of transfer ownership, planar tokens must remain with the admin.
            if (!_planarTransferActive) {
                require(to == owner(), "DIGIL: Planar Locked to Owner");
            }
        }

        // Perform the standard ERC721 token update (transfer).
        address from = super._update(to, tokenId, auth);
        
        Token storage t = _tokens[tokenId];

        // Update last activity
        t.lastActivity = block.timestamp;

        // Automatically whitelist the new owner for this token.
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

    /// @notice Allows the sender to opt out or opt in to token transfers.
    ///         Requires sending a value equal to or greater than the current incremental value at the coin rate.
    ///         For example at 0.0001ETH incremental value and 100 coin rate, requires .01ETH
    /// @param  optOut Send true to opt out, false to opt in
    function setOptStatus(bool optOut) external payable {
        address account = _msgSender();
        require(_blacklisted[account] != optOut, "DIGIL: No Change");

        // Calculate required minimum funds for opting in/out.
        // This ties the opt decision to the current economic scale of the system.
        uint256 required = _incrementalValue * _coinRate / _coinMultiplier;        
        if (msg.value < required) revert InsufficientFunds(required);
        
        // Add the sent value to the contract’s distribution (not to any specific token).
        _addValue(msg.value);

        // Update the accounts blacklist status.
        _blacklisted[account] = optOut;

        if (optOut) {
            emit OptOut(account);
        } else {
            emit OptIn(account);
        }
    }

    /// @notice Rescues a token from an account that has opted out or that hasnt seen significant action.
    /// @dev    Only callable by the contract owner. Transfers the token from a blacklisted/inactive address to a specified address.
    ///         If a planar token is rescued, to must be the contract owner, otherwise the transaction will revert.
    ///         Even when an address has opted out (blacklisted), rescue is only allowed after the
    ///         appropriate inactivity timeout (`STALLED_TIMEOUT` for stalled batch operations,
    ///         or `INACTIVITY_PERIOD` for normal inactivity), giving the user time to opt back in.
    /// @param  tokenId The token ID to rescue.
    /// @param  to The address to which the token is transferred.
    function rescueToken(uint256 tokenId, address to) external onlyOwner {
        _checkTokenExists(tokenId);

        require(to != address(0), "DIGIL: Invalid Rescue Address");

        Token storage t = _tokens[tokenId];
        address currentOwner = ownerOf(tokenId);

        bool isStalled = t.distributionIndex > 0;
        bool canBeRescued;

        if (isStalled) {
            // If the token is stalled in a batch operation, allow a quick rescue after STALLED_TIMEOUT
            canBeRescued = block.timestamp >= t.lastActivity + STALLED_TIMEOUT;
        } else {
            // If the token is not stalled, use the long INACTIVITY_PERIOD for true abandonment
            canBeRescued = block.timestamp >= t.lastActivity + INACTIVITY_PERIOD;
        }

        // Conditions for rescue:
        // - Owner is blacklisted AND the inactivity timer has elapsed, OR
        // - Token is inactive/abandoned AND it still has "economic weight" (value or charge).
        bool canRescueByBlacklist = _blacklisted[currentOwner] && canBeRescued;
        bool canRescueByAbandonment =
            canBeRescued &&
            (
                t.value > 0 ||
                (t.active == false && t.contributors.length > 0 && t.charge > 0 && t.incrementalValue > 0)
            );

        require(canRescueByBlacklist || canRescueByAbandonment, "DIGIL: Token Cannot Be Rescued");

        // Remove approvals before transfer (escrow via this contract).
        _approve(address(this), tokenId, address(0), false);
        // Transfer the token from the blacklisted or inactive address
        _transfer(currentOwner, to, tokenId);
        // Clear approvals post-transfer to avoid stray approvals on the new owner.
        _approve(address(0), tokenId, address(0), false);
    }

    // ERC721 Receiver

    /// @notice Handles the receipt of an external ERC721 token.
    /// @dev    When an ERC721 token is sent to this contract, creates a new Digil Token representing the token received.
    ///         The incremental value of the token is set to the minimum non-zero incremental value, with an activation threshold of 0.
    ///         The account (ERC721 contract address), and external token ID are appended to the Token URI as a query string.
    ///         Any data sent is stored with the Token and forwarded during Safe Transfer when {recallToken} is called.
    /// @param  operator The address which initiated the transfer.
    /// @param  from The previous owner of the ERC721 token.
    /// @param  tokenId The token ID of the external ERC721.
    /// @param  data Optional data forwarded with the transfer.
    /// @return bytes4 Selector confirming receipt.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external nonReentrant returns (bytes4) {
        _notOnBlacklist(operator);
        _notOnBlacklist(from);

        address account = _msgSender();

        // Double-check the external token actually resides in this contract.
        require(IERC721(account).ownerOf(tokenId) == address(this), "DIGIL: Contract Token Not Received");

        // Ensure that this external token has not been received before.
        require(!_contractTokenExists[account][tokenId], "DIGIL: Contract Token Already Exists");
        _contractTokenExists[account][tokenId] = true;

        // Create a new internal token with minimum incremental value and zero activation threshold.
        uint256 internalId = _createToken(from, _incrementalValue, 0, data);   
        // Store the external tokenId keyed by (external contract, internal digilId).     
        _contractTokens[account][internalId].tokenId = tokenId;

        Token storage t = _tokens[internalId];
        // Append the ERC721 contract address and tokenId as query parameters to the token URI.
        t.uri = string(
            abi.encodePacked(
                tokenURI(internalId),
                "?account=",
                Strings.toHexString(uint160(account), 20),
                "&tokenId=",
                tokenId.toString()
            )
        );

        // Track the attached contract token address and add it as a contributor.
        // The contract itself becomes the first "contributor" for distribution logic.
        t.contractTokenAddress = account;
        t.contributors.push(account);
        
        return this.onERC721Received.selector;
    }

    /// @notice Recalls an external contract token attached to a Digil token.
    /// @dev    The external token becomes recallable only after the Digil token has
    ///         passed through an activation/discharge distribution cycle, which sets
    ///         `contractToken.recallable = true`. This function:
    ///         - Requires that `account` matches the attached ERC721 contract.
    ///         - Requires that the attached token is currently marked as recallable.
    ///         - Applies {_applyActiveChargeBleed} to the Digil's `activeCharge`:
    ///             * If STABILIZED, the stabilization is consumed and no bleed occurs.
    ///             * Otherwise, roughly 50% of `activeCharge` is burned.
    ///         - Clears the attachment state and safely transfers the external
    ///           ERC721 back to the current Digil owner, forwarding `t.data` as
    ///           the transfer `data`.
    /// @param  account The address of the external ERC721 contract.
    /// @param  tokenId The internal Digil token ID whose attached contract token is to be recalled.
    function recallToken(address account, uint256 tokenId) external nonReentrant {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];

        // Safety check: enforce that the supplied account matches the attached contract.
        require(account == t.contractTokenAddress, "DIGIL: Invalid Contract Account");

        ContractToken storage contractToken = _contractTokens[account][tokenId];
        require(contractToken.recallable, "DIGIL: Contract Token Is Not Recallable");

        uint256 contractTokenId = contractToken.tokenId;

        // --- Effects: clear all "attached contract" state first ---
        contractToken.tokenId = 0;
        contractToken.recallable = false;
        _contractTokenExists[account][contractTokenId] = false;
        t.contractTokenAddress = address(0);

        address owner = ownerOf(tokenId);

        // Thematic bleed: lose 1 / AFFINITY_REDUCTION of activeCharge when recalled.
        _applyActiveChargeBleed(t);

        // --- Interaction: external call happens after state updates ---
        // Safely transfer the external ERC721 token back to the current owner of the Digil token.
        ERC721(account).safeTransferFrom(address(this), owner, contractTokenId, t.data);
    }

    // Token Information

    /// @dev    Internal function to ensure a token exists (i.e. has a non-zero owner).
    /// @param  tokenId The token ID to check.
    function _checkTokenExists(uint256 tokenId) internal view {
        require(_ownerOf(tokenId) != address(0), "DIGIL: Token Does Not Exist");
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
        _checkTokenExists(tokenId);

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
    /// @dev    Contributors may still be greater than zero after discharge if this is a contract token,
    ///         as the first contributor will be an ERC721 address until the underlying token is recalled.
    /// @param  tokenId The token ID to query.
    /// @return active Whether the token is active.
    /// @return activating Whether the token is being activated.
    /// @return discharging Whether the token is being discharged.
    /// @return restricted Whether the token is restricted.
    /// @return stabilized Whether the token is stabilized.
    /// @return links The number of links associated with the token.
    /// @return contributors The number of contributor addresses.
    /// @return contributionEpoch The logical epoch for contributions on this token.
    /// @return distributionIndex The current distribution index.
    /// @return data Arbitrary data stored with the token.
    function tokenData(uint256 tokenId) external view returns(bool active, bool activating, bool discharging, bool restricted, bool stabilized, uint256 links, uint256 contributors, uint256 contributionEpoch, uint256 distributionIndex, bytes memory data) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];
        bool isStabilized = (t.buff.flags & STABILIZED) != 0;

        return (t.active, t.activating, t.discharging, t.restricted, isStabilized, t.links.length, t.contributors.length, t.contributionEpoch, t.distributionIndex, t.data);
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
    /// @return charge The amount of coin units this address has contributed to the token's charge.
    /// @return value The amount of native value (in wei) attributed to this contributor on this token.
    /// @return exists True if a contribution record currently exists for this contributor.
    /// @return distributed True if this contributor has already been processed in the current distribution epoch.
    /// @return whitelisted True if this contributor is whitelisted for this token (relevant when the token is restricted).
    /// @return epoch The logical contribution epoch this record belongs to.
    function tokenContribution(uint256 tokenId, address contributor) external view returns (uint256 charge, uint256 value, bool exists, bool distributed, bool whitelisted, uint256 epoch) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];
        TokenContribution storage c = t.contributions[contributor];
        return (c.charge, c.value, c.exists, c.distributed, c.whitelisted, c.epoch);
    }

    /// @notice Retrieves link information for a token at a specific index.
    /// @param  tokenId The ID of the source token whose link is being queried.
    /// @param  index The zero-based index into the token's `links` array.
    /// @return linkId The ID of the linked token (or plane) at the given index.
    /// @return base The stored base efficiency percentage for this link.
    /// @return affinityBonus The additional affinity-based efficiency for this link.
    /// @return efficiencyBonus The temporary efficiency bonus applied to all outgoing links (0–100).
    /// @return attunement The current attunement Planar ID (0 if none).
    /// @return amplification The current charge amplification percentage (0 if none).
    /// @return flags      The current buff flag bitmask (only non-zero while a buff is active):
    ///                        1 = Stabilized, 2 = Anchored, 4 = Primed.
    /// @return expiresAt  The unix timestamp when the current buff expires
    ///                    (0 if no buff has ever been set).
    /// @return effectiveBase The effective base efficiency including any active buff
    function tokenLinkAt(uint256 tokenId, uint256 index) external view returns (uint256 linkId, uint8 base, uint256 affinityBonus, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint8 flags, uint64 expiresAt, uint256 effectiveBase) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];

        require(index < t.links.length, "DIGIL: Link Index Out Of Bounds");

        linkId = t.links[index];
        LinkEfficiency storage efficiency = t.linkEfficiency[linkId];

        base = efficiency.base;
        affinityBonus = efficiency.affinityBonus;

        BuffState storage buff = t.buff;
        efficiencyBonus = buff.efficiencyBonus;
        expiresAt = buff.expiresAt;
        
        if (block.timestamp < expiresAt) {
            attunement = buff.attunement;
            amplification = buff.amplification;
            flags = buff.flags; // Return the raw mask
        }

        effectiveBase = _effectiveBaseEfficiency(linkId, t);

        return (linkId, base, affinityBonus, efficiencyBonus, attunement, amplification, flags, expiresAt, effectiveBase);
    }

    /// @notice Returns information about an external ERC721 token attached to this Digil.
    /// @dev    If no external token is attached, `contractTokenAddress` will be zero,
    ///         and both `externalTokenId` and `recallable` will be zero/false.
    /// @param  tokenId The internal Digil token ID being queried.
    /// @return contractTokenAddress The ERC721 contract address of the attached token (zero if none).
    /// @return externalTokenId      The external ERC721 tokenId attached to this Digil (zero if none).
    /// @return recallable           True if the attached token can currently be recalled via {recallToken}.
    function tokenAttachment(uint256 tokenId) external view returns (address contractTokenAddress, uint256 externalTokenId, bool recallable) {
        _checkTokenExists(tokenId);
        
        Token storage t = _tokens[tokenId];
        contractTokenAddress = t.contractTokenAddress;

        if (contractTokenAddress != address(0)) {
            ContractToken storage ct = _contractTokens[contractTokenAddress][tokenId];
            externalTokenId = ct.tokenId;
            recallable      = ct.recallable;
        }
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
    /// @param  activationThreshold The number of coins required for token activation.
    /// @param  restricted Whether the token is restricted to whitelisted addresses for charging.
    /// @param  plane The chosen planar token (numeric index) to link with. This becomes the immutable
    ///               foundational plane for this token. Must be 0 (no plane) or in the planar range
    ///               [1 .. PLANAR_MAX_ID]. Foundational planes cannot be linked or changed later.
    /// @param  data Optional arbitrary data to store with the token.
    /// @return tokenId The ID of the newly created token.
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes calldata data) external payable nonReentrant returns(uint256) {
        // Require minimum incremental value
        if (incrementalValue > 0) {
            require(incrementalValue >= _incrementalValue, "DIGIL: Invalid Incremental Value");
        }
        
        // Create a new token with the given parameters.
        uint256 tokenId = _createToken(_msgSender(), incrementalValue, activationThreshold, data);
        Token storage t = _tokens[tokenId];

        // If the token is to be restricted, ensure the caller sends the required funds.
        if (restricted) {
            uint256 required = t.incrementalValue > _incrementalValue ? t.incrementalValue : _incrementalValue;
            if (msg.value < required) revert InsufficientFunds(required);

            t.restricted = true;
            emit Restrict(tokenId);
        }

        // If any Ether is sent, add it as token value.
        _createValue(tokenId, msg.value);

        // If a plane is specified (plane > 0), process the coin fee and link the token to the plane.
        if (plane > 0) {
            require(plane <= PLANAR_MAX_ID, "DIGIL: Invalid Plane");
            // Different fee structures based on plane index, pricing rarer planes higher.
            if (plane < 4) {
                // Void / karmic / kaotic planes (1–3): 5× coinRate
                _coinsFromSender(_coinRate * 5);
            } else if (plane > 16) {
                // Ethereal planes (17–18): 100× coinRate
                _coinsFromSender(_coinRate * 100);
            } else if (plane > 11) {
                // Energy planes (12–16): 25× coinRate
                _coinsFromSender(_coinRate * 25);
            } else if (plane > 7) {
                // Paraelemental planes (8–11): 1× coinRate
                _coinsFromSender(_coinRate);
            }
            // Record the plane link as the immutable foundational plane (index 0 in links[]).
            t.links.push(plane);
            t.linkEfficiency[plane] = LinkEfficiency(100, 0);
            emit Link(tokenId, plane, 100, 0);
        }
        
        return tokenId;
    }

    /// @notice Adds addresses to a token's whitelist.
    ///         Once an address has been whitelisted, it cannot be removed.
    ///         If no whitelisted addresses are supplied, the token's whitelist is disabled.
    ///         Requires a value sent greater than or equal to the larger of the token's incremental value or the minimum incremental value. 
    /// @param  tokenId The token ID to update.
    /// @param  whitelisted An array of addresses to whitelist.
    function restrictToken(uint256 tokenId, address[] memory whitelisted) external payable {
        _checkApproved(tokenId);

        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        // Determine if the token should be restricted based on provided addresses.
        bool restrict = whitelisted.length > 0;
        bool wasRestricted = t.restricted;
        if (restrict != wasRestricted) {
            t.restricted = restrict;
            if (restrict) {
                // Switching into restricted mode requires paying at least the higher
                // of token.incrementalValue or the global minimum.
                uint256 required = t.incrementalValue > _incrementalValue ? t.incrementalValue : _incrementalValue;
                if (value < required) revert InsufficientFunds(required);
                emit Restrict(tokenId);
            }
            // If restricting is being disabled, no additional payment is required.
        }

        // Add any sent Ether as token value (even if toggle did not change).
        _createValue(tokenId, value);
        
        // Loop through the provided addresses and whitelist them.
        mapping(address => TokenContribution) storage contributions = t.contributions;
        uint256 accountIndex;
        uint256 accountsLength = whitelisted.length;
        for (accountIndex; accountIndex < accountsLength; accountIndex++) {
            address account = whitelisted[accountIndex];
            // Whitelisting is a one-way operation: once set, it is never cleared.
            contributions[account].whitelisted = true;
            emit Whitelist(account, tokenId);
        }        
    }

    /// @notice Updates an existing Token. Message sender must be approved for this Token.
    ///         In order for the incremental value or activation threshold to be updated, the token must have 0 charge.
    ///         In order for the token data or URI to be updated a value must be sent of at least the token's incremental value plus the minimum incremental value.
    ///         In addition, for a data or URI update, a transfer of 1000 coins per coin rate for each.
    /// @dev    Data for the Planar Tokens must have a length of at least 4 in order to preserve the affinity bonus functionality.
    ///         Planar tokens must also maintain an Incrmental Value and Activation Threshold of 0.
    /// @param  tokenId The ID of the Token to Update
    /// @param  incrementalValue The Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a greater than the Minimum Incremental Value
    /// @param  activationThreshold The number of Coins required for the Token to be Activated
    /// @param  data The updated Data for the Token (only updated if length > 0)
    /// @param  uri The updated URI for the Token (only updated if length > 0) 
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data, string calldata uri) external payable nonReentrant {
        _checkApproved(tokenId);
        
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        // If token already has charge, its incremental value and activation threshold cannot be modified.
        if (t.charge > 0) {
            require(t.incrementalValue == incrementalValue && t.activationThreshold == activationThreshold, "DIGIL: Cannot Update Charged Token");
        }

        if (_isPlanar(tokenId)) {
            require(incrementalValue == 0, "DIGIL: Invalid Incremental Value");
            require(activationThreshold == 0, "DIGIL: Invalid Activation Threshold");
        }

        // Require minimum incremental value
        if (incrementalValue > 0) {
            require(incrementalValue >= _incrementalValue, "DIGIL: Invalid Incremental Value");
        }

        // Update last activity
        t.lastActivity = block.timestamp;

        bool overwriteUri = bytes(uri).length > 0;
        if (overwriteUri) {
            // Updating the URI requires a coin fee to ensure token integrity.
            _coinsFromSender(_coinRate * 1000);
        }

        bool overwriteData = bytes(data).length > 0;
        if (overwriteData) {
            if (_isPlanar(tokenId)) {
                // Planar tokens must preserve at least 4 bytes of data to keep affinity encoding valid.
                require(bytes(data).length >= 4, "DIGIL: Invalid Data Length");
            }
            // Updating data requires a coin fee to preserve the token's original intention.
            _coinsFromSender(_coinRate * 1000);
        }

        // Calculate the minimum required Ether value based on whether data or URI is updated.
        uint256 minimumValue = (overwriteData || overwriteUri) ? (t.incrementalValue + _incrementalValue) : 0;
        if (msg.value < minimumValue) revert InsufficientFunds(minimumValue);

        // Add any sent Ether to the contract's distribution (not directly to this token).
        _addValue(msg.value);

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
    ///         any temporary buff applied via {buffLinks}. If no buff is active or the buff
    ///         has expired, this returns the stored base efficiency.
    /// @param  linkId The destination token ID (or plane ID) for this link.
    /// @param  t The source token storage reference.
    /// @return effectiveBase The effective base efficiency for this link, including any active buff, capped at uint8::max (255).
    function _effectiveBaseEfficiency(uint256 linkId, Token storage t) internal view returns (uint256 effectiveBase) {
        uint8 base = t.linkEfficiency[linkId].base;

        uint8 bonus = _activeBuffBonus(t);
        if (bonus == 0) {
            // No active buff
            return base;
        }

        uint256 boosted = uint256(base) + uint256(bonus);
        if (boosted > type(uint8).max) {
            boosted = type(uint8).max;
        }

        return boosted;
    }

    /// @dev    Internal function to charge an active token.
    /// @param  contributor The address making the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The number of coin units used.
    /// @param  activeCoins Additional coin units applied as active charge.
    /// @param  value The native Ether value (in wei) sent.
    /// @param  link A flag indicating if the charge is coming via a link.
    function _chargeActiveToken(address contributor, uint256 tokenId, uint256 coins, uint256 activeCoins, uint256 value, bool link) internal {
        Token storage t = _tokens[tokenId];

        uint256[] storage links = t.links;
        uint256 linksLength = links.length;

        // If there are no links or the charge is directly linked, add the coins to the active charge.
        if (linksLength == 0 || link) {
            
            uint256 totalIncoming = coins + activeCoins;
            
            // Check for Amplifier Buff
            // activeCoins here includes Affinity Bonuses from upstream
            if (t.buff.amplification > 0 && block.timestamp < t.buff.expiresAt) {
                // Calculate bonus: (Total * Multiplier) / 100
                uint256 boost = (totalIncoming * t.buff.amplification) / 100;
                totalIncoming += boost;
            }
            
            t.activeCharge += totalIncoming;
            emit ActiveCharge(tokenId, totalIncoming);

        } else {    
            // Distribute the value and coins among all linked tokens.
            uint256 linkedValue = value / linksLength; // Distribute ETH evenly  
            uint256 linkIndex;
            for (linkIndex; linkIndex < linksLength; linkIndex++) {                
                uint256 linkId = links[linkIndex];

                // Calculate linkedCoins based on base efficiency applied to the coins split evenly amongst the links
                // Effective base efficiency (including any temporary buff)
                uint256 linkedCoins = (coins * _effectiveBaseEfficiency(linkId, t)) / linksLength / 100;
                // Calculate bonusCoins based on affinity bonus applied to the full coins
                uint256 bonusCoins = (coins * t.linkEfficiency[linkId].affinityBonus) / 100;

                // If nothing at all is going to this link, skip it.
                if (linkedCoins == 0 && bonusCoins == 0 && linkedValue == 0) {
                    continue;
                }

                // Attempt to charge the linked token.
                bool charged = _ownerOf(linkId) != address(0) && _chargeToken(contributor, linkId, linkedCoins, bonusCoins, linkedValue, true);
                if (charged) {
                    value -= linkedValue; // Subtract the successfully distributed value
                } else {
                    // If linked token could not be charged, add the coins to the source's active charge.
                    t.activeCharge += linkedCoins;
                    emit ActiveCharge(tokenId, linkedCoins);
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
            c.value = 0;
            c.exists = false;
            c.distributed = false;
            // NOTE: c.whitelisted is intentionally preserved across epochs.
        }
    }

    /// @dev    Internal function to process token charging.
    /// @param  contributor The address contributing to the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The coin units used.
    /// @param  activeCoins Additional active coin units.
    /// @param  value The native Ether value (in wei) provided.
    /// @param  link Flag indicating if the charge is via a link.
    /// @return True if the token was successfully charged.
    function _chargeToken(address contributor, uint256 tokenId, uint256 coins, uint256 activeCoins, uint256 value, bool link) internal returns(bool) {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        bool batchOperationInProgress = t.distributionIndex > 0;
        if (link && batchOperationInProgress) {
            // Linked charges quietly fail while a batch op is in progress,
            // so upstream links can skip this target without reverting the whole call chain.
            return false;
        } else {
            // Direct charges are not allowed during batch operations.
            require(!batchOperationInProgress, "DIGIL: Batch Operation In Progress");
        }

        // Proxy contributions require a value contribution
        if (!link && contributor != _msgSender()) {
            // Determine the minimum required value for a proxy contribution.
            uint256 requiredValue = t.incrementalValue > 0 ? t.incrementalValue : _incrementalValue;

            // For direct proxy calls, we revert if funds are insufficient.
            if (value < requiredValue) revert InsufficientFunds(requiredValue);
        }
        
        TokenContribution storage c = t.contributions[contributor];
        _touchContribution(t, c);
        
        // Check if contribution is allowed (if restricted, the contributor must be whitelisted).
        bool whitelisted = !t.restricted || c.whitelisted;

        uint256 incrementalValue = t.incrementalValue;
        // Calculate minimum required value for the given number of coins (scaled by _coinMultiplier).
        uint256 minimumValue = incrementalValue * coins / _coinMultiplier;

        // Determine minimum coins required; if incrementalValue is nonzero, derive from provided value.
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
            if (!whitelisted || minimumCoins > (coins + activeCoins) || value < minimumValue) {
                 // Fail softly so upstream link logic can continue.
                return false;
            }
            // In linked charging, use the entire provided value.
            minimumValue = value;
            if (coins < minimumCoins) {
                // Top up `coins` logically from the activeCoins budget.
                coins = minimumCoins;
            }

        } else {

            // For non-linked charging, enforce whitelisting and minimum value.
            require(whitelisted, "DIGIL: Restricted");    

            if (value < minimumValue) revert InsufficientFunds(minimumValue);
            
            // Transfer coins from the contributor to this contract.
            _coinsFromSender(coins);

        }

        // Update last activity
        t.lastActivity = block.timestamp;

        // If the token is active, route the charge accordingly.
        if (t.active) {

            _chargeActiveToken(contributor, tokenId, coins, activeCoins, value, link);

        } else {

            // For inactive tokens, record contributions.
            if (!c.exists) {
                // New contributor for this epoch
                c.exists = true;
                t.contributors.push(contributor);
            }

            if (c.distributed) {
                // Existing contributor already received a distribution in this epoch, reset
                c.distributed = false;
                c.charge = 0;
                c.value = 0;
            }    

            // Add to contribution value
            if (minimumValue > 0) {
                c.value += minimumValue;
                emit Contribute(contributor, tokenId, minimumValue);
            }
            
            // If excess value was provided, add the surplus to the token's value.
            if (value > minimumValue) {
                t.value += value - minimumValue;
                emit ContributeValueAs(contributor, tokenId, value - minimumValue);
            }

            // If excess coins were provided, add the surplus to active charge.
            if (coins > minimumCoins) {
                t.activeCharge += coins - minimumCoins;
                emit ActiveCharge(tokenId, coins - minimumCoins);
                // Only `minimumCoins` count toward this token's charge for distribution.
                coins = minimumCoins;
            }

            c.charge += coins;
            t.charge += coins;
            emit Charge(contributor, tokenId, coins, _msgSender());

        }

        return true;
    }

    /// @notice Charges a token.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The number of coin units to use.
    /// @return True if the token was successfully charged.
    function chargeToken(uint256 tokenId, uint256 coins) external payable returns(bool) {
        // Delegate to chargeTokenAs.
        return chargeTokenAs(_msgSender(), tokenId, coins);
    }

    /// @notice Charges a token on behalf of another contributor.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    /// @dev    Requires that the contributor is not blacklisted and the token exists.
    /// @param  contributor The address contributing the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The coin units used in the charge.
    /// @return True if the token was successfully charged.
    function chargeTokenAs(address contributor, uint256 tokenId, uint256 coins) public payable nonReentrant returns(bool) {
        _notOnBlacklist(contributor);
        _checkTokenExists(tokenId);
        
        require(contributor != address(0), "DIGIL: Invalid Contributor");
        require(coins >= _coinMultiplier, "DIGIL: Insufficient Charge");
        return _chargeToken(contributor, tokenId, coins, 0, msg.value, false);
    }

    // Token Distribution and Discharge

    /// @dev    Internal function to process token distributions in batches.
    /// @param  tokenId The token ID undergoing distribution.
    /// @param  discharge Flag indicating if this is a discharge operation.
    /// @return True if the distribution process is complete.
    function _distribute(uint256 tokenId, bool discharge) internal returns(bool) {
        Token storage t = _tokens[tokenId];

        // Update distribution charge if token charge is higher.
        uint256 dCharge = t.distributionCharge;
        if (t.charge >= dCharge) {
            // Capture all remaining charge into distributionCharge once per cycle.
            dCharge = t.distributionCharge = t.charge;
            t.charge = 0;
        }

        // Update distribution value if token value is higher.
        uint256 dValue = t.distributionValue;
        if (t.value >= dValue) {
            // Similarly, capture all remaining value into distributionValue.
            dValue = t.distributionValue = t.value;
        }

        // Calculate incremental value per coin unit for distribution.
        // Use full-precision ratio so we never over-distribute dValue when dCharge
        // is not an exact multiple of _coinMultiplier.
        uint256 incrementalValue = dCharge > 0 ? (dValue * _coinMultiplier) / dCharge : 0;

        uint256 dIndex = t.distributionIndex;

        uint256 distribution;
        
        // Process contributions in batches defined by _batchSize
        // If discharge is true (distribution phase of dischargeToken), use batchSize. If false (e.g., activateToken), use batchSize * 2.
        uint256 cEndIndex = dIndex + (discharge ? _batchSize : _batchSize * 2);
        if (cEndIndex > t.contributors.length) {
            cEndIndex = t.contributors.length;
        }
        
        for (dIndex; dIndex < cEndIndex; dIndex++) {
            address contributor = t.contributors[dIndex];
            if (contributor == address(0)) {
                break;
            }

            TokenContribution storage contribution = t.contributions[contributor];
            bool distributed = contribution.distributed;
            // Mark as processed for this epoch; `distributed` prevents double payouts.
            contribution.distributed = true;

            // If a contract token is associated, mark it recallable.
            ContractToken storage contractToken = _contractTokens[contributor][tokenId];
            if (contractToken.tokenId != 0) {

                contractToken.recallable = true;

            } else if (!distributed) {

                if (discharge) {

                    // For discharge, return contributed value back to the contributor.
                    _addValue(contributor, contribution.value, contribution.charge);

                } else {

                    // Otherwise, accumulate distribution for the token owner.
                    distribution += contribution.value;
                    // A percentage of the token's intrinsic value is sent to the contributor
                    uint256 distributableTokenValue = incrementalValue * contribution.charge / _coinMultiplier;

                    // Ensure we do not subtract more than exists in t.value due to rounding.
                    // If distributable is > t.value, we just take what is left.
                    if (distributableTokenValue > t.value) {
                        distributableTokenValue = t.value;
                    }

                    t.value -= distributableTokenValue;
                    _addDistributedValue(contributor, distributableTokenValue);

                }

            }
        }

        if (cEndIndex == t.contributors.length) {

            // Finalize distribution if all contributors have been processed.
            t.distributionIndex = 0;
            t.distributionCharge = 0;
            t.distributionValue = 0;

            uint256 tValue = t.value;
            t.value = 0;

            if (discharge) {

                // For discharge, return any undistributed value to the token owner.
                _addDistributedValue(ownerOf(tokenId), tValue);

            } else {

                if (dCharge > 0) {
                    t.activeCharge += dCharge;
                    emit ActiveCharge(tokenId, dCharge);
                }

                // Create a distribution for the token owner and include remaining value.
                _addDistributedValue(ownerOf(tokenId), distribution + tValue);
                
            }

            return true;
            
        } else {

            // Update the distribution index for further batch processing.
            t.distributionIndex = dIndex;

            if (!discharge && distribution > 0) {
                // If not discharging, flush partial owner distribution each batch to avoid overflow.
                _addDistributedValue(ownerOf(tokenId), distribution);
            }
            return false;
        }
    }

    /// @notice Discharges an existing token, processing its contributions and value
    ///         based on its active state. Any remaining `activeCharge` is redistributed
    ///         into its links, with optional retention if the ANCHORED buff is active.
    /// @dev    This is a multi-step batch operation that may need to be called
    ///         multiple times to complete:
    ///         - On the first call of a discharge cycle (`t.discharging == false`),
    ///           the caller must send ETH at least equal to
    ///             max(_incrementalValue, t.incrementalValue) * max(1, links.length).
    ///         - Subsequent calls in the same cycle (`t.discharging == true`) do not
    ///           require additional ETH.
    ///         - If the token is INACTIVE: contributed value/charge are returned to
    ///           contributors; remaining intrinsic value is sent to the owner.
    ///         - If the token is ACTIVE: contributors receive value proportional to
    ///           their charge; owner receives the remainder as per {_distribute}.
    ///         - After distribution, remaining `activeCharge` is redistributed into
    ///           linked tokens:
    ///             * If ANCHORED is active, 25% is retained and 75% redistributed.
    ///             * Otherwise, 100% is redistributed based on base link efficiencies.

    /// @param  tokenId The token ID to discharge.
    /// @return True if discharge is complete.
    function dischargeToken(uint256 tokenId) external payable nonReentrant returns (bool) {
        _checkApproved(tokenId);
        
        Token storage t = _tokens[tokenId];
        require(t.charge > 0 || t.value > 0 || t.activeCharge > 0 || t.discharging, "DIGIL: Nothing to Discharge");
        require(!t.activating, "DIGIL: Activation In Progress");
        
        // On the first call of a discharge cycle, enforce the fee.
        if (!t.discharging) {
            // Determine the required minimum value for discharge, scaled by number of links.
            // This scales the "fee" with the complexity of the token's graph.
            uint256 required = (_incrementalValue > t.incrementalValue ? _incrementalValue : t.incrementalValue) * (t.links.length > 0 ? t.links.length : 1);
            if (msg.value < required) revert InsufficientFunds(required);
        }
        
        // Update last activity
        t.lastActivity = block.timestamp;

        if (msg.value > 0) {
            _addValue(msg.value);
        }

        // Mark the token as being in a discharge operation.
        t.discharging = true;
        
        // Run the distribution phase based on mode (may require multiple calls).
        bool distributionComplete = _distribute(tokenId, !t.active);
        if (!distributionComplete) {
            emit Discharge(tokenId, false);
            return false;
        }

        /// Redistribute this sigil's remaining activeCharge into its links
        uint256 ac = t.activeCharge;
        if (ac > 0) {
            uint256 retained = 0;
            // Check flag AND expiry
            if ((t.buff.flags & ANCHORED) != 0 && block.timestamp < t.buff.expiresAt) {
                retained = ac / (AFFINITY_REDUCTION * AFFINITY_REDUCTION); // Keep 25%
                ac -= retained;                                            // Distribute the rest
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
                        linkedToken.activeCharge += share;

                        emit ActiveCharge(linkId, share);
                    }

                    // Any rounding remainder (from integer division) is implicitly lost,
                    // remaining as untracked power in the contract balance.
                }
            }

            // Clear the original token's active charge.
            t.activeCharge = 0;
        }

        // At this point, all contributions for the current epoch have been fully processed.
        // Clear the contributor list and logically reset all contribution state via epoch bump.
        address[] storage contributors = t.contributors;
        // Reset the length to 0 using assembly
        assembly {
            sstore(contributors.slot, 0)
        }

        // If a contract token is attached, it should no longer be recallable after a full discharge.
        // Preserve its address as a placeholder contributor so a future activation/distribution round
        // can re-enable recallability.
        if (t.contractTokenAddress != address(0)) {
            ContractToken storage contractToken = _contractTokens[t.contractTokenAddress][tokenId];
            if (contractToken.tokenId != 0) {
                contractToken.recallable = false;
                t.contributors.push(t.contractTokenAddress);
            }
        }

        // Advance the contribution epoch so all existing TokenContribution entries
        // are treated as reset the next time they are touched.
        t.contributionEpoch += 1;

        // Clear any buffs
        delete t.buff;

        // Clear flag on completion
        t.discharging = false;
        emit Discharge(tokenId, true);
        return true;
    }

    /// @notice Activates a token if its charge meets the activation threshold.
    /// @dev    This is a multi-step batch operation:
    ///         - If the token has the PRIMED buff active, the effective activation
    ///           threshold is halved.
    ///         - On the first call, the token must be inactive and have
    ///           `t.charge >= effectiveThreshold`.
    ///         - Subsequent calls in the same activation cycle are allowed while
    ///           `t.activating == true`, without re-checking the charge.
    ///         Activation uses {_distribute} with `discharge = false` and may require
    ///         multiple transactions to complete for large contributor sets.
    /// @return True if the token activation is complete.
    function activateToken(uint256 tokenId) external nonReentrant returns(bool) {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];

        uint256 threshold = t.activationThreshold;
        // Check flag AND ensure buff hasn't expired
        if ((t.buff.flags & PRIMED) != 0 && block.timestamp < t.buff.expiresAt) {
            // Temporarily halve the required activation threshold when PRIMED.
            threshold /= AFFINITY_REDUCTION;
        }

        require(t.active == false && (t.charge >= threshold || t.activating), "DIGIL: Token Cannot Be Activated");
        require(!t.discharging, "DIGIL: Discharge In Progress");

        // Update last activity
        t.lastActivity = block.timestamp;
        
        // Set flag at start
        t.activating = true;
        bool distributionComplete = _distribute(tokenId, false);
        
        if (!distributionComplete) {
            emit Activate(tokenId, false);
            return false;
        }
        
        t.active = true;
        // Clear flag on completion
        t.activating = false;
        emit Activate(tokenId, true);
        return true;
    }

    /// @dev    Applies thematic "bleed" to a token's active charge:
    ///         - If the token is STABILIZED (bit 1 set in `buff.flags`), consume that
    ///           protection and skip the bleed for this call.
    ///         - Otherwise, compute a loss of 1 / AFFINITY_REDUCTION of the current
    ///           `activeCharge`, subtract it, and leave the lost units as untracked
    ///           power in the contract’s ERC20 balance.
    ///         With the current configuration (AFFINITY_REDUCTION = 2), an unprotected
    ///         call burns ~50% of the token's activeCharge.
    /// @param  t The token whose activeCharge will be reduced.
    function _applyActiveChargeBleed(Token storage t) internal {
        uint256 ac = t.activeCharge;
        if (ac == 0) return;

        if ((t.buff.flags & STABILIZED) != 0) {
            // Consume the protection, but skip the bleed
            t.buff.flags &= ~STABILIZED; // Clear flag
            return;
        }

        uint256 lost = ac / AFFINITY_REDUCTION; // e.g., half
        t.activeCharge = ac - lost;
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
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];
        require(t.active == true && t.charge == 0, "DIGIL: Token Cannot Be Deactivated");
        // Make sure the token isn't currently being discharged or activated
        require(t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        // Update last activity
        t.lastActivity = block.timestamp;

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
    ///         - If this is a brand new link:
    ///             * First link on the token: 25% of base cost.
    ///             * Second link on the token: 50% of base cost.
    ///           All subsequent new links pay full base cost.
    /// @param  efficiency  The link efficiency (percentage).
    /// @param  linkCount   The total number of links on the token *after* this call.
    /// @param  isNewLink   True if this is the first time linking to `linkId`.
    /// @param  buffBonus   The current active buff bonus (0 if inactive).
    /// @return cost The ERC20 coin amount to charge (in full token units, scaled by
    ///              the underlying ERC20 decimals), after applying early-link
    ///              discounts and any active buff discount.
    function _linkCoinCost(uint8 efficiency, uint256 linkCount, bool isNewLink, uint8 buffBonus) internal view returns (uint256 cost) {
        // Existing scaling logic: efficiency plus triangular escalation.
        uint256 linkScale = 200 / linkCount;
        uint256 eAdj = efficiency > linkScale ? efficiency - linkScale : 0;
        uint256 baseCost = (efficiency + (eAdj * (eAdj + 1) / 2)) * _coinRate;

        // If a buff is active, discount the base cost.
        // Formula: cost = cost * 100 / (100 + bonus)
        if (buffBonus > 0) {
            baseCost = baseCost * 100 / (100 + uint256(buffBonus));
        }
        
        cost = baseCost;

        if (isNewLink) {
            // `linkCount` includes the newly added link, so:
            //  - existingCount == 0 => this is the 1st link
            //  - existingCount == 1 => this is the 2nd link
            uint256 existingCount = linkCount - 1;
            if (existingCount == 0) {
                // First link: 25% of base cost
                cost = baseCost / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
            } else if (existingCount == 1) {
                // Second link: 50% of base cost
                cost = baseCost / AFFINITY_REDUCTION;
            }
        }
    }

        /// @notice Links two tokens together to facilitate coin generation or transfers.
    ///         A token can have no more than 10 links.
    ///         Requires a value greater than or equal to the sum of the source and
    ///         destination token's incremental value. Any value contributed is split
    ///         between and added to the source and destination token.
    ///         The coin cost for linking scales with efficiency and number of links,
    ///         with early-link discounts:
    ///             - First new link on a token: 25% of base cost.
    ///             - Second new link on a token: 50% of base cost.
    ///             - Subsequent links: full base cost.
    ///         An efficiency of 1 indicates ~1% transfer; 100 indicates 100%; 200
    ///         indicates 200%, etc.
    /// @dev    A token's foundational Plane link (its "element") can only be set at
    ///         creation (in {createToken}) and is immutable. This function is for
    ///         creating peer-to-peer links between Digils, not for changing the
    ///         foundational Plane. The affinity bonus for this link is calculated
    ///         based on the foundational Planes (planar links) of the two Digils
    ///         involved. Cannot link directly to foundational planar tokens
    ///         (IDs 0–PLANAR_MAX_ID).
    /// @param  tokenId    The source token ID.
    /// @param  linkId     The destination token ID to link to.
    /// @param  efficiency The efficiency of the link (percentage based).
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) external payable nonReentrant {
        _checkTokenExists(tokenId);
        _checkApproved(tokenId);
        _checkTokenExists(linkId);

        Token storage t = _tokens[tokenId];

        require(t.links.length < MAX_LINKS, "DIGIL: Too Many Links");

        // Existing link state
        uint8 baseEfficiency = t.linkEfficiency[linkId].base;

        // Validate link: tokens must be different, destination must be non-planar,
        // and the new efficiency must strictly improve on the current base.
        require(tokenId != linkId && linkId > PLANAR_MAX_ID && efficiency > baseEfficiency, "DIGIL: Invalid Link" );

        // If a temporary buff is active, charge additional activeCharge
        // for adding a new outgoing link while the buff is still running.
        _chargeBuffForNewLink(t);

        Token storage d = _tokens[linkId];
        require(!d.restricted || d.contributions[_msgSender()].whitelisted, "DIGIL: Restricted");

        uint256 value = msg.value;
        uint256 requiredValue = t.incrementalValue + d.incrementalValue;
        if (value < requiredValue) revert InsufficientFunds(requiredValue);

        // Update last activity
        t.lastActivity = block.timestamp;

        // Split the contributed value evenly between the two tokens.
        uint256 half = value / 2;
        _createValue(tokenId, half);
        _createValue(linkId, value - half);

        // Update affinity bonus in storage, if applicable.
        _updateLinkAffinity(t, d, linkId, efficiency);

        // Update base efficiency in storage.
        t.linkEfficiency[linkId].base = efficiency;

        // If this is a brand-new link (no previous baseEfficiency), add it to the list.
        bool isNewLink = (baseEfficiency == 0);
        if (isNewLink) {
            t.links.push(linkId);
        }

        // For the event and cost, read back the final stored efficiency.
        LinkEfficiency storage eff = t.linkEfficiency[linkId];
        emit Link(tokenId, linkId, eff.base, eff.affinityBonus);

        // Determine if a buff is currently active for the a discount.
        uint8 buffBonus = _activeBuffBonus(t);

        // Compute and charge coin cost, including early-link and active buff discounts.
        uint256 coinCost = _linkCoinCost(efficiency, t.links.length, isNewLink, buffBonus);

        _coinsFromSender(coinCost);
    }

    /// @dev    Computes the activeCharge cost of a buff given:
    ///         - bonus: temporary bonus effectiveness (0–100)
    ///         - duration: duration in whole minutes
    ///         - linkCount: number of affected links
    ///         Uses the calibrated cost model:
    ///             cost ≈ bonus * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR
    ///         and enforces a minimum cost of `_coinRate` whenever the raw cost
    ///         is non-zero, so tiny buffs are never effectively free.
    /// @param  bonus The temporary buff bonus (0–100).
    /// @param  duration The duration in minutes.
    /// @param  linkCount The number of outgoing links affected.
    /// @return cost The activeCharge cost in coin units.
    function _buffCost(uint256 bonus, uint256 duration, uint256 linkCount) internal view returns (uint256 cost) {
        if (bonus == 0 || duration == 0 || linkCount == 0) {
            return 0;
        }

        cost = bonus * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR;

        // Enforce "minimum cost = _coinRate" rule for any non-zero buff.
        if (cost > 0 && cost < _coinRate) {
            cost = _coinRate;
        }
    }

    /// @dev    Charges additional activeCharge when a new link is created while a temporary
    ///         buff is active for the given token. Uses the remaining buff duration
    ///         and the same cost model as {buffLinks}, but per-link (linkCount = 1).
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
        
        // Calculate Magnitude based on efficiency + optional attunement + optional amplification
        uint256 magnitude = buff.efficiencyBonus + buff.amplification;
        if (buff.attunement > 0) {
            // Attunement acts like an extra BUFF_COST chunk of magnitude.
            magnitude += BUFF_COST;
        }
        // Check flags from storage
        uint8 flags = buff.flags;
        if ((flags & ANCHORED) != 0) {
            // Anchoring acts like an extra BUFF_COST chunk of magnitude.
            magnitude += BUFF_COST;
        }
        if ((flags & PRIMED) != 0) {
            // Priming acts like an extra BUFF_COST chunk of magnitude.
            magnitude += BUFF_COST;
        }

        uint256 cost = _buffCost(magnitude, remainingMinutes, 1);
        if (cost == 0) {
            return;
        }

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

        // Base Bonus Calculation
        if (s[1] == d[0] || s[2] == d[0]) {
            // If the source has strong affinity with the destination, provide a bonus of 2x the efficiency.
            _bonus = uint256(efficiency) * AFFINITY_BOOST;
        } else if (sourceId == destinationId || sourceId > 16) {
            // If the source is the same as the destination,
            // or the source is an ethereal plane (aether, world), provide a bonus of 1x the efficiency.
            _bonus = uint256(efficiency);
        } else if (s[3] == d[0]) {
            // If the source has weak affinity with the destination, provide a bonus of .5x the efficiency.
            _bonus = uint256(efficiency) / AFFINITY_REDUCTION;
        }

        // No Bonus
        if (_bonus == 0) {
            return _bonus;
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

    /// @dev    Updates the affinity bonus for a link between two tokens based on
    ///         their foundational Planes. If either token has no foundational
    ///         plane, or the planes are out of the planar range, this is a no-op.
    ///         The computed bonus is only applied if it exceeds the existing
    ///         stored `affinityBonus` for this link.
    /// @param  t          The source token storage reference.
    /// @param  d          The destination token storage reference.
    /// @param  linkId     The destination token ID (same as `d`'s ID).
    /// @param  efficiency The current link efficiency (percentage).
    function _updateLinkAffinity( Token storage t, Token storage d, uint256 linkId, uint8 efficiency) internal {
        // Both tokens must have a foundational plane as their first link.
        if (t.links.length == 0 || d.links.length == 0) {
            return;
        }

        uint256 sourcePlane = t.links[0];
        uint256 destinationPlane = d.links[0];

        // Calculate Natural Bonus
        uint256 bestBonus = _affinityBonus(sourcePlane, destinationPlane, efficiency);

        // Check if buff is active and attunement is valid
        if (t.buff.attunement > 0 && block.timestamp < t.buff.expiresAt) {
            uint256 attunementBonus = _affinityBonus(t.buff.attunement, destinationPlane, efficiency);
            
            // Keep the larger of the two
            if (attunementBonus > bestBonus) {
                bestBonus = attunementBonus;
            }
        }

        if (bestBonus == 0) {
            return;
        }

        LinkEfficiency storage eff = t.linkEfficiency[linkId];
        if (bestBonus > eff.affinityBonus) {
            // Only ever increase stored affinityBonus; never reduce an existing one.
            eff.affinityBonus = bestBonus;
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
        _checkTokenExists(linkId);
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];

        // Disallow unlinking foundational planes (IDs 0..PLANAR_MAX_ID)
        // so the token's elemental identity cannot be removed.
        require(linkId > PLANAR_MAX_ID && t.linkEfficiency[linkId].base > 0, "DIGIL: Invalid Link");

        // Update last activity
        t.lastActivity = block.timestamp;

        // Reset the link efficiency for the specified link.
        t.linkEfficiency[linkId] = LinkEfficiency(0, 0);

        uint256[] storage links = t.links;
        uint256 linkIndex;
        uint256 linksLength = links.length;
        // Loop through links to remove the specified link.
        for (linkIndex; linkIndex < linksLength; linkIndex++) {
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

    /// @dev Returns the active buff bonus, or 0 if expired/inactive.
    function _activeBuffBonus(Token storage t) internal view returns (uint8) {
        // If inactive, expiresAt is 0, and timestamp < 0 is false.
        if (block.timestamp < t.buff.expiresAt) {
            return t.buff.efficiencyBonus;
        }
        return 0;
    }

    /// @notice Temporarily buffs all outgoing links from a token by adding a bonus
    ///         on top of each link's base efficiency, and offers discounts on linking and stabilization costs.
    /// @dev    The buff:
    ///         - Consumes `activeCharge` from the token as a cost.
    ///         - Applies the same `efficiencyBonus` to all outgoing links.
    ///         - Lasts for `duration` minutes (capped at 24 hours).
    ///         The cost is computed via {_buffCost} using:
    ///             cost ≈ magnitude * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR
    ///         where:
    ///             magnitude = efficiencyBonus + amplification
    ///                 + BUFF_COST for attunement (if any)
    ///                 + BUFF_COST for ANCHORED (if set)
    ///                 + BUFF_COST for PRIMED (if set),
    ///             duration is in minutes, and linkCount is the number of outgoing links
    ///             (or 1 if there are none).
    ///         A non-zero buff always costs at least `_coinRate` units of activeCharge.
    /// @param  tokenId The ID of the token whose links are to be buffed.
    /// @param  efficiencyBonus The temporary bonus (0–100) added to each link's base efficiency.
    /// @param  attunement      Planar ID to mimic for affinity (1-18, or 0 for none).
    /// @param  amplification   Percentage multiplier applied to incoming charge (0-100, or 0 for none).
    /// @param  flags           Bitmask of buff flags to enable:
    ///                         - 2 = ANCHORED (retain portion of activeCharge on discharge)
    ///                         - 4 = PRIMED (temporary reduced activation threshold)
    ///                         The STABILIZED bit (1) cannot be set here and is preserved
    ///                         from previous calls to {stabilizeToken}.
    /// @param  duration        The buff duration in minutes (1–1440).
    function buffToken(uint256 tokenId, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint8 flags, uint256 duration) external nonReentrant {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];

        require(t.active, "DIGIL: Token Not Active");

        require((efficiencyBonus > 0 && efficiencyBonus <= MAX_BUFF_BONUS) || (attunement > 0 && attunement <= PLANAR_MAX_ID) || (amplification > 0 && amplification <= MAX_BUFF_BONUS), "DIGIL: Invalid Buff");
        
        require(duration > 0 && duration <= MAX_BUFF_DURATION_MIN, "DIGIL: Invalid Buff Duration");

        // Calculate Magnitude
        {
            uint256 magnitude = uint256(efficiencyBonus) + uint256(amplification);
            if (attunement > 0)             magnitude += BUFF_COST;
            if ((flags & ANCHORED) != 0)    magnitude += BUFF_COST;
            if ((flags & PRIMED) != 0)      magnitude += BUFF_COST;

            // Calculate link count (min 1)
            uint256 linkCount = t.links.length;
            if (linkCount == 0) linkCount = 1;

            // Cost is proportional to magnitude, duration, and number of affected links.
            uint256 cost = _buffCost(magnitude, duration, linkCount);
            if (t.activeCharge < cost) revert InsufficientActiveCharge(cost);
            t.activeCharge -= cost;
        }

        // Compute expiry timestamp in seconds
        uint256 expiry = block.timestamp + (duration * 1 minutes);
        t.buff.expiresAt = uint64(expiry);
        t.buff.efficiencyBonus = efficiencyBonus;
        t.buff.amplification = amplification;
        t.buff.attunement = attunement;

        // Preserve any existing STABILIZED protection; caller cannot toggle bit 0 via buffToken.
        t.buff.flags = flags | (t.buff.flags & STABILIZED);

        emit Buff(tokenId, efficiencyBonus, attunement, amplification, flags, duration);
    }

    /// @notice Pays ERC20 Coins to protect the token from "bleed" during the next
    ///         deactivation or recall.
    /// @dev    Base Cost is 25% of the current activeCharge, payable in Coins.
    ///         (This allows the user to pay a smaller fee to save the 50% bleed).
    ///         If a buff is active, cost is further reduced by: cost * 100 / (100 + bonus).
    ///         Sets the `stabilized` flag to true.
    /// @param  tokenId The token ID to stabilize.
    function stabilizeToken(uint256 tokenId) external nonReentrant {
        _checkApproved(tokenId);

        Token storage t = _tokens[tokenId];
        require((t.buff.flags & STABILIZED) == 0, "DIGIL: Already Stabilized");
        
        uint256 ac = t.activeCharge;
        require(ac > 0, "DIGIL: No Charge to Stabilize");

        // Calculate Insurance Cost.
        // Bleed is 50% (ac / 2). We set insurance cost to 25% (ac / 4).
        // This makes paying the fee mathematically rational.
        // We enforce a minimum floor of 100 * coinRate to prevent dust spam.
        uint256 floor = 100 * _coinRate;
        uint256 calculatedCost = ac / (AFFINITY_REDUCTION * AFFINITY_REDUCTION);
        
        uint256 cost = calculatedCost > floor ? calculatedCost : floor;

        // Apply Discount if Buff is active
        uint8 bonus = _activeBuffBonus(t);
        if (bonus > 0) {
            // Active buffs reduce stabilization cost: cost *= 100 / (100 + bonus).
            cost = cost * 100 / (100 + uint256(bonus));
        }

        // Transfer Coins from the user to the contract
        _coinsFromSender(cost);

        // Set protection
        t.buff.flags |= STABILIZED;
        
        emit Stabilize(tokenId);
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
    function overchargeToken(uint256 tokenId, uint256 coins) external payable nonReentrant {
        _checkApproved(tokenId);

        require(coins >= _coinMultiplier, "DIGIL: Insufficient Charge");

        Token storage t = _tokens[tokenId];

        // Do not interfere with batch operations or activation/discharge flows.
        require(t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");
        require(!t.activating && !t.discharging, "DIGIL: Lifecycle In Progress");
        require(t.active, "DIGIL: Token Not Active");

        // Use the greater of the token's incremental value or the global minimum.
        uint256 iv = t.incrementalValue > 0 ? t.incrementalValue : _incrementalValue;

        // Premium cost: 2x the normal ETH-per-coin-unit rate.
        // `coins` is in "coin units" (scaled by _coinMultiplier), so we normalize by _coinMultiplier.
        uint256 required = (iv * coins * AFFINITY_BOOST) / _coinMultiplier;
        if (msg.value < required) revert InsufficientFunds(required);

        // Update last activity timestamp.
        t.lastActivity = block.timestamp;

        // All ETH becomes contract-level value / system fuel.
        _addValue(msg.value);

        // Grant raw activeCharge to the token.
        t.activeCharge += coins;
        emit ActiveCharge(tokenId, coins);
    }

}