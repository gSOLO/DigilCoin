// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "github/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Coin used for Charging Tokens
interface DigilCoin is IERC20 {
    
}

/// @dev Utility contract used for the generation of Coins when Tokens are Charged or Activated
interface DigilLinkUtility {
    function getDefaultLinks(uint256 tokenId) external view returns (DigilToken.TokenLink[] memory);
    function getLinkValues(uint256 tokenId, bool discharge, DigilToken.TokenLink[] memory links, uint256 charge) external view returns (DigilToken.TokenLink[8] memory);
}

/// @title Digil Token (NFT)
/// @author gSOLO
/// @notice NFT contract used for the creation, charging, and activation of Digital Sigils
/// @custom:security-contact security@digil.co.in
contract DigilToken is ERC721, Ownable, IERC721Receiver {
    IERC20 private _erc20 = DigilCoin(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8); // 0xa4101FEDAd52A85FeE0C85BcFcAB972fb7Cc7c0e
    uint256 private _coinDecimals = 10 ** 18;
    uint256 private _coinRate = 100;
    DigilLinkUtility private _linkUtility = DigilLinkUtility(0xf8e81D47203A594245E36C48e151709F0C19fBe8);
    uint256 private _incrementalValue = 100 * 1000 gwei;
    uint256 private _transferRate = 95 * 1000 gwei;
    bool _paused;
    address _this;

    mapping(uint256 => Token) private _tokens;
    mapping(address => bool) private _blacklisted;
    mapping(address => Distribution) private _distributions;
    mapping(ERC721 => ContractToken[]) private _contractTokenAlias;
    ContractToken private _nullContractToken = ContractToken(0, 0, false);

    // Pending Coin and Value Distributions, and the Time of the last Distribution
    struct Distribution {
        uint256 time;
        uint256 coins;
        uint256 value;
    }
    
    // The relationship between a source and destination Token
    struct TokenLink {
        uint256 source;
        uint256 destination;
        uint256 value;
        uint256 efficiency;
        uint256 probability;
    }

    // Information about how much was Contributed to a Token's Charge
    struct TokenContribution {
        uint256 charge;
        uint256 value;
        bool exists;
        bool distributed;
        bool whitelisted;
    }

    // Illustrates the relationship between an external ERC721 token and an internal Token
    struct ContractToken {
        uint256 externalTokenId;
        uint256 internalTokenId;
        bool returnable;
    }

    // Token information
    struct Token {
        uint256 charge;
        uint256 incrementalValue;
        uint256 value;

        address[] contributors;
        mapping(address => TokenContribution) contributions;

        uint256 activationThreshold;
        bool active;

        TokenLink[] links;
        
        bytes data;
        string uri;

        bool whitelistEnabled;
    }

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

    /// @dev Configuration was updated
    event Configure(address coinAddress, address utilityAddress);

    /// @notice Token was created
    event Create(uint256 indexed tokenId);

    /// @notice Token was updated
    event Update(uint256 indexed tokenId);

    /// @notice Token was Activated
    event Activate(uint256 indexed tokenId); 

    /// @notice Value and Coins were generated for a given address
    event PendingDistribution(address indexed addr, uint256 value, uint256 coins);

    /// @notice Value was Contributed to a Token
    event Contribution(address indexed addr, uint256 indexed tokenId);
    
    /// @notice Token was Charged
    event Charge(uint256 indexed tokenId);

    /// @notice Token was Linked
    event Link(uint256 indexed tokenId, uint256 indexed linkId, uint256 efficiency, uint256 probability);

    /// @notice Token was Unlinked
    event Unlink(uint256 indexed tokenId, uint256 indexed linkId);

    /// @dev Contract was Paused
    event Pause(address admin);

    /// @dev Contract was Unpaused
    event Unpause(address admin);

    /// @dev Address was added to or removed from the contract Blacklist
    event Blacklist(address indexed account, bool removed);

    /// @dev Address was added to a Token's Whitelist
    event Whitelist(address indexed account, uint256 indexed tokenId, bool whitelistEnabled);

    constructor() ERC721("Digil Token", "DiGiL") {
        _this = address(this);
        _erc20.approve(_this, ~uint256(0));

        string memory base = _baseURI();
        
        string[18] memory plane;
        plane[0] = "null";
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
        plane[17] = "ilxr";
        
        for (uint256 tokenIndex; tokenIndex < 18; tokenIndex++) {
            uint256 tokenId = _tokenIdCounter.current();
            _tokenIdCounter.increment();
            _safeMint(msg.sender, tokenId);
            Token storage t = _tokens[tokenId];
            t.active = true;
            t.uri = string(abi.encodePacked(base, plane[tokenIndex])); 
        }

        _tokens[0].whitelistEnabled = true;
        _tokens[1].charge = 1000000000;
        _tokens[2].charge = 1000000000;
        _tokens[3].charge = 1000000000;
    }

    /// @notice Accepts all payments.
    /// @dev    The origin of the payment is not tracked by the contract, but the accumulated balance can be used by the admin to add Value to Tokens.
    receive() external payable {
        _addValue(msg.value);
    }

    /// @notice Will transfer any pending Coin and Value Distributions associated with the sender.
    ///         A number of bonus Coins are available every 15 minutes for those who already hold Coins, Tokens, or have any pending Value distributions.
    /// @return coins The number of Coins transfered
    /// @return value The Value transfered
    function withdraw() public senderEnabled returns(uint256 coins, uint256 value) {
        address addr = _msgSender();

        Distribution storage distribution = _distributions[addr];

        coins = distribution.coins;
        distribution.coins = 0;

        value = distribution.value;
        distribution.value = 0;

        if (value > 0 || balanceOf(addr) > 0 || _erc20.balanceOf(addr) > 0) {
            uint256 lastBonus = distribution.time;
            distribution.time = block.timestamp;
            uint256 bonus = (block.timestamp - lastBonus) / 15 minutes;
            coins += (bonus < _coinRate ? bonus : _coinRate);
        }

        if (coins > 0) {
            _transferCoinsFrom(_this, addr, coins);
        }

        if (value > 0) {            
            Address.sendValue(payable(addr), value);
        }

        return (coins, value);
    }

    function _addValue(uint256 value) private {
        _addValue(_this, value, 0);
    }

    function _addValue(address addr, uint256 value, uint256 coins) private {
        Distribution storage d = _distributions[addr];
        d.value += value;
        d.coins += coins;
        emit PendingDistribution(addr, value, coins);
    }

    function _addDistribution(address addr, uint256 value, uint256 coins) internal {
        uint256 chargeRate = _incrementalValue;
        uint256 transferRate = _transferRate;
        uint256 incrementalValue = value / chargeRate;
        uint256 valueRate = transferRate - chargeRate;
        _addValue(incrementalValue * valueRate);
        _addValue(addr, incrementalValue * transferRate, coins);
    }

    function _createValue(uint256 tokenId, uint256 value) internal {        
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

    /// @dev    Adds Value to the specified Token using the contract's available balance.
    /// @param  tokenId The ID of the Token to add Value to
    /// @param  value The Value to add to the Token
    function createValue(uint256 tokenId, uint256 value) public payable admin {
        _createValue(tokenId, value);
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
    /// @param  coinAddress The address of the ERC20 contract to use as Coins
    /// @param  coinDecimals The number of decimals used in the ERC20 contract, to the power of 10 (ex: 10 ** 18)
    /// @param  utilityAddress Link Utility contract address
    /// @param  chargeRate Represents a number of values:
    ///                    The maximum number of bonus Coins a user can withdraw.
    ///                    The multiplier used when determining the number of Coins required to update a Token URI.
    ///                    The multiplier used when determining the number of Coins required to link a Token with an efficiency greater than 100.
    ///                    The minimum Value used to charge a Token, update a Token URI, or skip executing Links (* 1k gwei)
    /// @param  transferRate The Value to be distributed when a Token is Activated as a percentage of the chargeRate (* 1k gwei)
    function configure(address coinAddress, uint256 coinDecimals, address utilityAddress, uint256 chargeRate, uint256 transferRate) public admin {
        require(chargeRate > 0 && transferRate <= chargeRate && transferRate >= (chargeRate / 2));

        _erc20 = IERC20(coinAddress);
        _erc20.approve(_this, ~uint256(0));
        _coinDecimals = coinDecimals;
        _coinRate = chargeRate;

        _linkUtility = DigilLinkUtility(utilityAddress);

        _incrementalValue = chargeRate * 1000 gwei;
        _transferRate = transferRate * 1000 gwei;
        
        emit Configure(coinAddress, utilityAddress);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal enabled override
    {
        super._beforeTokenTransfer(from, to, tokenId);
        _notOnBlacklist(from);
        _notOnBlacklist(to);
    }

    function _approvedOrOwner(uint256 tokenId) private view returns(bool) {
        return _isApprovedOrOwner(_msgSender(), tokenId);
    }

    modifier approved(uint256 tokenId) {
        require(_approvedOrOwner(tokenId));
        _;
    }

    function _whenNotPaused() private view {
        require(_paused == false);
    }

    modifier senderEnabled() {
        _whenNotPaused();
        _notOnBlacklist(_msgSender());
        _;
    }

    modifier operatorEnabled(address account) {
        _whenNotPaused();
        _notOnBlacklist(account);
        _;
    }

    modifier enabled() {
        _whenNotPaused();
        _;
    }

    /// @dev Pause the contract
    function pause() public admin {
        _paused = true;
        emit Pause(_msgSender());
    }

    /// @dev Unpause the contract
    function unpause() public admin {
        _paused = false;
        emit Unpause(_msgSender());
    }

    // Blacklist
    function _notOnBlacklist(address account) internal view {
        require(!_blacklisted[account]);
    }

    function _blacklist(address account) private {
        _blacklisted[account] = true;
        emit Blacklist(account, false);
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
        require(value >= _coinRate / 2 * _incrementalValue);
        _blacklist(_msgSender());
        _addValue(value);
    }

    /// @dev    Remove account from Blacklist.
    /// @param  account The address to Whitelist
    function whitelist(address account) public admin {
        _blacklisted[account] = false;
        emit Blacklist(account, true);
    }

    // Coin
    function _transferCoins(address account, uint256 coins) internal returns(bool) {
        return _erc20.transfer(account, coins * _coinDecimals);
    }

    function _coinsFromSender(uint256 coins) internal returns(bool) {
        return _transferCoinsFrom(_msgSender(), _this, coins);
    }

    function _transferCoinsFrom(address from, address to, uint256 coins) internal returns(bool) {
        return _erc20.transferFrom(from, to, coins * _coinDecimals);
    } 

    /// @dev    When an ERC721 token is sent to this contract, creates a new Token representing the token received.
    ///         The Incremental Value of the Token is set to the Minimum Non-Zero Incremental Value,
    ///         with an Activation Threshold of 0, and Activate On Charge set to false.
    ///         The account (ERC721 contract address), and external token ID are appended to the Token URI as a query string.
    ///         Any data sent is stored with the Token and forwarded during Safe Transfer when returnToken is called.
    /// @param  operator The address which called safeTransferFrom on the ERC721 token contract
    /// @param  from The previous owner of the ERC721 token
    /// @param  tokenId The ID of the ERC721 token
    /// @param  data Optional data sent from the ERC721 token contract
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external operatorEnabled(operator) returns (bytes4) {
        address account = _msgSender();
        ERC721 erc721 = ERC721(account);

        _notOnBlacklist(account);
        require(account != _this && _getContractToken(account, tokenId, false).externalTokenId == 0);

        uint256 internalTokenId = _createToken(from, _incrementalValue, 0, data);        
        _contractTokenAlias[erc721].push(ContractToken(tokenId, internalTokenId, false));      
        
        Token storage t = _tokens[internalTokenId];
        t.uri = string(abi.encodePacked(tokenURI(internalTokenId), "?account=", account, "&tokenId=", tokenId));
        t.contributors.push(account);

        return this.onERC721Received.selector;
    }

    /// @notice Return the Contract Token to the current owner. The Token the Contract Token is attached to must have been discharged.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value.
    function returnToken(address account, uint256 tokenId) public payable {
        ContractToken memory contractToken = _getContractToken(account, tokenId, true);
        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;
        require (contractToken.returnable && value >= t.incrementalValue);
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
    function _baseURI() internal pure override returns (string memory) {
        return "https://digil.co.in/token/";
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
    /// @param  tokenId The ID of the token whose Value and Data is to be returned
    /// @return value The current Value the Token
    /// @return charge The current Charge of the Token
    /// @return chargedValue The Value of the Token derived from the Token's Charge (Charge * Incremental Value)
    /// @return data The Token's Data
    function tokenData(uint256 tokenId) public view tokenExists(tokenId) returns(uint256 value, uint256 charge, uint256 chargedValue, bytes memory data) {
        Token storage t = _tokens[tokenId]; 
        return (t.value, t.charge, t.charge * t.incrementalValue, t.data);
    }

    // Token
    modifier requireIncrementalValue(uint256 tokenId) {
        uint256 value = msg.value;
        require(value >= _incrementalValue && value >= _tokens[tokenId].incrementalValue);
        _;
    }

    function _tokenExists(uint256 tokenId) private view {
        require(_exists(tokenId));
    }

    modifier tokenExists(uint256 tokenId) {
        _tokenExists(tokenId);
        _;
    }

    // Create Token
    function _createToken(address creator, uint256 incrementalValue, uint256 activationThreshold, bytes calldata data) internal operatorEnabled(creator) returns(uint256) {        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(creator, tokenId);

        emit Create(tokenId);
        _updateToken(tokenId, incrementalValue, activationThreshold, "", false, data, true);

        return tokenId;
    }

    /// @notice Creates a new Token
    /// @dev    Data stored with the Token cannot be udpated.
    /// @param  incrementalValue the Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a multiple of the default Incremental Value
    /// @param  activationThreshold the number of Coins required for the Token to be Activated
    /// @param  data Optional data to store with the Token
    function createToken(uint256 incrementalValue, uint256 activationThreshold, bool whitelistEnabled, bytes calldata data) public payable returns(uint256) {
        address addr = _msgSender();
        uint256 tokenId = _createToken(addr, incrementalValue, activationThreshold, data);
        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;
        if (whitelistEnabled) {
            require(value >= t.incrementalValue && value >= _incrementalValue);
            emit Whitelist(addr, tokenId, true);
        }
        if (value > 0) {
            _createValue(tokenId, value);
        }
        t.whitelistEnabled = whitelistEnabled;
        t.contributions[addr].whitelisted = true;
        return tokenId;
    }

    /// @dev    Add accounts to a Token's Whitelist.
    /// param   tokenId The ID of the 
    /// @param  accounts The addresses to Whitelist
    /// @param  whitelistEnabled A boolean indicating whether a Token's Whitelist is enabled
    function whitelistToken(uint256 tokenId, address[] memory accounts, bool whitelistEnabled) public payable approved(tokenId) {
        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];
        bool whitelistWasEnabled = t.whitelistEnabled;
        if (whitelistEnabled && !whitelistWasEnabled) {
            require(value >= t.incrementalValue && value >= _incrementalValue);
        }
        if (value > 0) {
            _createValue(tokenId, value);
        }
        t.whitelistEnabled = whitelistEnabled;        
        mapping(address => TokenContribution) storage contributions = t.contributions;
        uint256 accountIndex;
        uint256 accountsLength = accounts.length;
        for (accountIndex; accountIndex < accountsLength; accountIndex++) {
            address account = accounts[accountIndex];
            contributions[account].whitelisted = true;
            emit Whitelist(account, tokenId, whitelistEnabled);
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
    ///             A Value sent of at least the Token's Incremental Value plus the default Incremental Value
    /// @param  tokenId The ID of the Token to Update
    /// @param  incrementalValue The Value (in wei), required to be sent with each Coin used to Charge the Token. Can be 0 or a multiple of the default Incremental Value
    /// @param  activationThreshold The number of Coins required for the Token to be Activated
    function updateToken(uint256 tokenId, uint256 incrementalValue, uint256 activationThreshold, string calldata uri) public payable approved(tokenId) {
        Token storage t = _tokens[tokenId];
        bool haveCharge = t.charge > 0;
        uint256 tChargeRate = t.incrementalValue;

        require(tChargeRate == incrementalValue && haveCharge || !haveCharge);
        require(t.activationThreshold == activationThreshold || !haveCharge);

        bool overwriteUri = bytes(uri).length > 0;
        if (overwriteUri && !_ownerIsSender()) {
            require(_transferCoinsFrom(_msgSender(), _this, _coinRate * 2500));
        }

        uint256 value = msg.value;
        uint256 minimumValue = overwriteUri ? (tChargeRate + _incrementalValue) : 0;
        require(value >= minimumValue);

        _addValue(value);
        _updateToken(tokenId, incrementalValue, activationThreshold, uri, overwriteUri, bytes(""), false);
    }

    // Destroy Token
    function _destroy(uint256 tokenId) internal approved(tokenId) {
        _distribute(tokenId, true);

        delete _tokens[tokenId];

        _burn(tokenId);
    }

    /// @notice Destroy (burn), an existing Token.
    ///         Any Contributed Value that has not yet been Distributed will be returned to its Contributors, any additional Token Value to its owner.
    ///         Requires a Value sent greater than or equal to the larger of the Token's Incremental Value or the default Incremental Value to be Destroyed.
    /// @param  tokenId The ID of the Token to Destroy
    function destroyToken(uint256 tokenId) public payable senderEnabled approved(tokenId) {
        uint256 value = msg.value;
        require(value >= _incrementalValue && value >= _tokens[tokenId].incrementalValue);
        _destroy(tokenId);
        _addValue(value);
    }

    // Charging and Discharging Tokens
    function _charge(uint256 tokenId, uint256 value) internal tokenExists(tokenId) {
        _tokens[tokenId].charge += value;
        emit Charge(tokenId);
    }

    function _discharge(uint256 tokenId, uint256 value) internal tokenExists(tokenId) {
        _tokens[tokenId].charge -= value;
        emit Update(tokenId);
    }

    /// @notice Discharge an existing Token. 
    ///         If the Token is Active: Any Contributed Value that has not yet been Distributed will be Distributed.
    ///         If the Token is Inactive: Any Contributed Value that has not yet been Distributed will be returned to its Contributors, any additional Token Value to its owner.
    ///         Requires a Value sent greater than or equal to the larger of the Token's Incremental Value or the default Incremental Value.
    /// @param  tokenId The ID of the Token to Discharge
    function dischargeToken(uint256 tokenId) public payable approved(tokenId) {
        uint256 value = msg.value;
        Token storage t = _tokens[tokenId];
        require(value >= _incrementalValue && value >= t.incrementalValue);
        _distribute(tokenId, !t.active);
        _addValue(value);
    }

    /// @notice Charge Token.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value for each Coin.
    /// @param  tokenId The ID of the Token to Charge
    /// @param  coins The Coins used to Charge the Token 
    function chargeToken(uint256 tokenId, uint256 coins) public payable {
        chargeToken(_msgSender(), tokenId, coins, true);
    }

    /// @notice Charge Token on behalf of a contributor.
    ///         Requires a Value sent greater than or equal to the Token's Incremental Value for each Coin,
    ///         and or to avoid Link execution (generate or distribute bonus Coins), a Value greater than or equal to the default Incremental Value.
    /// @param  contributor The address to record as the contributor of this Charge
    /// @param  tokenId The ID of the Token to Charge
    /// @param  coins The Coins used to Charge the Token
    /// @param  executeLinks A boolean indicating whether to skip automatic Token Activation or Link execution
    function chargeToken(address contributor, uint256 tokenId, uint256 coins, bool executeLinks) public payable operatorEnabled(contributor) {
        Token storage t = _tokens[tokenId];
        TokenContribution storage c = t.contributions[contributor];
        require(!t.whitelistEnabled || c.whitelisted);
        
        uint256 value = msg.value;
        uint256 contribution = t.incrementalValue * coins;
        require(value >= contribution && coins > 0);

        _coinsFromSender(coins);
        _charge(tokenId, coins);
        
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

        if (t.charge > 0) {
            if (!executeLinks) {
                require(value >= _incrementalValue);
            } else {
                _executeLinks(tokenId, false);
            }
        }
    }

    // Token Activation
    function _activate(uint256 tokenId) internal approved(tokenId) {
        Token storage t = _tokens[tokenId];
        require(t.active == false && t.charge >= t.activationThreshold);

        t.active = true;
        emit Activate(tokenId);

        _distribute(tokenId, false);

        if (t.charge > 0) {
            _executeLinks(tokenId, true);
        }
    }

    /// @notice Activate an Inactive Token, Distributes Value, Coins, and execute Links.
    ///         Requires the Token have a Charge greater than or equal to the Token's Activation Threshold.
    /// @param  tokenId The ID of the Token to activate.
    function activateToken(uint256 tokenId) public senderEnabled {
        _activate(tokenId);
    }

    /// @notice Deactivates an Active Token.
    ///         Requires the Token have zero Charge, and a Value sent greater than or equal to the Token's Incremental Value.
    /// @param  tokenId The ID of the token to Deactivate
    function deactivateToken(uint256 tokenId) public payable senderEnabled {
        Token storage t = _tokens[tokenId];
        uint256 value = msg.value;
        require(t.active == true && t.charge == 0 && value >= t.incrementalValue);

        t.active = false;       
        emit Update(tokenId);

        _addValue(value);
    }

    // Token Distribution
    function _distribute(uint256 tokenId, bool destroy) internal {
        Token storage t = _tokens[tokenId];

        address tokenOwner = ownerOf(tokenId);

        uint256 tValue = t.value;
        t.value = 0;

        uint256 distribution;
        uint256 cIndex;
        uint256 cLength = t.contributors.length;
        uint256 incrementalValue = tValue / (t.charge + 1);
        for (cIndex; cIndex < cLength; cIndex++) {
            address contributor = t.contributors[cIndex];
            TokenContribution storage contribution = t.contributions[contributor];
            bool distributed = contribution.distributed;
            contribution.distributed = true;
            ContractToken storage contractToken = _getContractToken(contributor, tokenId, false);
            if (contractToken.internalTokenId != 0) {
                contractToken.returnable = true;
            } else if (!distributed) {
                uint256 contributedValue = contribution.value;
                uint256 contributedCharge = contribution.charge;
                if (destroy) {
                    _addValue(contributor, contributedValue, contributedCharge);
                } else {
                    distribution += contributedValue;                    
                    uint256 distributableTokenValue = incrementalValue * contributedCharge;
                    tValue -= distributableTokenValue;
                    _addValue(contributor, distributableTokenValue, 1);
                }
            }
        }

        if (destroy) {
            _addDistribution(tokenOwner, tValue, 0);
        } else {
            _addDistribution(tokenOwner, distribution, 0);
            _addValue(tValue);
        }
    }

    // Token Linking
    function _executeLinks(uint256 tokenId, bool discharge) internal tokenExists(tokenId) {
        Token storage t = _tokens[tokenId];
        TokenLink[8] memory links = _linkUtility.getLinkValues(tokenId, discharge, t.links, t.charge * _coinDecimals);

        uint256 linkIndex;
        uint256 linksLength = links.length;
        for (linkIndex; linkIndex < linksLength; linkIndex++) {
            TokenLink memory link = links[linkIndex];
            uint256 sourceId = link.source;
            uint256 destinationId = link.destination;
            if (destinationId == 0) {
                break;
            }
            uint256 value = link.value;
            if (value > 0) {
                value = value / _coinDecimals;                
                if (value > 0 && sourceId != 0) {
                    _discharge(sourceId, value);
                } else if (value == 0) {
                    value = 1;
                }
                _charge(destinationId, value + link.efficiency / _coinDecimals);
            }
        }
    }

    function _link(uint256 tokenId, uint256 source, uint256 destination, uint256 efficiency, uint256 probability) internal {
        TokenLink[] storage links = _tokens[tokenId].links;
        TokenLink memory link = TokenLink(source, destination, 0, efficiency, probability);
        links.push(link);
        emit Link(tokenId, destination, efficiency, probability);
    }

    function _linkRate(uint256 rate, uint256 cutoff) internal pure returns(uint256) {
        uint256 e = rate > cutoff ? rate - cutoff : 0;
        return rate + (e * (e + 1) / 2);
    }

    /// @notice Links two Tokens together in order to generate or transfer Coins on Charge or Token Activation.
    ///         A Link between Tokens (from source to destination) must not already exist, and both Tokens must have less than 8 Links each.
    ///         Requires a Value greater than or equal to the larger of the source or destination Token's Incremental Value.
    ///         Any Value contributed is split between and added to the source and destination Token.
    ///         Requires a summation of Coins at the Coin Rate depending on the Link Efficiency (>1) and Probability (>64).
    ///         Maximum Efficiency is 512. An Efficiency of 1 is meant to indicate a Coin generation or transfer of 1%. 200 would be 200% et. cetera.
    ///         Maximum Probability is 255. A Probability of 64 is meant to indicate a 25% (64/256) chance that the Link will generate or transfer Coins.
    ///         The default Links are also determined by the Link Utility contract, which is meant to provide bonus Coins without manual linking.
    /// @param  tokenId The ID of the Token to Link (source)
    /// @param  linkId The ID of the Token to Link to (destination)
    /// @param  efficiency The Efficiency of the Token Link
    /// @param  probability The Probability that the Token Link will execute
    /// @param  linkDefaults Boolean used to indicate whether the default Links should be added to the Token if they haven't been already  
    function linkToken(uint256 tokenId, uint256 linkId, uint256 efficiency, uint256 probability, bool linkDefaults) public payable senderEnabled approved(tokenId) {
        require(tokenId != linkId);
        
        Token storage t = _tokens[tokenId];
        Token storage d = _tokens[linkId];

        uint256 value = msg.value;
        uint256 tIncrementalValue = t.incrementalValue;
        require(value >= tIncrementalValue && tIncrementalValue >= d.incrementalValue);
        require(efficiency <= 512 && probability < 256);
        if (value > 0) {
            _createValue(tokenId, value / 2);
            _createValue(linkId, value / 2);
        }

        _coinsFromSender((_linkRate(efficiency, 1) + _linkRate(probability, 64)) * _coinRate);
        
        TokenLink[] storage links = t.links;
        uint256 linksLength = links.length;
        if (linksLength == 0 && linkDefaults) {
            TokenLink[] memory defaultLinks = _linkUtility.getDefaultLinks(tokenId);
            linksLength = defaultLinks.length;
            for(uint256 linkIndex; linkIndex < linksLength; linkIndex++) {
                TokenLink memory link = defaultLinks[linkIndex];
                _link(tokenId, link.source, link.destination, link.efficiency, link.probability);
            }
        }

        bool alreadyLinked;
        for(uint256 linkIndex; linkIndex < linksLength; linkIndex++) {
            alreadyLinked = alreadyLinked || links[linkIndex].destination == linkId;
        }

        require(!alreadyLinked && linksLength < 8 && d.links.length < 8);
        
        _link(tokenId, tokenId, linkId, efficiency, probability);
    }

    /// @notice Unlinks Tokens
    /// @dev    Tokens with ID 0 or 1 cannot be Unlinked
    /// @param  tokenId The ID of the Token to Unlink (source)
    /// @param  linkId The ID of the Token to Unlink (destination)
    function unlinkToken(uint256 tokenId, uint256 linkId) public senderEnabled approved(tokenId) {
        require(linkId > 1 && tokenId != linkId);
        TokenLink[] storage links = _tokens[tokenId].links;
        uint256 linkIndex;
        uint256 linksLength = links.length;
        for (linkIndex; linkIndex < linksLength; linkIndex++) {
            TokenLink storage link = links[linkIndex];
            if (link.destination == linkId) {
                links[linkIndex] = links[linksLength - 1];
                links.pop();
                emit Unlink(tokenId, linkId);
                break;
            }
        }
    }   
}
