// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.31;

import {ERC721} from "@openzeppelin/contracts@5.1.0/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts@5.1.0/token/ERC721/IERC721Receiver.sol";

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