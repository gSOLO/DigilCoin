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
        uint256 eTokenIndex;
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

    /// @notice Gets the Links for a given Token 
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

        uint256 totalValue;
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
            if (willExecute(link.probability, sourceId, destinationId)) { 
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
                    if (value >= charge) {
                        charge -= value;
                    } else {
                        charge = 0;
                    }
                }                
                totalValue += result.value;                
            }

            results[linkIndex] = result;

            if (linkIndex == 0) {
                break;
            }
        }

        return results;
    }

    /// @notice Determines whether a Token Link overcomes the Probility Threshold
    function willExecute(uint256 probability, uint256 source, uint256 destination) public view returns (bool) {
        if (probability == 0) { return false; }
        uint256 probabilityThreshold = uint256(uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, source, destination))) % 250);
        return probability > probabilityThreshold;
    } 
}