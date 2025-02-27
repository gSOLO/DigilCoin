// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.22;

// Import OpenZeppelin contracts for standard ERC721 functionality, ownership, safe transfers, counters, ERC20 interfacing, and reentrancy protection.
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Digil Token (NFT)
/// @author gSOLO
/// @notice NFT contract used for the creation, charging, and activation of Digital Sigils on the Ethereum Blockchain
/// @custom:security-contact security@digil.co.in
contract DigilToken is ERC721, Ownable, IERC721Receiver, ReentrancyGuard {
    // Usings
    using Strings for uint256;  // Allow uint256 values to be converted to strings

    // Immutable contract-level variables set during construction
    address private immutable _this;            // This contract's address
    IERC20 private immutable _coins;            // ERC20 token used for coin transfers within the contract
    uint256 private immutable _coinMultiplier;  // Multiplier used for coin calculation
    
    // Coin rate and bonus rate
    uint256 private _coinRate;                                  // Mutable coin rate for various operations
    uint256 private constant BONUS_RATE_DIVISOR = 100;          // Factor for determining bonus coins when value is added

    // Constants for bonus interval and multiplier
    uint256 private constant BONUS_INTERVAL = 15 minutes;       // Allows 100% of bonus coins to be retrieved every 25 hours 
    uint256 private constant VALUE_MULTIPLIER = 1000 gwei;      // Simplify minimum values

    // Configuration values for incremental and transfer values
    uint256 private _incrementalValue = 100 * VALUE_MULTIPLIER; // Minimum incremental value in wei
    uint256 private _transferValue = 95 * VALUE_MULTIPLIER;     // Value transferred during charge operations

    // Batch operations limiter
    uint16 private constant DEFAULT_BATCH_SIZE = 10;            // Default size for batch operations (350)
    uint16 private _batchSize = DEFAULT_BATCH_SIZE;             // Base value for maximum number of distribution or discharge operations per transaction

    // Define the inactivity period for rescuing tokens
    uint256 private constant INACTIVITY_PERIOD = 365 days;      // Allows tokens with eth tied to them to be recovered after a period of time

    // Max link and affinity bonus scale
    uint256 private constant MAX_LINKS = 10;                    // Maximum number of links a token can have
    uint256 private constant AFFINITY_BOOST = 2;                // Factor used in determining affinity bonus increases
    uint256 private constant AFFINITY_REDUCTION = 2;            // Divisor used in determining affinity bonus reductions

    // Mappings for token data, blacklisted addresses, distributions, and contract tokens
    mapping(uint256 => Token) private _tokens;                                      // Mapping from token ID to its associated Token data
    mapping(address => bool) private _blacklisted;                                  // Mapping for addresses that are blacklisted (opted-out)
    mapping(address => Distribution) private _distributions;                        // Mapping for pending distributions of coins and value per address
    mapping(address => mapping(uint256 => bool)) private _contractTokenExists;      // Mappings to track ERC721 tokens received from external contracts
    mapping(address => mapping(uint256 => ContractToken)) private _contractTokens;  // Mappings to track ERC721 tokens and if they're recallable

    /// @dev Structure to hold pending coin and value distributions, and the time of the last distribution
    struct Distribution {
        uint256 time;   // Timestamp of the last distribution or withdrawal
        uint256 coins;  // Pending coins to be distributed
        uint256 value;  // Pending Ether value to be distributed
    }

    /// @dev Structure to hold contribution data for a token
    struct TokenContribution {
        uint256 charge;     // Coins contributed to the token's charge
        uint256 value;      // Ether value contributed
        bool exists;        // Indicates if the contributor exists (has contributed)
        bool distributed;   // Indicates if the contribution has been distributed
        bool whitelisted;   // Indicates if the contributor is whitelisted
    }

    /// @dev Structure to represent a contract token relationship (the relationship between an external ERC721 token and a Digil Token)
    struct ContractToken {
        uint256 tokenId;    // ID of the external ERC721 token
        bool recallable;    // Indicates if the token can be recalled
    }

    /// @dev Structure to represent link efficiency between tokens
    struct LinkEfficiency {
        uint8 base;             // Base efficiency percentage for coin transfer
        uint256 affinityBonus;  // Additional bonus based on plane affinity
    }

    /// @dev Structure to hold detailed token information
    struct Token {
        uint256 charge;             // Accumulated charge from direct contributions
        uint256 distributionCharge; // Charge reserved for distributions
        uint256 activeCharge;       // Charge accumulated from active token operations and links
        uint256 value;              // Intrinsic value accumulated by the token
        uint256 distributionValue;  // Value reserved for distributions
        uint256 incrementalValue;   // Incremental value used for charging computations (value required per coin to charge)
        
        uint256 dischargeIndex;     // Current index for batch discharge processing
        uint256 distributionIndex;  // Current index for batch distribution processing

        uint256 activationThreshold;// Required charge to activate the token
        uint256 lastActivity;       // Timestamp of the last significant action
        
        uint256[] links;            // Array of token IDs or plane IDs the token is linked to
        mapping(uint256 => LinkEfficiency) linkEfficiency;  // Mapping of link ID to its efficiency settings
        
        address[] contributors;     // List of contributor addresses that have charged this token
        mapping(address => TokenContribution) contributions;// Mapping from contributor to their contribution details
        
        bytes data;                 // Arbitrary data stored with the token
        string uri;                 // Token metadata URI

        bool active;                // Indicates if the token is active
        bool activating;            // Indicates if the token is currently being activated
        bool discharging;           // Indicates if the token is currently being discharged
        bool restricted;            // Indicates if contributions are restricted to whitelist
    }

    // Counter for token IDs
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

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

    /// @notice Emitted when a new token is created.
    /// @param  tokenId The ID of the token that was created
    event Create(uint256 indexed tokenId);

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
    event Charge(address indexed addr, uint256 indexed tokenId, uint256 coins);

    /// @notice Emitted when an active token is charged.
    /// @param  tokenId The ID of the token being charged
    /// @param  coins The number of coins the token was charged with
    event ActiveCharge(uint256 indexed tokenId, uint256 coins);

    /// @notice Emitted when a token is discharged or is in the process of being discharged.
    /// @dev    Check with tokenData to get an idea of its completion progress
    /// @param  tokenId The ID of the token that was or is being discharged
    /// @param  complete Indicates whether the process was completed
    event Discharge(uint256 indexed tokenId, bool complete);

    /// @notice Emitted when a token is linked to a plane.
    /// @param  tokenId The ID of the token that was linked
    /// @param  linkId The ID of the plane that the token was linked to
    event Link(uint256 indexed tokenId, uint256 indexed linkId);

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
    event ContributeValue(address indexed addr, uint256 indexed tokenId, uint256 value);

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
    /// @param  coins The number of coins sent
    error CoinTransferFailed(uint256 coins);

    /// @notice Contract constructor. Initializes state variables, mints initial tokens, and sets up planar data.
    /// @param  initialOwner The address that will own the contract initially.
    /// @param  coins The address of the ERC20 token used as coins.
    /// @param  coinDecimals The number of decimals for the coin token.
    constructor(address initialOwner, address coins, uint256 coinDecimals) ERC721("Digil Token", "DIGIL") Ownable(initialOwner) {
        _this = address(this);
        _coins = IERC20(coins);
        _coinMultiplier = 10 ** coinDecimals;
        _coinRate = 100 * _coinMultiplier;
        _coins.approve(_this, type(uint256).max);
        
        string memory baseURI = "https://digil.co.in/token/";
        
        // Define an array of plane names.
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

        // Define planar data for each plane
        // 0:   identifier
        // 1:   strong affinity bonus
        // 2:   strong affinity bonus
        // 3:   weak affinity bonus
        // 4:   delimiter
        // 5-9: simplified name
        bytes[21] memory data;
        data[0] =  "----|";      // null
        data[1] =  "xrot|X";     // void
        data[2] =  "roxy|K.N ";  // karma
        data[3] =  "orxy|K.S";   // kaos
        data[4] =  "faly|X.S";   // fire
        data[5] =  "afly|X.E";   // air
        data[6] =  "ewny|X.N";   // earth
        data[7] =  "weny|X.W";   // water
        data[8] =  "im-y|X.NW";  // ice
        data[9] =  "lfay|X.NE";  // lightning
        data[10] = "mi-y|X.NNE"; // metal
        data[11] = "newy|X.NNW"; // nature
        data[12] = "hrdy|X.SE";  // harmony
        data[13] = "dohy|X.SW";  // discord
        data[14] = "podt|K.W";   // entropy
        data[15] = "grht|K.E";   // negentropy/exergy
        data[16] = "kpgt|K";     // magick/kosmos
        data[17] = "txy-|K.X";   // aether
        data[18] = "yxt-|X.R";   // external reality
        data[19] = "----|.XR";   // extended reality
        data[20] = "----|.ILXR"; // digil reality
        
        // Unchecked block used to mint the initial tokens without overflow checks (safe here due to known bounds)
        unchecked {
            uint256 tokenId;
            // Loop until 20 tokens are minted.
            while (tokenId < 20) {
                tokenId = _tokenIdCounter.current();
                _tokenIdCounter.increment();

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

        // Mark the first token as restricted.
        _tokens[0].restricted = true;
    }

    /// @dev    Transfers ownership of the contract and planar tokens to a new account
    /// @param  newOwner the address to transfer ownership to
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        uint256 tokenId;
        for (tokenId; tokenId < 20; tokenId++) {
            address currentOwner = ownerOf(tokenId);
            _approve(_this, tokenId, address(0), false);
            _transfer(currentOwner, newOwner, tokenId);
            _approve(address(0), tokenId, address(0), false);
        }
        
        super.transferOwnership(newOwner);
    }

    // Configuration

    /// @dev    Update contract configuration.
    /// @param  coins Used to determine a number of values:
    ///                     Maximum number of bonus Coins a user can withdraw.
    ///                     Number of Coins required to Update a Token URI.
    ///                     Number of Coins required to Link a Token.
    ///                     Number of Coins required to Opt-Out.
    /// @param  incrementalValue The minimum value (in wei) used to Charge, Activate a Token, update a Token URI
    /// @param  transferValue The value (in wei) to be distributed when a Token is Activated as a percentage of the minimum value
    /// @param  batchSize The multiplier used for batch size for distribute and discharge calls that can be made per transaction 
    function configure(uint256 coins, uint256 incrementalValue, uint256 transferValue, uint16 batchSize) public onlyOwner {
        // Validate configuration parameters.
        require(coins > 0 && transferValue <= incrementalValue && transferValue >= (incrementalValue * 9 / 10) && batchSize> 0, "DIGIL: Invalid Configuration");

        _coins.approve(_this, type(uint256).max); // Re-approve coins to allow maximum transfers.
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
        if (!_transferCoinsFrom(_msgSender(), _this, coins)) revert CoinTransferFailed(coins);
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

    /// @notice Returns any pending coin and value distributions for the sender, not inculding bonus coins.
    /// @return coins The number of coin units pending transferred to the sender.
    /// @return value The native Ether value pending transferred to the sender.
    /// @return time The time of the sender's last distribution.
    function pendingDistribution(address addr) public view returns(uint256 coins, uint256 value, uint256 time) {
        Distribution storage distribution = _distributions[addr];
        return (distribution.coins, distribution.value, distribution.time);
    }

    /// @notice Withdraws any pending coin and value distributions for the sender, and optionally provides bonus coins.
    ///         If no coins or tokens are owned by the user, bonus coins can be rewarded by donating to the contract.
    ///         With default values it amounts to 1000000000000000 wei ((100 * 1000 gwei) * (100 * 10 ** 18) /  (10 ** 18) / 10))
    /// @dev    Bonus coins are calculated based on the time since the last distribution.
    /// @return coins The number of coin units transferred to the sender.
    /// @return value The native Ether value transferred to the sender.
    function withdraw() public payable nonReentrant returns(uint256 coins, uint256 value) {
        address addr = _msgSender();
        // Ensure the sender is not blacklisted.
        _notOnBlacklist(addr);

        Distribution storage distribution = _distributions[addr];

        // Calculate required donation for bonus eligibility
        uint256 donationThreshold = (_incrementalValue * _coinRate / _coinMultiplier) / 10;

        // Add donated Ether to the contract's balance
        if (msg.value > 0) {
            _addValue(msg.value);
        }

        // Retrieve and reset the pending value and coin distributions.
        value = distribution.value;
        distribution.value = 0;
        coins = distribution.coins;
        distribution.coins = 0;

        // Award bonus coins if user holds tokens or donates enough Ether
        if (balanceOf(addr) > 0 || _coins.balanceOf(addr) > 0 || msg.value >= donationThreshold) {
            uint256 lastBonusTime = distribution.time;            
            distribution.time = block.timestamp;
            uint256 bonus = (block.timestamp - lastBonusTime) / BONUS_INTERVAL * _coinMultiplier;
            // Limit the bonus to the current coin rate.
            coins += (bonus < _coinRate ? bonus : _coinRate);
        }

        // Transfer any pending native value to the sender.
        if (value > 0) {            
            Address.sendValue(payable(addr), value);
        }

        // Attempt to transfer coins from this contract to the sender; if it fails, reassign the pending coins.
        if (coins > 0 && !_transferCoinsFrom(_this, addr, coins)) {
            distribution.coins = coins;
            coins = 0;
        }

        return (coins, value);
    }

    // Add Value and Distributions

    /// @dev    Internal helper that adds native value to the contract’s balance.
    /// @param  value The amount of Ether (in wei) to add.
    function _addValue(uint256 value) private {
        if (value > 0) {
            _addValue(_this, value, 0);
            emit ContractDistribution(value);
        }
    }

    /// @dev    Internal function to add native value and coins to a given address's pending distribution.
    /// @param  addr The address to credit the distribution.
    /// @param  value The amount of native value (in wei) to add.
    /// @param  coins The number of coin units to add.
    function _addValue(address addr, uint256 value, uint256 coins) private {
        if (value > 0 || coins > 0) {
            Distribution storage distribution = _distributions[addr];
            if (value > 0) {
                distribution.value += value;
            }
            if (coins > 0) {
                distribution.coins += coins;
            }
            if (addr != _this) {
                emit PendingDistribution(addr, coins, value);
            }
        }
    }

    /// @dev    Internal function that calculates and assigns distribution amounts between the contract and a specified address.
    ///         Adds a percentage of the value to be distributed to the contract, and the rest to the address specified.
    ///         Adds a number of bonus coins based on the value to be distributed to "reward" the contributor for contributing value to the contract.
    ///         An example 1 eth distribution with a incremental value of 100 and a transfer value of 95 would:
    ///             Add 0.05 eth to the contract.
    ///             Add 0.95 eth to the address specified.
    ///             Add 10000 Coins to the address specified.
    /// @param  addr The address to credit the distribution.
    /// @param  value The amount of native value (in wei) to add.
    function _addDistributedValue(address addr, uint256 value) internal {
        // Calculate the incremental distribution multiplier.
        uint256 incrementalDistribution = value / _incrementalValue;
        // Add the non-transferred portion of the value to the contract's distribution.
        _addValue(incrementalDistribution * (_incrementalValue - _transferValue));
        // Calculate bonus coins based on the incremental distribution.
        uint256 bonusCoins = _coinRate / BONUS_RATE_DIVISOR * incrementalDistribution;
        // Add the transferred value and coins (including bonus) to the specified address.
        _addValue(addr, incrementalDistribution * _transferValue, bonusCoins);
    }

    /// @dev    Internal function that adds contributed value to a token.
    /// @param  tokenId The token to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function _createValue(uint256 tokenId, uint256 value) internal {
        _tokens[tokenId].value += value;
        emit ContributeValue(tokenId, value);
    }

    /// @notice Creates Value for a Token using the contract's available balance.
    /// @dev    Requires that the contract has enough value; deducts the amount from the contract distribution.
    /// @param  tokenId The token ID to which the value is added.
    /// @param  value The amount of value (in wei) to add.
    function createValue(uint256 tokenId, uint256 value) public payable onlyOwner {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.dischargeIndex == 0 && t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        _addValue(msg.value);

        // Ensure the contract has sufficient available value.
        if (_distributions[_this].value < value) revert InsufficientFunds(value);

        _distributions[_this].value -= value;

        _createValue(tokenId, value);
    }

    // ERC721 Updates

    /// @dev    Overrides the ERC721 _update function to perform additional checks and actions.
    /// @param  to The address receiving the token.
    /// @param  tokenId The token ID being transferred.
    /// @param  auth Authorization address.
    /// @return The previous owner address.
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        // Ensure neither the sender nor the recipient are blacklisted.
        _notOnBlacklist(_msgSender());
        _notOnBlacklist(to);
        // Perform the standard ERC721 token update (transfer).
        address from = super._update(to, tokenId, auth);
        
        Token storage t = _tokens[tokenId];

        // Update last activity
        t.lastActivity = block.timestamp;

        // Automatically whitelist the new owner for this token.
        t.contributions[to].whitelisted = true;
        return from;
    }

    /// @dev    Modifier that ensures the caller is approved to operate on the token.
    /// @param  tokenId The token ID for which approval is required.
    modifier approved(uint256 tokenId) {
        address account = _msgSender();
        _notOnBlacklist(account);
        require(_isAuthorized(ownerOf(tokenId), account, tokenId), "DIGIL: Not Approved");
        _;
    }

    /// @dev    Modifier that ensures an operator is not blacklisted.
    /// @param  account The address to check.
    modifier operatorEnabled(address account) {
        _notOnBlacklist(account);
        _;
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
    function setOptStatus(bool optOut) public payable {
        address account = _msgSender();
        require(_blacklisted[account] != optOut, "DIGIL: No Change");

         // Calculate required minimum funds for opting in.
        uint256 required = _incrementalValue * _coinRate / _coinMultiplier;        
        if (msg.value < required) revert InsufficientFunds(required);
        
        // Add the sent value to the contract’s distribution.
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
    /// @param  tokenId The token ID to rescue.
    /// @param  to The address to which the token is transferred.
    function rescueToken(uint256 tokenId, address to) external tokenExists(tokenId) onlyOwner {
        Token storage t = _tokens[tokenId];

        address currentOwner = ownerOf(tokenId);
        // Conditions for rescue:
        // - Owner is blacklisted OR
        // - Token is inactive for the specified period AND meets ETH-related criteria
        require(
            _blacklisted[currentOwner] || 
            (
                block.timestamp >= t.lastActivity + INACTIVITY_PERIOD && 
                (
                    t.value > 0 || 
                    (t.active == false && t.contributors.length > 0 && t.charge > 0 && t.incrementalValue > 0)
                )
            ),
            "DIGIL: Token Cannot Be Rescued"
        );

        // Remove approvals before transfer.
        _approve(_this, tokenId, address(0), false);
        // Transfer the token from the blacklisted or inactive address.
        _transfer(currentOwner, to, tokenId);
        // Clear approvals post-transfer.
        _approve(address(0), tokenId, address(0), false);
    }

    // ERC721 Receiver

    /// @notice Handles the receipt of an external ERC721 token.
    /// @dev    When an ERC721 token is sent to this contract, creates a new Digil Token representing the token received.
    ///         The incremental value of the token is set to the minimum non-zero incremental value, with an activation threshold of 0.
    ///         The account (ERC721 contract address), and external token ID are appended to the Token URI as a query string.
    ///         Any data sent is stored with the Token and forwarded during Safe Transfer when {recallToken} is called.
    ///         If the ERC721 received is a Digil Token it is linked to the new token.
    /// @param  operator The address which initiated the transfer.
    /// @param  from The previous owner of the ERC721 token.
    /// @param  tokenId The token ID of the external ERC721.
    /// @param  data Optional data forwarded with the transfer.
    /// @return bytes4 Selector confirming receipt.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external nonReentrant operatorEnabled(operator) operatorEnabled(from) returns (bytes4) {
        address account = _msgSender();
        // Ensure that this external token has not been received before.
        require(!_contractTokenExists[account][tokenId], "DIGIL: Contract Token Already Exists");
        _contractTokenExists[account][tokenId] = true;

        // Create a new internal token with zero incremental value and activation threshold.
        uint256 internalId = _createToken(from, 0, 0, data);        
        _contractTokens[account][internalId].tokenId = tokenId;

        Token storage t = _tokens[internalId];
        // Append the ERC721 contract address and tokenId as query parameters to the token URI.
        t.uri = string(abi.encodePacked(tokenURI(internalId), "?account=", Strings.toHexString(uint160(account), 20), "&tokenId=", tokenId.toString()));
        // Add the ERC721 contract address as a contributor.
        t.contributors.push(account);

        uint256 minimumIncrementalValue = _incrementalValue;
        // If the external token is a Digil Token, link the tokens.
        if (account == _this) {
            Token storage d = _tokens[tokenId];
            d.links.push(internalId);
            d.linkEfficiency[internalId] = LinkEfficiency(uint8(100 / d.links.length), 0);
            uint256 dIncrementalValue = d.incrementalValue;
            if (minimumIncrementalValue < dIncrementalValue) {
                minimumIncrementalValue = dIncrementalValue;
            }
        }
        // Set the incremental value for the newly created token.
        t.incrementalValue = minimumIncrementalValue;
        
        return this.onERC721Received.selector;
    }

    /// @notice Recalls an external contract token attached to a Digil token.
    ///         The token the Contract Token is attached to must have been activated.
    ///         Requires a value sent greater than or equal to the token's incremental value.
    /// @param  account The address of the external ERC721 contract.
    /// @param  tokenId The internal Digil token ID whose attached contract token is to be recalled.
    function recallToken(address account, uint256 tokenId) public nonReentrant approved(tokenId) {
        ContractToken storage contractToken = _contractTokens[account][tokenId];
        require(contractToken.recallable, "DIGIL: Contract Token Is Not Recallable");

        uint256 contractTokenId = contractToken.tokenId;
        // Reset the contract token mapping.
        contractToken.tokenId = 0;
        contractToken.recallable = false;

        // Safely transfer the external ERC721 token back to the current owner of the Digil token.
        ERC721(account).safeTransferFrom(_this, ownerOf(tokenId), contractTokenId, _tokens[tokenId].data);

        _contractTokenExists[account][contractTokenId] = false;
    }

    // Token Information

    /// @dev    Modifier to ensure a token exists (i.e. has a non-zero owner).
    /// @param  tokenId The token ID to check.
    modifier tokenExists(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "DIGIL: Token Does Not Exist");
        _;
    }

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
    function tokenURI(uint256 tokenId) public view virtual override tokenExists(tokenId) returns (string memory) {
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
    function tokenCharge(uint256 tokenId) public view tokenExists(tokenId) returns(uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold) {
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
    /// @return links The number of links associated with the token.
    /// @return contributors The number of contributor addresses.
    /// @return dischargeIndex The current discharge index.
    /// @return distributionIndex The current distribution index.
    /// @return data Arbitrary data stored with the token.
    function tokenData(uint256 tokenId) public view tokenExists(tokenId) returns(bool active, bool activating, bool discharging, bool restricted, uint256 links, uint256 contributors, uint256 dischargeIndex, uint256 distributionIndex, bytes memory data) {
        Token storage t = _tokens[tokenId]; 
        return (t.active, t.activating, t.discharging, t.restricted, t.links.length, t.contributors.length, t.dischargeIndex, t.distributionIndex, t.data);
    }

    // Token Creation

    /// @dev    Internal function to create a new token.
    /// @param  creator The address that the token is being created for.
    /// @param  incrementalValue The incremental value associated with the token.
    /// @param  activationThreshold The activation threshold for the token.
    /// @param  data Optional data to store with the token.
    /// @return tokenId The newly created token ID.
    function _createToken(address creator, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data) internal returns(uint256) {      
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        emit Create(tokenId);
        
        // Mint the token to the creator.
        _mint(creator, tokenId);

        Token storage t = _tokens[tokenId];

        // Set last activity
        t.lastActivity = block.timestamp;
        
        // Set the token parameters.
        t.incrementalValue = incrementalValue;
        t.activationThreshold = activationThreshold;

        t.data = data;

        return tokenId;
    }

    /// @notice Creates a new token.
    ///         Linking to a plane other than the 4 elemental planes (4-7; fire, air, earth, water) requires a Coin transfer:
    ///             void, karmic, and kaotic planes (1-3; void, karma, kaos): 5x Coin Rate
    ///             paraelemental planes (8-11; ice, lightning, metal, nature): 1x Coin Rate
    ///             energy planes (12-16; harmony, discord, entropy, exergy, magick): 25x Coin Rate
    ///             ethereal planes (17-18; aether, world): 100x Coin Rate
    /// @param  incrementalValue The incremental value (in wei) to be required with each coin used for charging.
    /// @param  activationThreshold The number of coins required for token activation.
    /// @param  restricted Whether the token is restricted to whitelisted addresses.
    /// @param  plane The chosen planar token (numeric index) to link with.
    /// @param  data Optional data to store with the token.
    /// @return tokenId The ID of the newly created token.
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes calldata data) public payable returns(uint256) {
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
        if (msg.value > 0) {
            _createValue(tokenId, msg.value);
        }

        // If a plane is specified (plane > 0), process the coin fee and link the token to the plane.
        if (plane > 0) {
            require(plane <= 18, "DIGIL: Invalid Plane");
            // Different fee structures based on plane index.
            if (plane < 4) {
                _coinsFromSender(_coinRate * 5);
            } else if (plane > 16) {
                _coinsFromSender(_coinRate * 100);
            } else if (plane > 11) {
                _coinsFromSender(_coinRate * 25);
            } else if (plane > 7) {
                _coinsFromSender(_coinRate);
            }
            // Record the plane link.
            t.links.push(plane);
            t.linkEfficiency[plane] = LinkEfficiency(100, 0);
            emit Link(tokenId, plane);
        }
        
        return tokenId;
    }

    /// @notice Adds addresses to a token's whitelist.
    ///         Once an address has been whitelisted, it cannot be removed.
    ///         If no whitelisted addresses are supplied, the token's whitelist is disabled.
    ///         Requires a value sent greater than or equal to the larger of the token's incremental value or the minimum incremental value. 
    /// @param  tokenId The token ID to update.
    /// @param  whitelisted An array of addresses to whitelist.
    function restrictToken(uint256 tokenId, address[] memory whitelisted) public payable approved(tokenId) {
        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.dischargeIndex == 0 && t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        // Determine if the token should be restricted based on provided addresses.
        bool restrict = whitelisted.length > 0;
        bool wasRestricted = t.restricted;
        if (restrict != wasRestricted) {
            t.restricted = restrict;
            if (restrict) {
                uint256 required = t.incrementalValue > _incrementalValue ? t.incrementalValue : _incrementalValue;
                if (value < required) revert InsufficientFunds(required);
                emit Restrict(tokenId);
            }
        }

        // Add any sent Ether as token value.
        if (value > 0) {
            _createValue(tokenId, value);
        }

        // Loop through the provided addresses and whitelist them.
        mapping(address => TokenContribution) storage contributions = t.contributions;
        uint256 accountIndex;
        uint256 accountsLength = whitelisted.length;
        for (accountIndex; accountIndex < accountsLength; accountIndex++) {
            address account = whitelisted[accountIndex];
            contributions[account].whitelisted = true;
            emit Whitelist(account, tokenId);
        }        
    }

    /// @notice Updates an existing Token. Message sender must be approved for this Token.
    ///         In order for the incremental value or activation threshold to be updated, the token must have 0 charge.
    ///         In order for the token data or URI to be updated a value must be sent of at least the token's incremental value plus the minimum incremental value.
    ///         In addition, for a data update, a transfer of 10000 coins per coin rate; for a URI update, 100000 coins per coin rate.
    /// @param  tokenId The ID of the Token to Update
    /// @param  incrementalValue The Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a multiple of the Minimum Incremental Value
    /// @param  activationThreshold The number of Coins required for the Token to be Activated (decimals excluded)
    /// @param  data The updated Data for the Token (only updated if length > 0)
    /// @param  uri The updated URI for the Token (only updated if length > 0) 
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data, string calldata uri) public payable approved(tokenId) {
        Token storage t = _tokens[tokenId];
        // Make sure the token isn't currently being discharged or activated
        require(t.dischargeIndex == 0 && t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");

        activationThreshold *= _coinMultiplier;

        // If token already has charge, its incremental value and activation threshold cannot be modified.
        if (t.charge > 0) {
            require(t.incrementalValue == incrementalValue && t.activationThreshold == activationThreshold, "DIGIL: Cannot Update Charged Token");
        }

        // Update last activity
        t.lastActivity = block.timestamp;

        bool needCoins = owner() != _msgSender();

        bool overwriteData = bytes(data).length > 0;
        if (overwriteData && needCoins) {
            // For data updates (if not owner), transfer a fee of 1000 coin rate.
            _coinsFromSender(_coinRate * 1000);
        }

        bool overwriteUri = bytes(uri).length > 0;
        if (overwriteUri && needCoins) {
            // For URI updates (if not owner), transfer a fee of 10000 coin rate.
            _coinsFromSender(_coinRate * 10000);
        }

        // Calculate the minimum required Ether value based on whether data or URI is updated.
        uint256 minimumValue = (overwriteData || overwriteUri) ? (t.incrementalValue + _incrementalValue) : 0;
        if (msg.value < minimumValue) revert InsufficientFunds(minimumValue);

        // Add any sent Ether to the contract's distribution.
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

            t.activeCharge += coins + activeCoins;
            emit ActiveCharge(tokenId, coins + activeCoins);

        } else {    
            // Distribute the value and coins among all linked tokens.
            uint256 linkedValue = value / linksLength;   
            uint256 linkIndex;
            for (linkIndex; linkIndex < linksLength; linkIndex++) {                
                uint256 linkId = links[linkIndex];
                // Calculate linkedCoins based on base efficiency applied to the coins split evenly amongst the links
                uint256 linkedCoins = coins / linksLength / 100 * t.linkEfficiency[linkId].base;
                // Calculate bonusCoins based on affinity bonus applied to the full coins
                uint256 bonusCoins = coins / 100 * t.linkEfficiency[linkId].affinityBonus;
                // Attempt to charge the linked token.
                bool charged = _ownerOf(tokenId) != address(0) && _chargeToken(contributor, linkId, linkedCoins, bonusCoins, linkedValue, true);
                if (charged) {
                    value -= linkedValue;
                } else {
                    // If linked token could not be charged, add the coins to its active charge.
                    t.activeCharge += linkedCoins;
                    emit ActiveCharge(linkId, linkedCoins);
                }
            }
        }

        // Any remaining value is added to the owner's pending distribution.
        if (value > 0) {
            _addDistributedValue(ownerOf(tokenId), value);
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
        bool batchOperationInProgress = t.dischargeIndex > 0 || t.distributionIndex > 0;
        if (link && batchOperationInProgress) {
            return false;
        } else {
            require(!batchOperationInProgress, "DIGIL: Batch Operation In Progress");
        }
        
        // Update last activity
        t.lastActivity = block.timestamp;

        TokenContribution storage c = t.contributions[contributor];
        // Check if contribution is allowed (if restricted, the contributor must be whitelisted).
        bool whitelisted = !t.restricted || c.whitelisted;

        uint256 incrementalValue = t.incrementalValue;
        // Calculate minimum required value for the given number of coins.
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
            // If the contributor isn't whitelisted, or not enough coins are supplied by the link, the token will not be charged
            if (!whitelisted || minimumCoins > (coins + activeCoins)) {
                return false;
            }
            // In linked charging, use the entire provided value.
            minimumValue = value;

        } else {

            // For non-linked charging, enforce whitelisting and minimum value.
            require(whitelisted, "DIGIL: Restricted");    

            if (value < minimumValue) revert InsufficientFunds(minimumValue);
            
            // Transfer coins from the contributor.
            _coinsFromSender(coins);

        }

        // If the token is active, route the charge accordingly.
        if (t.active) {

            _chargeActiveToken(contributor, tokenId, coins, activeCoins, value, link);

        } else {

            // For inactive tokens, record contributions.
            if (!c.exists) {
                // New contributor
                c.exists = true;
                t.contributors.push(contributor);
            }

            if (c.distributed) {
                // Existing contributor already recieved a distribution, reset 
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
                emit ContributeValue(contributor, tokenId, value - minimumValue);
            }

            // If excess coins were provided, add the surplus to active charge.
            if (coins > minimumCoins) {
                t.activeCharge += coins - minimumCoins;
                emit ActiveCharge(tokenId, coins - minimumCoins);
                coins = minimumCoins;
            }

            c.charge += coins;
            t.charge += coins;
            emit Charge(contributor, tokenId, coins);

        }

        return true;
    }

    /// @notice Charges a token.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The number of coin units to use.
    /// @return True if the token was successfully charged.
    function chargeToken(uint256 tokenId, uint256 coins) public payable returns(bool) {
        // Multiply the coin amount by coin decimals and delegate to chargeTokenAs.
        return chargeTokenAs(_msgSender(), tokenId, coins);
    }

    /// @notice Charges a token on behalf of another contributor.
    ///         Requires a value sent greater than or equal to the token's incremental value for each coin.
    /// @dev    Requires that the contributor is not blacklisted and the token exists.
    /// @param  contributor The address contributing the charge.
    /// @param  tokenId The token ID to charge.
    /// @param  coins The coin units used in the charge.
    /// @return True if the token was successfully charged.
    function chargeTokenAs(address contributor, uint256 tokenId, uint256 coins) public payable operatorEnabled(contributor) tokenExists(tokenId) returns(bool) {
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
            dCharge = t.distributionCharge = t.charge;
            t.charge = 0;
        }

        // Update distribution value if token value is higher.
        uint256 dValue = t.distributionValue;
        if (t.value >= dValue) {
            dValue = t.distributionValue = t.value;
        }

        // Calculate incremental value per coin unit for distribution.
        uint256 incrementalValue = dCharge >= _coinMultiplier ? dValue / (dCharge / _coinMultiplier) : 0;

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
                    // A percentage of the token's intrinsic value is sent to the contributor along with a bonus coin
                    uint256 distributableTokenValue = incrementalValue * contribution.charge / _coinMultiplier;
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

                // Create a distribution for the token owner and add remaining value to the contract.
                _addDistributedValue(ownerOf(tokenId), distribution);
                _addValue(tValue);
                
            }

            return true;
            
        } else {

            // Update the distribution index for further batch processing.
            t.distributionIndex = dIndex;

            if (!discharge && distribution > 0) {
                // If not discharging, create a distribution for the token owner.
                _addDistributedValue(ownerOf(tokenId), distribution);
            }
            return false;
        }
    }

    /// @notice Discharges an existing token and resets all contributions.
    ///         If the token has been activated: Any contributed value that has not yet been distributed will be distributed to owner.
    ///         If the token has not been activated: Any contributed value that has not yet been distributed will be returned to its contributors, any additional token value to its owner.
    ///         Requires a value sent greater than or equal to the larger of the token's incremental value or the minimum incremental value, scaled by the number of links.
    /// @param  tokenId The token ID to discharge.
    /// @return True if discharge is complete.
    function dischargeToken(uint256 tokenId) public payable approved(tokenId) returns (bool) {
        Token storage t = _tokens[tokenId];
        require(t.charge > 0 || t.value > 0 || t.discharging, "DIGIL: Nothing to Discharge");
        require(!t.activating, "DIGIL: Activation In Progress");
        
        // Determine the required minimum value for discharge, scaled by number of links.
        uint256 required = (_incrementalValue > t.incrementalValue ? _incrementalValue : t.incrementalValue) * (t.links.length > 0 ? t.links.length : 1);
        if (msg.value < required) revert InsufficientFunds(required);

        // Update last activity
        t.lastActivity = block.timestamp;

        _addValue(msg.value);

        // Set flag at start
        t.discharging = true;
        
        uint256 dIndex = t.dischargeIndex;
        
        // Distribute based on mode
        bool distributionComplete = dIndex > 0 || _distribute(tokenId, !t.active);
        if (!distributionComplete) {
            emit Discharge(tokenId, false);
            return false;
        }

        address contractTokenAddress;

        uint256 cLength = t.contributors.length;
        uint256 cEndIndex = dIndex + (_batchSize * 2);
        if (cEndIndex > cLength) {
            cEndIndex = cLength;
        }
        // Process in batches defined by _batchSize.
        for (dIndex; dIndex < cEndIndex; dIndex++) {
            address contributor = t.contributors[dIndex];
            if (contributor == address(0)) {
                break;
            }
            
            TokenContribution storage contribution = t.contributions[contributor];
            // Reset contribution data.
            contribution.charge = 0;
            contribution.value = 0;
            contribution.exists = false;
            contribution.distributed = false;

            // For contract tokens, adjust recallable status.
            if (t.dischargeIndex == 0) {
                ContractToken storage contractToken = _contractTokens[contributor][tokenId];
                if (contractToken.tokenId != 0) {
                    contractTokenAddress = contributor;
                    contractToken.recallable = false;
                }
            }
        }

        if (cEndIndex == cLength) {
            
            // If batch completes
            t.dischargeIndex = 0;
            delete t.contributors;
            emit Discharge(tokenId, true);

        } else {

            // Partial discharge
            t.dischargeIndex = dIndex;
            emit Discharge(tokenId, false);
            return false;

        }

        if (contractTokenAddress != address(0)) {
            // If applicable, re-add the contract token address as a contributor.
            t.contributors.push(contractTokenAddress);
        }

        // Clear flag on completion
        t.discharging = false;
        return true;
    }

    /// @notice Activates a token if its charge meets the activation threshold.
    ///         Requires the token have a charge greater than or equal to the token's activation threshold or its distribution charge exceeds the threshold.
    /// @param  tokenId The token ID to activate.
    /// @return True if the token activation is complete.
    function activateToken(uint256 tokenId) public approved(tokenId) returns(bool) {
        Token storage t = _tokens[tokenId];
        require(t.active == false && (t.charge >= t.activationThreshold || t.activating), "DIGIL: Token Cannot Be Activated");

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

    /// @notice Deactivates an active token.
    ///         Requires the token have zero charge, and a value sent greater than or equal to the token's incremental value.
    /// @param  tokenId The ID of the token to deactivate
    function deactivateToken(uint256 tokenId) public payable approved(tokenId) {
        Token storage t = _tokens[tokenId];
        require(t.active == true && t.charge == 0, "DIGIL: Token Cannot Be Deactivated");
        // Make sure the token isn't currently being discharged or activated
        require(t.dischargeIndex == 0 && t.distributionIndex == 0, "DIGIL: Batch Operation In Progress");
        
        if (msg.value < t.incrementalValue) revert InsufficientFunds(t.incrementalValue);

        // Update last activity
        t.lastActivity = block.timestamp;

        if (msg.value > 0) {
            _addValue(msg.value);
        }

        t.active = false;
        emit Deactivate(tokenId);
    }

    // Token Links

    /// @notice Links two tokens together to facilitate coin generation or transfers. A token can have no more than 10 links.
    ///         Requires a value greater than the sum of the source and destination token's incremental value.
    ///         Any value contributed is split between and added to the source and destination token.
    ///         Requires a summation of coins at the coin rate depending on the number of existing links.
    ///         An efficiency of 1 is meant to indicate a coin generation or transfer of 1%; 100 would be 100%; 200 would be 200%; et. cetera.
    /// @param  tokenId The source token ID.
    /// @param  linkId The destination token ID to link to.
    /// @param  efficiency The efficiency of the link (percentage based).
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) public payable approved(tokenId) tokenExists(linkId) {
        Token storage t = _tokens[tokenId];
        require(t.links.length <= MAX_LINKS, "DIGIL: Too Many Links");

        uint8 baseEfficiency = t.linkEfficiency[linkId].base;
        uint256 bonusEfficiency = t.linkEfficiency[linkId].affinityBonus;

        // Validate link: tokens must be different, destination must be in allowed range, and efficiency must be greater than current base.
        require(tokenId != linkId && linkId > 18 && efficiency > baseEfficiency, "DIGIL: Invalid Link");
        
        Token storage d = _tokens[linkId];
        // Ensure the destination token is not restricted or the sender is whitelisted.
        require(!d.restricted || d.contributions[_msgSender()].whitelisted, "DIGIL: Restricted");

        uint256 value = msg.value;
        // Ensure sufficient value is provided for linking.
        if (value < (t.incrementalValue + d.incrementalValue)) revert InsufficientFunds(t.incrementalValue + d.incrementalValue);

        // Update last activity
        t.lastActivity = block.timestamp;

        // Split the value evenly between the two tokens.
        if (value > 0) {
            _createValue(tokenId, value / 2);
            _createValue(linkId, value / 2);
        }

        // If both tokens are associated with planes, calculate bonus affinity.
        uint256 sourcePlane = t.links.length > 0 ? t.links[0] : 0;
        uint256 destinationPlane = d.links.length > 0 ? d.links[0] : 0;
        if (sourcePlane > 0 && sourcePlane <= 18 && destinationPlane > 0 && destinationPlane <= 18) {            
            uint256 bonus = _affinityBonus(sourcePlane, destinationPlane, efficiency);
            bonusEfficiency = bonus > bonusEfficiency ? bonus : bonusEfficiency;
        }

        // Update link efficiency details.
        t.linkEfficiency[linkId].base = efficiency;
        t.linkEfficiency[linkId].affinityBonus = bonusEfficiency;
        
        // If the link was not already present, add it.
        if (baseEfficiency == 0) {
            t.links.push(linkId);
        }

        emit Link(tokenId, linkId, efficiency, bonusEfficiency);
        
        // Calculate additional coin fee based on efficiency and current link count.
        uint256 linkScale = 200 / t.links.length;
        uint256 e = efficiency > linkScale ? efficiency - linkScale : 0;
        _coinsFromSender((efficiency + (e * (e + 1) / 2)) * _coinRate);
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

    /// @notice Unlinks a token from another token.
    /// @param  tokenId The source token ID.
    /// @param  linkId The destination token ID to unlink.
    function unlinkToken(uint256 tokenId, uint256 linkId) public approved(tokenId) tokenExists(linkId) {
        Token storage t = _tokens[tokenId];
        require(linkId > 0 && t.linkEfficiency[linkId].base > 0, "DIGIL: Invalid Link");

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
                // Swap with the last element and remove it.
                links[linkIndex] = links[linksLength - 1];
                links.pop();
                emit Unlink(tokenId, linkId);
                break;
            }
        }
    }
}