// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import "remix_tests.sol";
import "remix_accounts.sol";
import "../contracts/DigilCoin.sol";

contract DigilCoinTest is DigilCoin {

    address acc0 = TestsAccounts.getAccount(0);
    address acc1;
    address acc2;
    address acc3;
    address acc4;

    constructor() DigilCoin(acc0) {
        
    }

    function beforeAll() public {
        acc1 = TestsAccounts.getAccount(1);
        acc2 = TestsAccounts.getAccount(2);
        acc3 = TestsAccounts.getAccount(3);
        acc4 = TestsAccounts.getAccount(4);
    }

    function testTokenInitialValues() public {
        Assert.equal(name(), "Digil Coin", "token name did not match");
        Assert.equal(symbol(), "DIGIL", "token symbol did not match");
        Assert.equal(decimals(), 18, "token decimals did not match");
        Assert.equal(totalSupply(), 0, "token supply should be 0");
    }

    function testTokenMinting() public {
        Assert.equal(balanceOf(acc0), 0 , "token balance should be 0 initially");
        mint(acc0, 10000);
        Assert.equal(balanceOf(acc0), 10000, "token balance did not match");
    }

    function testTotalSupply() public {
        Assert.equal(totalSupply(), 10000, "total supply did not match");
    }

    function testTokenTransfer() public {
        Assert.equal(balanceOf(acc1), 0, "token balance should be zero initially");
        approve(acc0, 500);
        transferFrom(acc0, acc1, 500);
        Assert.equal(balanceOf(acc0), 9500, "token balance did not match");
        Assert.equal(balanceOf(acc1), 500, "token balance did not match");
    }

    /// #sender: account-1
    function testTokenTransferToOtherAddress() public {
        Assert.equal(balanceOf(acc1), 500, "acc1 token balance did not match");
        approve(acc1, 100);
        transferFrom(acc1, acc2, 100);
        Assert.equal(balanceOf(acc1), 400, "acc1 token balance did not match");
        Assert.equal(balanceOf(acc2), 100, "acc2 token balance did not match");
    }
}

