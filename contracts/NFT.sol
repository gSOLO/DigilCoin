// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.29;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract NFT is ERC721, Ownable, IERC721Receiver {
    constructor(address initialOwner) ERC721("NFT Token", "NFT") Ownable(initialOwner) {

    }

    function mint(address to, uint256 tokenId) public onlyOwner {
        _mint(to, tokenId);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}