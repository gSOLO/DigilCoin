// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "github/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Digil Token (NFT)
/// @author gSOLO
/// @notice NFT contract used for the creation, charging, and activation of Digital Sigils on the Ethereum Blockchain
/// @custom:security-contact security@digil.co.in
contract DigilToken is ERC721, Ownable, IERC721Receiver {
    using Strings for uint256;
    
    IERC20 private _coins = IERC20(0xa4101FEDAd52A85FeE0C85BcFcAB972fb7Cc7c0e);
    uint256 private _coinDecimals = 10 ** 18;
    uint256 private _coinRate = 100 * 10 ** 18;

    uint256 private _incrementalValue = 100 * 1000 gwei;
    uint256 private _transferRate = 95 * 1000 gwei;

    bool _paused;
    address _this;

    mapping(uint256 => Token) private _tokens;
    mapping(address => bool) private _blacklisted;
    mapping(address => Distribution) private _distributions;
    mapping(ERC721 => ContractToken[]) private _contractTokenAlias;
    ContractToken private _nullContractToken = ContractToken(0, 0, false);

    /// @dev Pending Coin and Value Distributions, and the Time of the last Distribution
    struct Distribution {
        uint256 time;
        uint256 coins;
        uint256 value;
    }

    /// @dev Information about how much was Contributed to a Token's Charge
    struct TokenContribution {
        uint256 charge;
        uint256 value;
        bool exists;
        bool distributed;
        bool whitelisted;
    }

    /// @dev Illustrates the relationship between an external ERC721 token and a Digil Token
    struct ContractToken {
        uint256 externalTokenId;
        uint256 internalTokenId;
        bool recallable;
    }

    /// @dev Token information
    struct Token {
        uint256 charge;
        uint256 incrementalValue;
        uint256 value;        
        
        uint256 linkedCharge;
        uint256[] links;
        mapping(uint256 => uint8) linkEfficiency;

        address[] contributors;
        mapping(address => TokenContribution) contributions;

        uint256 activationThreshold;
        bool active;
        bool activated;
        
        bytes data;
        string uri;

        bool restricted;
    }

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

    /// @dev Configuration was updated
    event Configure(uint256 chargeRate, uint256 transferRate);

    /// @dev Contract was Paused
    event Pause();

    /// @dev Contract was Unpaused
    event Unpause();

    /// @dev Address was added to the contract Blacklist
    event Blacklist(address indexed account);

    /// @dev Address was removed from the contract Blacklist
    event Whitelist(address indexed account);

    /// @dev Address was added to a Token's Whitelist
    event Whitelist(address indexed account, uint256 indexed tokenId);

    /// @notice Token was updated
    event Update(uint256 indexed tokenId);

    /// @notice Token was Activated
    event Activate(uint256 indexed tokenId);

    /// @notice Token was Deactivated
    event Dectivate(uint256 indexed tokenId);

    /// @notice Token was Charged
    event Charge(uint256 indexed tokenId);

    /// @notice Token was Linked
    event Link(uint256 indexed tokenId, uint256 indexed linkId, uint8 efficiency);

    /// @notice Token was Unlinked
    event Unlink(uint256 indexed tokenId, uint256 indexed linkId);

    /// @notice Coins and Value was generated for a given address
    event PendingDistribution(address indexed addr, uint256 coins, uint256 value);

    /// @notice Value was Contributed to a Token
    event Contribution(address indexed addr, uint256 indexed tokenId);

    constructor() ERC721("Digil Token", "DiGiL") {
        _this = address(this);
        _coins.approve(_this, ~uint256(0));
        
        address sender = msg.sender;
        string memory baseURI = "https://digil.co.in/token/";
        
        string[21] memory plane;
        plane[0] = "";
        plane[1] = "void";
        plane[2] = "karma";
        plane[3] = "kaos";
        plane[4] = "fire";
        plane[5] = "air";
        plane[6] = "earth";
        plane[7] = "water";
        plane[8] = "ice";
        plane[9] = "lightning";
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
        
        unchecked {
            for (uint256 tokenIndex; tokenIndex < 21; tokenIndex++) {
                uint256 tokenId = _tokenIdCounter.current();
                _tokenIdCounter.increment();
                _mint(sender, tokenId);
                Token storage t = _tokens[tokenId];
                t.active = true;
                t.activated = true;
                t.uri = string(abi.encodePacked(baseURI, plane[tokenIndex]));
            }
        }

        _tokens[0].restricted = true;
        _tokens[20].restricted = true;
    }

    /// @notice Accepts all payments.
    /// @dev    The origin of the payment is not tracked by the contract, but the accumulated balance can be used by the admin to add Value to Tokens.
    receive() external payable {
        _addValue(msg.value);
    }

    /// @notice Will transfer any pending Coin and Value Distributions associated with the sender.
    ///         A number of bonus Coins are available every 15 minutes for those who already hold Coins, Tokens, or have any pending Value distributions.
    /// @return coins The number of Coins transferred
    /// @return value The Value transferred
    function withdraw() public enabled returns(uint256 coins, uint256 value) {
        address addr = _msgSender();
        _notOnBlacklist(addr);

        Distribution storage distribution = _distributions[addr];

        value = distribution.value;
        distribution.value = 0;
        bool haveValue = value > 0;

        coins = distribution.coins;
        distribution.coins = 0;

        if (haveValue || balanceOf(addr) > 0 || _coins.balanceOf(addr) > 0) {
            uint256 lastBonusTime = distribution.time;
            distribution.time = block.timestamp;
            uint256 bonus = (block.timestamp - lastBonusTime) / 15 minutes * _coinDecimals;
            coins += (bonus < _coinRate ? bonus : _coinRate);
        }

        if (haveValue) {            
            Address.sendValue(payable(addr), value);
        }

        if (coins > 0 && !_transferCoinsFrom(_this, addr, coins)) {
            distribution.coins = coins;
            coins = 0;
        }

        return (coins, value);
    }

    function _addValue(uint256 value) private {
        _addValue(_this, value, 0);
    }

    function _addValue(address addr, uint256 value, uint256 coins) private {
        if (value > 0 || coins > 0) {
            Distribution storage distribution = _distributions[addr];
            distribution.value += value;
            distribution.coins += coins;
            emit PendingDistribution(addr, coins, value);
        }
    }

    /// @dev    Adds a percentage of the value to be Distributed to the contract, and the rest to the address specified.
    ///         Adds all the Coins to be Distributed to the address specified along with an additional number of bonus coins based on the value to be Distributed.
    ///         An example 1 eth, 100 Coin distribution with a chargeRate of 100 and a transferRate of 95 would:
    ///             Add 0.05 eth to the contract.
    ///             Add 0.95 eth to the address specified.
    ///             Add 1100 Coins to the address specified (1000 bonus Coins)
    function _addDistribution(address addr, uint256 value, uint256 coins) internal {
        uint256 incrementalDistribution = value / _incrementalValue;
        uint256 contractRate = _incrementalValue - _transferRate;
        _addValue(incrementalDistribution * contractRate);
        uint256 bonusCoins = _coinRate / 1000 * incrementalDistribution;
        _addValue(addr, incrementalDistribution * _transferRate, coins + bonusCoins);
    }

    function _createValue(uint256 tokenId, uint256 value) internal {
        _tokens[tokenId].value += value;
        emit Contribution(_this, tokenId);
    }

    /// @dev    Adds Value to the specified Token using the contract's available balance.
    /// @param  tokenId The ID of the Token to add Value to
    /// @param  value The Value to add to the Token
    function createValue(uint256 tokenId, uint256 value) public payable admin {
        _addValue(msg.value);
        Distribution storage distribution = _distributions[_this];
        uint256 balance = distribution.value;
        require(value <= balance);
        distribution.value -= value;

        Token storage t = _tokens[tokenId];
        uint256 newValue = t.value + value;
        t.value = newValue;
        emit Contribution(_this, tokenId);
    }

    function _ownerIsSender() private view returns(bool) {
        return owner() == _msgSender();
    }

    function _onlyOwner() private view {
        require(_ownerIsSender());
    }

    modifier admin() {
        _onlyOwner();
        _;
    }

    /// @dev    Update contract configuration.
    /// @param  chargeRate Represents a number of values:
    ///                    The maximum number of bonus Coins a user can withdraw.
    ///                    The multiplier used when determining the number of Coins required to update a Token URI.
    ///                    The multiplier used when determining the number of Coins required to link a Token with an efficiency greater than 100.
    ///                    The minimum Value used to charge a Token, update a Token URI, or skip executing Links (* 1k gwei)
    /// @param  transferRate The Value to be distributed when a Token is Activated as a percentage of the chargeRate (* 1k gwei)
    function configure(uint256 chargeRate, uint256 transferRate) public admin {
        require(chargeRate > 0 && transferRate <= chargeRate && transferRate >= (chargeRate / 2));

        _coins.approve(_this, ~uint256(0));
        _coinRate = chargeRate * _coinDecimals;

        _incrementalValue = chargeRate * 1000 gwei;
        _transferRate = transferRate * 1000 gwei;
        
        emit Configure(chargeRate, transferRate);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal enabled override
    {
        super._beforeTokenTransfer(from, to, tokenId);
        _notOnBlacklist(from);
        _notOnBlacklist(to);
    }

    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal enabled override
    {
        super._afterTokenTransfer(from, to, tokenId);
        _tokens[tokenId].contributions[to].whitelisted = true;
    }

    function _whenNotPaused() private view {
        require(_paused == false);
    }

    function _enabled(address account) private view {
        _whenNotPaused();
        _notOnBlacklist(account);
    }

    modifier approved(uint256 tokenId) {
        address account = _msgSender();
        _enabled(account);
        require(_isApprovedOrOwner(account, tokenId));
        _;
    }

    modifier operatorEnabled(address account) {
        _enabled(account);
        _;
    }

    modifier enabled() {
        _whenNotPaused();
        _;
    }

    /// @dev Pause the contract
    function pause() public admin {
        _paused = true;
        emit Pause();
    }

    /// @dev Unpause the contract
    function unpause() public admin {
        _paused = false;
        emit Unpause();
    }

    // Blacklist
    function _notOnBlacklist(address account) internal view {
        require(!_blacklisted[account]);
    }

    function _blacklist(address account) private {
        _blacklisted[account] = true;
        emit Blacklist(account);
    }

    /// @dev    Add account to Blacklist
    /// @param  account The address to Blacklist
    function blacklist(address account) public admin {
        _blacklist(account);
    }

    /// @notice Opt-Out to prevent Token transfers to/from sender.
    ///         Requires Incremental Value of half the current Coin Rate.
    function optOut() public payable {
        uint256 value = msg.value;
        require(value >= _incrementalValue * _coinRate / _coinDecimals / 2);
        _blacklist(_msgSender());
        _addValue(value);
    }

    /// @dev    Remove account from Blacklist.
    /// @param  account The address to Whitelist
    function whitelist(address account) public admin {
        _blacklisted[account] = false;
        emit Whitelist(account);
    }

    // Coin
    function _coinsFromSender(uint256 coins) internal returns(bool) {
        return _transferCoinsFrom(_msgSender(), _this, coins);
    }

    function _transferCoinsFrom(address from, address to, uint256 coins) internal returns(bool) {
        return _coins.transferFrom(from, to, coins);
    } 

    /// @dev    When an ERC721 token is sent to this contract, creates a new Token representing the token received.
    ///         The Incremental Value of the Token is set to the Minimum Non-Zero Incremental Value, with an Activation Threshold of 0.
    ///         The account (ERC721 contract address), and external token ID are appended to the Token URI as a query string.
    ///         Any data sent is stored with the Token and forwarded during Safe Transfer when {recallToken} is called.
    ///         If the ERC721 received is a DigilToken it is linked to the new Token.
    /// @param  operator The address which called safeTransferFrom on the ERC721 token contract
    /// @param  from The previous owner of the ERC721 token
    /// @param  tokenId The ID of the ERC721 token
    /// @param  data Optional data sent from the ERC721 token contract
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external operatorEnabled(operator) returns (bytes4) {
        address account = _msgSender();        
        require(_getContractToken(account, tokenId, false).externalTokenId == 0);

        uint256 internalTokenId = _createToken(from, 0, 0, data);        
        _contractTokenAlias[ERC721(account)].push(ContractToken(tokenId, internalTokenId, false));

        Token storage t = _tokens[internalTokenId];
        t.uri = string(abi.encodePacked(tokenURI(internalTokenId), "?account=", Strings.toHexString(uint160(account), 20), "&tokenId=", tokenId.toString()));
        t.contributors.push(account);

        uint256 minimumIncrementalValue = _incrementalValue;
        if (account == _this) {
            Token storage d = _tokens[tokenId];
            d.links.push(internalTokenId);
            d.linkEfficiency[internalTokenId] = uint8(100 / d.links.length);
            uint256 dIncrementalValue = d.incrementalValue;
            if (minimumIncrementalValue < dIncrementalValue) {
                minimumIncrementalValue = dIncrementalValue;
            }
        }
        t.incrementalValue = minimumIncrementalValue;
        
        return this.onERC721Received.selector;
    }

    /// @notice Return the Contract Token to the current owner. The Token the Contract Token is attached to must have been Activasted or Destroyed.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value.
    function recallToken(address account, uint256 tokenId) public payable {
        ContractToken memory contractToken = _getContractToken(account, tokenId, true);

        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;
        require (contractToken.recallable && value >= t.incrementalValue);
        _addValue(value);

        ERC721(account).safeTransferFrom(_this, ownerOf(tokenId), contractToken.externalTokenId, t.data);
    }

    function _getContractToken(address account, uint256 tokenId, bool pop) internal returns(ContractToken storage) {
        ContractToken[] storage eTokens = _contractTokenAlias[ERC721(account)];
        uint256 eTokenIndex;
        uint256 eTokensLength = eTokens.length;
        for (eTokenIndex; eTokenIndex < eTokensLength; eTokenIndex++) {
            ContractToken storage eToken = eTokens[eTokenIndex];
            uint256 internalTokenId = eToken.internalTokenId;
            if (internalTokenId == tokenId) {
                if (pop) {
                    eTokens[eTokenIndex] = eTokens[eTokensLength - 1];
                    eTokens.pop();
                }
                return eToken;
            }
        }
        return _nullContractToken;
    }

    // Token Information
    function _baseURI() internal view override returns (string memory) {
        return _tokens[0].uri;
    }

    /// @notice If the URI of the Token is explicitly set, it will be returned. 
    ///         If the URI of the Token is not set, a concatenation of the base URI and the Token ID is returned (the default behavior).
    /// @param  tokenId The ID of the Token to retrieve the URI for
    /// @return The Token URI if the Token exists. 
    function tokenURI(uint256 tokenId) public view virtual override tokenExists(tokenId) returns (string memory) {
        string storage uri = _tokens[tokenId].uri;

        if (bytes(uri).length > 0) {
            return string(abi.encodePacked(uri));
        }

        return super.tokenURI(tokenId);
    }

    /// @notice Get the total Value of the Token and any associated Data
    /// @dev    The Value and Charged Value can be added  together to give the Token's Total Value.
    ///         The Charged Value is derived from the Token's Charge and Incremental Value (Charge (decimals excluded) * Incremental Value)
    /// @param  tokenId The ID of the token whose Value and Data is to be returned
    /// @return value The current Value the Token
    /// @return charge The current Charge of the Token
    /// @return incrementalValue The Incremental Value of the Token
    /// @return linkedCharge The current Charge of the Token generated from Links
    /// @return data The Token's Data
    function tokenData(uint256 tokenId) public view tokenExists(tokenId) returns(uint256 value, uint256 charge, uint256 incrementalValue, uint256 linkedCharge, bytes memory data) {
        Token storage t = _tokens[tokenId]; 
        return (t.value, t.charge, t.incrementalValue, t.linkedCharge, t.data);
    }

    modifier tokenExists(uint256 tokenId) {
        require(_exists(tokenId));
        _;
    }

    // Create Token
    function _createToken(address creator, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data) internal returns(uint256) {        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _mint(creator, tokenId);
        
        _updateToken(tokenId, incrementalValue, activationThreshold, "", false, data, true);

        return tokenId;
    }

    /// @notice Creates a new Token.
    ///         Linking to a plane other than the 4 elemental planes (4-7; fire, air, earth, water) requires a Coin transfer:
    ///             void, karmic, and kaotic planes (1-3; void, karma, kaos): 10x Coin Rate
    ///             paraelemental planes (8-11; ice, lightning, metal, nature): 1x Coin Rate
    ///             energy planes (12-16; harmony, discord, entropy, exergy, magick): 100x Coin Rate
    ///             ethereal planes (17-18; aether, world): 250x Coin Rate
    /// @dev    Data stored with the Token cannot be updated.
    /// @param  incrementalValue the Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a multiple of the Minimum Incremental Value
    /// @param  activationThreshold the number of Coins required for the Token to be Activated (decimals excluded)
    /// @param  restricted Boolean indicating whether a address must be Whitelisted to Contribute to a Token
    /// @param  plane The planar Token to link to
    /// @param  data Optional data to store with the Token
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool restricted, uint256 plane, bytes calldata data) public payable returns(uint256) {
        address addr = _msgSender();
        uint256 tokenId = _createToken(addr, incrementalValue, activationThreshold * _coinDecimals, data);
        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;

        if (value > 0) {
            _createValue(tokenId, value);
        }

        if (plane > 0) {
            require (plane <= 18);
            if (plane < 4) {
                _coinsFromSender(_coinRate * 10);
            } else if (plane > 16) {
                _coinsFromSender(_coinRate * 250);
            } else if (plane > 11) {
                _coinsFromSender(_coinRate * 100);
            } else if (plane > 7) {
                _coinsFromSender(_coinRate);
            }
            t.links.push(plane);
            t.linkEfficiency[plane] = 100;
        }
        
        if (restricted) {
            require(value >= t.incrementalValue && value >= _incrementalValue);
            t.restricted = restricted;
            emit Update(tokenId);
        }

        return tokenId;
    }

    /// @notice Add accounts to a Token's Whitelist.
    ///         Requires a Value sent greater than or equal to the larger of the Token's Incremental Value or the Minimum Incremental Value to be Restricted. 
    /// @param  tokenId The ID of the 
    /// @param  accounts The addresses to Whitelist
    /// @param  restrict A boolean indicating whether a Token's Whitelist is enabled
    function whitelist(uint256 tokenId, address[] memory accounts, bool restrict) public payable approved(tokenId) {
        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];

        bool wasRestricted = t.restricted;
        if (restrict != wasRestricted) {
            if (restrict) {
                require(value >= t.incrementalValue && value >= _incrementalValue);
            }
            t.restricted = restrict;
            emit Update(tokenId);
        }

        if (value > 0) {
            _createValue(tokenId, value);
        }

        mapping(address => TokenContribution) storage contributions = t.contributions;

        uint256 accountIndex;
        uint256 accountsLength = accounts.length;
        for (accountIndex; accountIndex < accountsLength; accountIndex++) {
            address account = accounts[accountIndex];
            contributions[account].whitelisted = true;
            emit Whitelist(account, tokenId);
        }        
    }

    // Update Token
    function _updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, string memory uri, bool overwriteUri, bytes memory data, bool overwriteData) internal {
        Token storage t = _tokens[tokenId];

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

    /// @notice Updates an existing Token. Message sender must be approved for this Token.
    ///         In order for the incrementalValue or activationThreshold to be updated, the Token must have 0 Charge.
    ///         In order for the Token URI to be updated, the following conditions must be met:
    ///             A transfer of 2500 Coins per Coin Rate
    ///             A Value sent of at least the Token's Incremental Value plus the Minimum Incremental Value
    /// @param  tokenId The ID of the Token to Update
    /// @param  incrementalValue The Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a multiple of the Minimum Incremental Value
    /// @param  activationThreshold The number of Coins required for the Token to be Activated (decimals excluded)
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, string calldata uri) public payable approved(tokenId) {
        Token storage t = _tokens[tokenId];
        bool haveCharge = t.charge > 0;
        uint256 tChargeRate = t.incrementalValue;
        activationThreshold *= _coinDecimals;

        if (haveCharge) {
            require(tChargeRate == incrementalValue && t.activationThreshold == activationThreshold);
        }

        bool overwriteUri = bytes(uri).length > 0;
        if (overwriteUri && !_ownerIsSender()) {
            require(_coinsFromSender(_coinRate * 2500));
        }

        uint256 value = msg.value;
        uint256 minimumValue = overwriteUri ? (tChargeRate + _incrementalValue) : 0;
        require(value >= minimumValue);

        _addValue(value);
        _updateToken(tokenId, incrementalValue, activationThreshold, uri, overwriteUri, bytes(""), false);
    }

    // Charge Token
    function _chargeActiveToken(address contributor, uint256 tokenId, uint256 coins, uint256 value, bool link) internal {
        Token storage t = _tokens[tokenId];

        uint256[] storage links = t.links;
        uint256 linksLength = links.length;

        if (linksLength == 0 || link) {

            t.linkedCharge += coins;
            emit Charge(tokenId);

        } else {    

            uint256 linkedValue = value / linksLength;   
            uint256 linkIndex;
            for(linkIndex; linkIndex < linksLength; linkIndex++) {                
                uint256 linkId = links[linkIndex];
                uint256 linkedCoins = coins / 100 * t.linkEfficiency[linkId];
                bool charged = _chargeToken(contributor, linkId, linkedCoins, linkedValue, true);
                if (charged) {
                    value -= linkedValue;
                } else {
                    t.linkedCharge += linkedCoins;
                }
            }

        }

        if (value > 0) {
            _addDistribution(ownerOf(tokenId), value, 0);
        }
    }

    function _chargeToken(address contributor, uint256 tokenId, uint256 coins, uint256 value, bool link) internal returns(bool) {
        Token storage t = _tokens[tokenId];

        TokenContribution storage c = t.contributions[contributor];
        bool validContribution = !t.restricted || c.whitelisted;

        uint256 contribution = t.incrementalValue * coins / _coinDecimals;
        validContribution = validContribution && value >= contribution;

        if (link) {

            if (!validContribution) {
                return false;
            }

        } else {

            require(validContribution && _coinsFromSender(coins));

        }

        if (t.activated) {

            _chargeActiveToken(contributor, tokenId, coins, value, link || !t.active);

        } else {

            if (!c.exists) {
            c.exists = true;
                t.contributors.push(contributor);
            }
            c.charge += coins;
            c.value += contribution;

            uint256 valueContribution = value - contribution;
            if (valueContribution > 0) {
                uint256 currentValue = t.value;
                uint256 newValue = currentValue + valueContribution;
                t.value = newValue;
            }

            if (contribution > 0 || valueContribution > 0) {
                emit Contribution(contributor, tokenId);
            }
            t.charge += coins;

            emit Charge(tokenId);

        }

        return true;
    }

    /// @notice Charge Token.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value for each Coin.
    /// @param  tokenId The ID of the Token to Charge
    /// @param  coins The Coins used to Charge the Token (decimals excluded)
    function chargeToken(uint256 tokenId, uint256 coins) public payable {
        chargeToken(_msgSender(), tokenId, coins);
    }

    /// @notice Charge Token on behalf of a contributor.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value for each Coin.
    /// @param  contributor The address to record as the contributor of this Charge
    /// @param  tokenId The ID of the Token to Charge
    /// @param  coins The Coins used to Charge the Token (decimals excluded)
    function chargeToken(address contributor, uint256 tokenId, uint256 coins) public payable operatorEnabled(contributor) {
        require(coins > 0);
        _chargeToken(contributor, tokenId, coins * _coinDecimals, msg.value, false);
    }

    // Token Distribution
    function _distribute(uint256 tokenId, bool discharge) internal {
        address tokenOwner = ownerOf(tokenId);

        Token storage t = _tokens[tokenId];
        uint256 tCharge = t.charge;
        t.charge = 0;
        uint256 tValue = t.value;
        t.value = 0;

        uint256 distribution;
        uint256 cIndex;
        uint256 cLength = t.contributors.length;
        uint256 incrementalValue = tCharge > 0 && tCharge >= _coinDecimals ? tValue / (tCharge / _coinDecimals) : 0;
        for (cIndex; cIndex < cLength; cIndex++) {
            address contributor = t.contributors[cIndex];
            TokenContribution storage contribution = t.contributions[contributor];
            bool distributed = contribution.distributed;
            contribution.distributed = true;

            ContractToken storage contractToken = cIndex == 0 ? _getContractToken(contributor, tokenId, false) : _nullContractToken;
            if (contractToken.internalTokenId != 0) {

                contractToken.recallable = true;

            } else if (!distributed) {

                if (discharge) {

                    _addValue(contributor, contribution.value, contribution.charge);

                } else {

                    distribution += contribution.value;
                    uint256 distributableTokenValue = incrementalValue * contribution.charge / _coinDecimals;
                    tValue -= distributableTokenValue;
                    _addValue(contributor, distributableTokenValue, 1 * _coinDecimals);

                }

            }
        }
        
        if (discharge) {

            t.linkedCharge = 0;
            _addDistribution(tokenOwner, tValue, 0);

        } else {

            t.linkedCharge += tCharge;
            _addDistribution(tokenOwner, distribution, 0);
            _addValue(tValue);
            
        }
    }

    // Discharge Token
    function _discharge(uint256 tokenId, bool burn) internal {
        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];
        require(value >= _incrementalValue && value >= t.incrementalValue);
        _addValue(value);
        
        _distribute(tokenId, burn || !t.activated);

        address contractTokenAddress;

        uint256 cIndex;
        uint256 cLength = t.contributors.length;
        for (cIndex; cIndex < cLength; cIndex++) {
            address contributor = t.contributors[cIndex];
            TokenContribution storage contribution = t.contributions[contributor];

            contribution.charge = 0;
            contribution.value = 0;
            contribution.exists = false;
            contribution.distributed = false;

            if (cIndex == 0) {
                ContractToken storage contractToken =  _getContractToken(contributor, tokenId, false);
                if (contractToken.internalTokenId != 0) {
                    contractTokenAddress = contributor;
                    contractToken.recallable = false;  
                    if (burn) {
                        contractToken.internalTokenId = 0;  
                    }                    
                }
            }
        }

        delete t.contributors;

        if (contractTokenAddress != address(0)) {
            t.contributors.push(contractTokenAddress);
        }

        if (burn) {
            delete _tokens[tokenId];
            _burn(tokenId);
        }
    }

    /// @notice Discharge an existing Token and reset all Contributions.
    ///         If the Token has been Activated: Any Contributed Value that has not yet been Distributed will be Distributed.
    ///         If the Token has not been Activated: Any Contributed Value that has not yet been Distributed will be returned to its Contributors, any additional Token Value to its owner.
    ///         Requires a Value sent greater than or equal to the larger of the Token's Incremental Value or the Minimum Incremental Value to be Discharged.
    /// @param  tokenId The ID of the Token to Discharge
    function dischargeToken(uint256 tokenId) public payable approved(tokenId) {
        _discharge(tokenId, false); 
    }

    /// @notice Destroy (burn), an existing Token.
    ///         If the Token has been Activated: Any Contributed Value that has not yet been Distributed will be Distributed.
    ///         If the Token has not been Activated: Any Contributed Value that has not yet been Distributed will be returned to its Contributors, any additional Token Value to its owner.
    ///         Any Contract Tokens Linked to this Token that have yet to be Recalled, cannot be Recalled.
    ///         Requires a Value sent greater than or equal to the larger of the Token's Incremental Value or the Minimum Incremental Value to be Destroyed.
    /// @param  tokenId The ID of the Token to Destroy
    function destroyToken(uint256 tokenId) public payable approved(tokenId) {        
        _discharge(tokenId, true);
    }

    /// @notice Activate an Inactive Token, Distributes Value, Coins, and execute Links.
    ///         Requires the Token have a Charge greater than or equal to the Token's Activation Threshold.
    /// @param  tokenId The ID of the Token to activate.
    function activateToken(uint256 tokenId) public approved(tokenId) {
        Token storage t = _tokens[tokenId];
        require(t.active == false && t.charge >= t.activationThreshold);

        t.active = true;
        t.activated = true;
        emit Activate(tokenId);

        _distribute(tokenId, false);
    }

    /// @notice Deactivates an Active Token.
    ///         Requires the Token have zero Charge, and a Value sent greater than or equal to the Token's Incremental Value.
    /// @param  tokenId The ID of the token to Deactivate
    function deactivateToken(uint256 tokenId) public payable approved(tokenId) {
        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;
        require(t.active == true && t.charge == 0 && value >= t.incrementalValue);

        t.active = false;       
        emit Dectivate(tokenId);

        _addValue(value);
    }

    /// @notice Links two Tokens together in order to generate or transfer Coins on Charge or Token Activation.
    ///         A Link between Tokens (from source to destination) must not already exist, and both Tokens must have less than 8 Links each.
    ///         Requires a Value greater than or equal to the larger of the source or destination Token's Incremental Value.
    ///         Any Value contributed is split between and added to the source and destination Token.
    ///         Requires a summation of Coins at the Coin Rate depending on the Link Efficiency (>1).
    ///         An Efficiency of 1 is meant to indicate a Coin generation or transfer of 1%. 200 would be 200% et. cetera.
    /// @param  tokenId The ID of the Token to Link (source)
    /// @param  linkId The ID of the Token to Link to (destination)
    /// @param  efficiency The Efficiency of the Link
    function linkToken(uint256 tokenId, uint256 linkId, uint8 efficiency) public payable approved(tokenId) {
        require(tokenId != linkId && linkId > 18 && efficiency > 0);
        
        Token storage t = _tokens[tokenId];
        Token storage d = _tokens[linkId];

        require(!d.restricted || d.contributions[_msgSender()].whitelisted);

        uint8 linkEfficiency = t.linkEfficiency[linkId];

        uint256 value = msg.value;
        uint256 tIncrementalValue = t.incrementalValue;
        require(value >= tIncrementalValue && tIncrementalValue >= d.incrementalValue);
        if (value > 0) {
            _createValue(tokenId, value / 2);
            _createValue(linkId, value / 2);
        }
        
        if (linkEfficiency == 0) {
            t.links.push(linkId);
        }
        
        uint256 e = efficiency > 100 ? efficiency - 100 : 0;
        require(_coinsFromSender((efficiency + (e * (e + 1) / 2)) * _coinRate));

        t.linkEfficiency[linkId] = efficiency;
        emit Link(tokenId, linkId, efficiency);
    }

    /// @notice Unlinks Tokens
    /// @dev    Tokens with ID 0 or 1 cannot be Unlinked
    /// @param  tokenId The ID of the Token to Unlink (source)
    /// @param  linkId The ID of the Token to Unlink (destination)
    function unlinkToken(uint256 tokenId, uint256 linkId) public approved(tokenId) {
        Token storage t = _tokens[tokenId];
        t.linkEfficiency[linkId] = 0;

        uint256[] storage links = t.links;
        uint256 linkIndex;
        uint256 linksLength = links.length;
        for (linkIndex; linkIndex < linksLength; linkIndex++) {
            uint256 lId = links[linkIndex];
            if (lId == linkId) {
                links[linkIndex] = links[linksLength - 1];
                links.pop();
                emit Unlink(tokenId, linkId);
                break;
            }
        }
    }
}
