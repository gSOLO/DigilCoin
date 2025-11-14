// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

// This import is automatically injected by Remix
import "remix_tests.sol"; 

// This import is required to use custom transaction context
// Although it may fail compilation in 'Solidity Compiler' plugin
// But it will work fine in 'Solidity Unit Testing' plugin
import "remix_accounts.sol";

import "../contracts/IDigilToken.sol";
import "../contracts/DigilTestLibrary.sol";

// File name has to end with '_test.sol', this file can contain more than one testSuite contracts
contract CharlieTestSuite {
    IERC20 public coins;
    IDigilToken public digil;

    receive() external payable {
        
    }

    /// 'beforeAll' runs before all other tests
    /// More special functions are: 'beforeEach', 'beforeAll', 'afterEach' & 'afterAll'
    function beforeAll() public {
        // <instantiate contract>
        coins = DigilTestLibrary.getCoins();
        digil = DigilTestLibrary.getToken();
        Assert.equal(uint(1), uint(1), "1 should be equal to 1");
    }

    /// #sender: account-2
    /// #value: 31011000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken(1000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 100 * 10 ** 18, "First withdrawl should be 100 coins");
        Assert.equal(withdrawlValue, 0, "First withdrawl should be 0 value");

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 10 * 10 ** 18, "Coins from distribution should be 10 bonus for value");
        Assert.equal(withdrawlValue, 950000000000000, "Distributed value shopuld be 95% of 1000000000000000");

        tokenId = digil.createToken(10000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 10000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 100 * 10 ** 18, "Coins from distribution should be 100 bonus for value");
        Assert.equal(withdrawlValue, 9500000000000000, "Distributed value should be 95% of 10000000000000000");

        tokenId = digil.createToken(10000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 30000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 300000 * 10 ** 18, "Coins from distribution should be 300000 bonus for value");
        Assert.equal(withdrawlValue, 28500000000000000000, "Distributed value should be 95% of 30000000000000000000");
    }

    /// #sender: account-2
    /// #value: 600000000000000
    function testUpdateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        bool approved = coins.approve(address(digil), 2 * 1000 * 100 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        // Create a token with initial parameters
        uint256 tokenId = digil.createToken(100000000000000, 1000000000000000000, false, 4, "Update Test");

        // Update token parameters
        digil.updateToken{value: 200000000000000}(tokenId, 200000000000000, 2000000000000000000, "New Data", "New URI");
        
        // Verify updated token charge parameters
        ( , , , uint256 incrementalValue, uint256 activationThreshold) = digil.tokenCharge(tokenId);
        Assert.equal(incrementalValue, 200000000000000, "Incremental value should be updated");
        Assert.equal(activationThreshold, 2000000000000000000, "Activation threshold should be updated");
        
        // Verify updated URI
        string memory uri = digil.tokenURI(tokenId);
        Assert.equal(uri, "New URI", "URI should be updated");

        // Verify updated data 
        (, , , , , , , , bytes memory tokenData) = digil.tokenData(tokenId);
        Assert.ok(keccak256("New Data") == keccak256(tokenData), "Token data should be updated");

        approved = coins.approve(address(digil), coinMultiplier);
        Assert.ok(approved, "Coin approval failed");
        digil.chargeToken{value: incrementalValue}(tokenId, coinMultiplier);

        // Attempt to update the token (should fail)
        try digil.updateToken{value: 200000000000000}(tokenId, 300000000000000, 3000000000000000000, "", "") {
            Assert.ok(false, "Updating token with charge should fail");
        } catch {
            Assert.ok(true, "Incorrect error for updating charged token");
        }
    }
}