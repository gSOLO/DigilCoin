// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface DigilToken is IERC721 {
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

    // Information about how much was contributed to a Token's charge
    struct TokenContribution {
        uint256 charge;
        uint256 value;
        bool exists;
        bool distributed;
    }

    // Illustrates the relationship between an external ERC721 token and an internal Token.
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
        bool activateOnCharge;
        bool active;

        TokenLink[] links;
        
        bytes data;
        string uri;
    }
}

/// @custom:security-contact security@digil.co.in
contract DigilLinkUtility {
    constructor() {}
    
    /// @notice Gets the default Links for a given Token 
    /// @dev    A Token with an ID of 1 is assumed to be the Void Token, a special token where any unused charge is drained to when Link Values are being calculated.
    /// @param  tokenId The ID of the Token to get Links for
    /// @return results A collection of Token Links
    function getDefaultLinks(uint256 tokenId) public pure returns (DigilToken.TokenLink[] memory results) {
        if (tokenId >= 16) {
            results = new DigilToken.TokenLink[](3);
            results[0] = DigilToken.TokenLink(tokenId, 1, 0, 100, 255);
            results[1] = DigilToken.TokenLink(2, tokenId, 0, 1, 16);
            results[2] = DigilToken.TokenLink(3, tokenId, 0, 2, 8);
        } else if (tokenId == 3) {
            results = new DigilToken.TokenLink[](2);
            results[0] = DigilToken.TokenLink(tokenId, 1, 0, 100, 255);
            results[1] = DigilToken.TokenLink(2, tokenId, 0, 1, 64);
        } else if (tokenId == 2) {
            results = new DigilToken.TokenLink[](2);
            results[0] = DigilToken.TokenLink(tokenId, 1, 0, 100, 255);
            results[1] = DigilToken.TokenLink(3, tokenId, 0, 2, 32);
        } else if (tokenId > 1) {
            results = new DigilToken.TokenLink[](1);
            results[0] = DigilToken.TokenLink(tokenId, 1, 0, 100, 255);
        } else if (tokenId == 1) {
            results = new DigilToken.TokenLink[](8);
            results[0] = DigilToken.TokenLink(tokenId, 4, 0, 1, 16);
            results[1] = DigilToken.TokenLink(tokenId, 5, 0, 1, 16);
            results[2] = DigilToken.TokenLink(tokenId, 6, 0, 1, 16);
            results[3] = DigilToken.TokenLink(tokenId, 7, 0, 1, 16);            
            results[4] = DigilToken.TokenLink(tokenId, 4, 0, 2, 8);
            results[5] = DigilToken.TokenLink(tokenId, 5, 0, 1, 16);            
            results[6] = DigilToken.TokenLink(tokenId, 6, 0, 1, 16);
            results[7] = DigilToken.TokenLink(tokenId, 7, 0, 2, 8);
        }
    }

    /// @notice Calculates the Value of the Links for a given Token. In the context of a Token Link, Value is in Coins, not Ether (wei).
    /// @dev    If the Token is being Discharged, attempts to use up the entirety of the charge parameter when calculating the Values.
    ///         If the Token is not being Discharged, the Probability of a Link executing is capped to 64 (of 255), any Value generated is essentially a bonus.
    ///         It is assumed that there are a maximum of 16 Token Links passed in (any Token Links after the 16th will not generate Value).
    /// @param  tokenId The ID of the Token to get Link Values for
    /// @param  discharge Boolean indicating whether the Token is being Discharged
    /// @param  links A collection of Links (assumed to be attached to the Token), used to calculate the Link Values
    /// @param  charge The available Charge to generate Value from
    /// @return results A collection of Token Links with Values calculated
    function getLinkValues(uint256 tokenId, bool discharge, DigilToken.TokenLink[] memory links, uint256 charge) external view returns (DigilToken.TokenLink[16] memory results) {
        if (charge == 0) {
            return results;
        }
        
        uint256 linksLength = uint256(links.length);
        if (linksLength == 0) {
            links = getDefaultLinks(tokenId);
            linksLength = uint256(links.length);
        }
        if (linksLength == 0) {
            return results;
        }

        uint256 linkIndex = (linksLength < 16 ? linksLength : 16) - 1;
        uint256 probabilityCap = discharge ? 255 : (64 - linkIndex * 4);
        for (linkIndex; linkIndex >= 0; linkIndex--) {
            DigilToken.TokenLink memory link = links[linkIndex];

            uint256 efficiency = link.efficiency;
            if (efficiency == 0) {
                continue;
            }
            
            if (link.probability > probabilityCap) {
                link.probability = probabilityCap;
            }

            bool linked;
            uint256 destinationId = link.destination;
            uint256 sourceId = link.source;
            if (willExecute(link.probability, sourceId, destinationId, charge)) { 
                if (tokenId == destinationId) {
                    linked = true;                       
                } else if (sourceId == tokenId) {
                    linked = true;
                    sourceId = destinationId;
                    destinationId = tokenId;
                }
            }

            DigilToken.TokenLink memory result = DigilToken.TokenLink(sourceId, destinationId, 0, 0, 0);

            if (linked) {
                bool haveEffieiencyBonus = efficiency > 100;
                uint256 value = charge / 100 * (haveEffieiencyBonus ? 100 : efficiency);
                result.value = value + (charge / 100 * (haveEffieiencyBonus ? efficiency - 100 : 0));
                if (discharge) {
                    if (charge >= value) {
                        charge -= value;
                    } else {
                        charge = 0;
                    }
                }                
            }

            results[linkIndex] = result;

            if (linkIndex == 0) {
                break;
            }
        }

        return results;
    }

    /// @notice Determines whether a Token Link overcomes the Probability Threshold
    /// @dev    While this function is meant to be "random," the fact that it is somewhat deterministic is not terribly important
    ///         as there are various caps in place to limit generated Value, and or it is assumed that any bonuses would have been "paid for" (in Coins)
    /// @param  probability The Probability that the Token Link should be executed
    /// @param  sourceId The ID of the source Token
    /// @param  destinationId The ID of the destination Token
    /// @param  charge The Charge being checked
    /// @return A boolean indicating whether a Token Link should have Value generated from its charge
    function willExecute(uint256 probability, uint256 sourceId, uint256 destinationId, uint256 charge) public view returns (bool) {
        if (probability == 0) { return false; }
        uint256 probabilityThreshold = uint256(uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, sourceId, destinationId, charge))) % 250);
        return probability > probabilityThreshold;
    } 
}
