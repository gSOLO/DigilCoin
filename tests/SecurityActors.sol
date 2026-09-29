// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IDigilCoin} from "../contracts/IDigilCoin.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract FeeSpender {
    function pay(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.spendFrom(payer, amount));
    }

    function deposit(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.transferFrom(payer, address(this), amount));
    }

    function refund(IDigilCoin coin, address payer, uint256 amount) external {
        require(coin.transfer(payer, amount));
    }
}

contract CallbackActor is IERC721Receiver {
    bool public rejectEth;
    bool public rejectNft;
    bool public attempted;
    bool public reentered;
    address public callbackTarget;
    bytes public callbackData;

    function configure(bool ethFailure, bool nftFailure, address target, bytes calldata data) external {
        rejectEth = ethFailure;
        rejectNft = nftFailure;
        callbackTarget = target;
        callbackData = data;
        attempted = false;
        reentered = false;
    }

    function execute(address target, bytes calldata data) external payable returns (bytes memory result) {
        bool success;
        (success, result) = target.call{value: msg.value}(data);
        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    function forceEth(address payable target) external payable {
        new ForcedEth{value: msg.value}(target);
    }

    function _callback() private {
        if (callbackTarget != address(0) && !attempted) {
            attempted = true;
            (reentered,) = callbackTarget.call(callbackData);
        }
    }

    receive() external payable {
        require(!rejectEth, "test receiver rejects ETH");
        _callback();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectNft, "test receiver rejects NFT");
        _callback();
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ForcedEth {
    constructor(address payable target) payable {
        // Constructor-only destruction tests ETH arriving without receive/donate.
        selfdestruct(target);
    }
}

contract FailingCoin is ERC20 {
    bool public failMint;
    bool public failTransfer;

    constructor() ERC20("Failure fixture", "FAIL") {}

    function setFailures(bool mintFailure, bool transferFailure) external {
        failMint = mintFailure;
        failTransfer = transferFailure;
    }

    function mint(address to, uint256 amount) external {
        require(!failMint, "test mint failure");
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transferFrom(from, to, amount);
    }

    function spendFrom(address payer, uint256 amount) external returns (bool) {
        _spendAllowance(payer, msg.sender, amount);
        _transfer(payer, msg.sender, amount);
        return true;
    }

    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}
