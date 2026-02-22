// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract NFT is ERC721, IERC721Receiver {
    constructor() ERC721("NFT Token", "NFT") {

    }

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }

    function onERC721Received(address /*operator*/, address /*from*/, uint256 /*tokenId*/, bytes calldata /*data*/) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}