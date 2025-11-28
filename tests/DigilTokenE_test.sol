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
contract EchoTestSuite {
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

    /// #sender: account-4
    /// #value: 1011000000000000000
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

        digil.chargeToken{value: 1000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 10000 * 10 ** 18, "Coins from distribution should be 10000 bonus for value");
        Assert.equal(withdrawlValue, 950000000000000000, "Distributed value should be 95% of 1000000000000000000");
    }

    /// #sender: account-4
    /// #value: 5100000000000000
    function testLinkRestrictedToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve coins for charging
        bool approved = coins.approve(address(digil), 3000 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        // Create source and restricted linked tokens
        uint256 sourceTokenId = digil.createToken(0, 0, false, 4, "Source Token");
        uint256 restrictedTokenId = digil.createToken{value: incrementalValue}(incrementalValue, 0, true, 5, "Restricted Linked Token");
        
        // Link the tokens
        digil.linkToken{value: incrementalValue}(sourceTokenId, restrictedTokenId, 10);

        // Verify link exists
        ( , , , , uint256 links, , , , ) = digil.tokenData(sourceTokenId);
        Assert.equal(links, 2, "Link not added"); // Plane link + new link
        
        // Activate both tokens
        digil.activateToken(sourceTokenId);
        digil.activateToken(restrictedTokenId);
        
        digil.chargeToken(sourceTokenId, coinMultiplier * 2);

        (uint256 sourceCharge, uint256 sourceActiveCharge, uint256 sourceValue, , ) = digil.tokenCharge(sourceTokenId);
        Assert.equal(sourceCharge, 0, "Invalid Source charge");
        Assert.equal(sourceActiveCharge, coinMultiplier / 100 * 10, "Invalid Source active charge");
        Assert.equal(sourceValue, 0, "Invalid Source value");

        (uint256 restrictedCharge, uint256 restrictedActiveCharge, uint256 restrictedValue, , ) = digil.tokenCharge(restrictedTokenId);
        Assert.equal(restrictedCharge, 0, "Invalid Restricted charge");
        Assert.equal(restrictedActiveCharge, 0, "Invalid Restricted active charge");
        Assert.equal(restrictedValue, 0, "Invalid Restricted value");

        // Unlink tokens
        digil.unlinkToken(sourceTokenId, restrictedTokenId);
        
        // Verify link removed
        ( , , , , links, , , , ) = digil.tokenData(sourceTokenId);
        Assert.equal(links, 1, "Link not removed"); // Only plane link remains
    }

    /// #sender: account-5
    /// #value: 20000000000000000
    function testSetOptStatus() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        bool approved = coins.approve(address(digil), coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(0, 0, false, 4, "Opt Out Charge Test");

        digil.setOptStatus{value: incrementalValue * 100}(true);

        // Attempt to create a token (should fail)
        try digil.createToken(0, 0, false, 4, "Create Token Fail") {
            Assert.ok(false, "Opted out user should not be able to create a token");
        } catch {
            Assert.ok(true, "Opted out user should not be able to create a token");
        }

        // Attempt to charge the token (should fail)
        try digil.chargeToken(tokenId, coinMultiplier) {
            Assert.ok(false, "Opted out user should not be able to charge token");
        } catch {
            Assert.ok(true, "Correctly prevented opted out user from charging");
        }

        digil.setOptStatus{value: incrementalValue * 100}(false);

        // Attempt to create a token (should succeed)
        try digil.createToken(0, 0, false, 4, "Create Token Success") {
            Assert.ok(true, "Opted in user should be able to create a token");
        } catch {
            Assert.ok(false, "Opted in user should be able to create a token");
        }

        // Charge the token (should succeed)
        try digil.chargeToken(tokenId, coinMultiplier) {
            Assert.ok(true, "Opted in user should be able to charge token");
        } catch {
            Assert.ok(false, "Opted in user should be able to charge token");
        }
        (uint256 charge, , , , ) = digil.tokenCharge(tokenId);
        Assert.equal(charge, coinMultiplier, "Token should be charged after opting back in");
    }

    /// #sender: account-5
    /// #value: 200000000000000
    function testDeactivateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        uint256 tokenId = digil.createToken(incrementalValue, 0, false, 4, "Deactivate Test");
    
        // Activate the token (assuming zero activation threshold allows immediate activation)
        digil.activateToken(tokenId);
        
        // Deactivate the token
        digil.deactivateToken(tokenId);
        
        // Verify deactivation
        (bool isActive, , , , , , , , ) = digil.tokenData(tokenId);
        Assert.ok(!isActive, "Token should be deactivated");

        // Charge the token
        bool approved = coins.approve(address(digil), coinMultiplier);
        Assert.ok(approved, "Coin approval failed");
        digil.chargeToken{value: 100000000000000}(tokenId, coinMultiplier);

        // Activate the token
        digil.activateToken(tokenId);
    }
}