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
}

/// @title Digil Link Utility
/// @author gSOLO
/// @notice Utility functions used to retrieve, calculate values, and rates for Token Links 
/// @custom:security-contact security@digil.co.in
contract DigilLinkUtility {
    constructor() {}
    
    /// @notice Gets the default Links for a given Token 
    /// @dev    A Token with an ID of 1 is assumed to be the Void Token, a special token where any unused Charge is drained into when Link Values are being calculated.
    /// @param  tokenId The ID of the Token to get Links for
    /// @return results A collection of Token Links
    function getDefaultLinks(uint256 tokenId) public pure returns (DigilToken.TokenLink[] memory results) {
        if (tokenId >= 18) {
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
    ///         It is assumed that there are a maximum of 8 Token Links passed in (any Token Links after the 8th will not generate Value).
    /// @param  tokenId The ID of the Token to get Link Values for
    /// @param  discharge Boolean indicating whether the Token is being Discharged
    /// @param  links A collection of Links (assumed to be attached to the Token), used to calculate the Link Values
    /// @param  charge The available Charge to generate Value from
    /// @return results A collection of Token Links with Values calculated
    function getLinkValues(uint256 tokenId, bool discharge, DigilToken.TokenLink[] memory links, uint256 charge) external view returns (DigilToken.TokenLink[8] memory results) {
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

        return discharge ? _getDischargeValues(tokenId, links, charge) : _getBonusValues(tokenId, links, charge);
    }

    function _getDischargeValues(uint256 tokenId, DigilToken.TokenLink[] memory links, uint256 charge) internal view returns (DigilToken.TokenLink[8] memory results) {
        uint256 linksLength = uint256(links.length);
        uint256 linkIndex = (linksLength < 8 ? linksLength : 8) - 1;
        for (linkIndex; linkIndex >= 0; linkIndex--) {
            DigilToken.TokenLink memory link = links[linkIndex];

            uint256 efficiency = link.efficiency;
            if (efficiency == 0) {
                continue;
            }

            uint256 destinationId = link.destination;
            uint256 sourceId = link.source;

            uint256 probabilityThreshold = uint256(uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, destinationId, charge))) % 250);
            if (sourceId == tokenId && link.probability > probabilityThreshold) {
                uint256 iCharge = charge / 100;
                bool haveEffieiencyBonus = efficiency > 100;
                if (haveEffieiencyBonus) {
                    results[linkIndex] = DigilToken.TokenLink(sourceId, destinationId, charge, iCharge * (efficiency - 100), 0);
                    charge = 0;
                } else {
                    uint256 value = iCharge * efficiency;
                    results[linkIndex] = DigilToken.TokenLink(sourceId, destinationId, value, 0, 0);
                     if (charge >= value) {
                        charge -= value;
                    } else {
                        charge = 0;
                    }      
                }    
            }

            if (linkIndex == 0) {
                break;
            }
        }

        return results;
    }

    function _getBonusValues(uint256 tokenId, DigilToken.TokenLink[] memory links, uint256 charge) internal view returns (DigilToken.TokenLink[8] memory results) {
        uint256 linksLength = uint256(links.length);
        uint256 linkIndex = (linksLength < 8 ? linksLength : 8) - 1;
        for (linkIndex; linkIndex >= 0; linkIndex--) {
            DigilToken.TokenLink memory link = links[linkIndex];

            uint256 efficiency = link.efficiency;
            if (efficiency == 0) {
                continue;
            }
            
            uint256 probability = link.probability;
            if (probability > 64) {
                probability = 64;
            }

            bool linked;
            uint256 destinationId = link.destination;            
            uint256 probabilityThreshold = uint256(uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, destinationId, charge))) % 250);
            if (probability > probabilityThreshold) { 
                uint256 sourceId = link.source;
                if (tokenId == destinationId) {
                    linked = true;                       
                } else if (sourceId == tokenId) {
                    linked = true;
                    sourceId = destinationId;
                    destinationId = tokenId;
                }
            }

            if (linked) {
                uint256 value = charge / 100 * efficiency;
                results[linkIndex] = DigilToken.TokenLink(0, destinationId, value, 0, 0);
                if (charge >= value) {
                    charge -= value;
                } else {
                    charge = 0;
                }  
            }

            if (linkIndex == 0) {
                break;
            }
        }

        return results;
    }
}
