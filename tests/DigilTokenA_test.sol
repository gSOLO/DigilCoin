// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

// This import is automatically injected by Remix
import "remix_tests.sol"; 

// This import is required to use custom transaction context
// Although it may fail compilation in 'Solidity Compiler' plugin
// But it will work fine in 'Solidity Unit Testing' plugin
import "remix_accounts.sol";

import "../contracts/IDigilToken.sol";
import "../contracts/DigilTestLibrary.sol";

// File name has to end with '_test.sol', this file can contain more than one testSuite contracts
contract AlphaTestSuite {
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

    /// #sender: account-0
    /// #value: 1011000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken(1000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 1 * 10 ** 18, "First withdrawl should be 1 coin");
        Assert.equal(withdrawlValue, 0, "First withdrawl should be 0 value");

        balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 1 * 10 ** 18, "Coin balance should be 1 coin");

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 10 * 10 ** 18, "Coins from distribution should be 10 bonus for value");
        Assert.equal(withdrawlValue, 950000000000000, "Distributed value shopuld be 95% of 1000000000000000");

        balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 10 * 10 ** 18, "Coin balance should be 10 coins");

        tokenId = digil.createToken(10000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 10000 * 10 ** 18, "Coins from distribution should be 10000 bonus for value");
        Assert.equal(withdrawlValue, 950000000000000000, "Distributed value should be 95% of 1000000000000000000");
    }

    /// #sender: account-0
    function testCreateToken() public {
        uint256 incrementalValue = 100000000000000;
        uint256 activationThreshold = 100000000000000000;
        uint256 plane = 4;                    
        bytes memory data = "Test Token";

        uint256 balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 2, "Token balance should be 2"); // Form Withdraw

        uint256 tokenId = digil.createToken(incrementalValue, activationThreshold, false, plane, data);

        balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 3, "Token balance should be 3");
       
        (bool active, bool activating, bool discharging, bool tokenRestricted, uint256 links, uint256 contributors, uint256 contributionEpoch, uint256 distributionIndex, bytes memory tokenData) = digil.tokenData(tokenId);
        Assert.ok(active == false, "Token should be inactive initially");
        Assert.ok(activating == false, "Token should not be activating at creation");
        Assert.ok(discharging == false, "Token should not be discharging at creation");
        Assert.ok(tokenRestricted == false, "Token restriction flag mismatch");
        Assert.ok(links == 1, "Token should have a plane link if plane > 0");
        Assert.ok(contributors == 0, "Token should have no contributors at creation, including creator");
        Assert.ok(contributionEpoch == 0, "Token contribution epoch should be 0 at creation");
        Assert.ok(distributionIndex == 0, "Token should not be distributing");
        Assert.ok(keccak256(data) == keccak256(tokenData), "Token data should be unmodified");
    }

    /// #sender: account-0
    function testChargeToken() external payable {
        uint256 coinMultiplier = 10 ** 18;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 10 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(0, 10 * coinMultiplier, false, 4, "Test Charge");

        (uint256 initialCharge, , , , ) = digil.tokenCharge(tokenId);

        digil.chargeToken(tokenId, coinMultiplier);

        (uint256 newCharge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= initialCharge + coinMultiplier, "Token charge did not increase appropriately(1)");

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            digil.chargeTokenAs{value: 100000000000000}(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }

        (uint256 fullCharge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(fullCharge >= newCharge + coinMultiplier * 9, "Token charge did not increase appropriately (10)");

        (uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold) = digil.tokenCharge(tokenId);
        Assert.ok(charge == fullCharge, "Token should be at full charge");
        Assert.ok(activeCharge == 0, "Active charge should be 0");
        Assert.ok(value == 100000000000000 * 9, "Value should be 100000000000000 * 9");
        Assert.ok(incrementalValue == 0, "Incremental value should be 0");
        Assert.ok(activationThreshold == fullCharge, "Token should be at activation threshold");
    }

    /// #sender: account-0
    /// #value: 1000000000000000
    function testChargeTokenWithValue() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 10 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Charge With Value");

        (uint256 initialCharge, , uint256 initialValue, , ) = digil.tokenCharge(tokenId);

        digil.chargeToken{value: incrementalValue}(tokenId, coinMultiplier);

        (uint256 newCharge, , uint256 newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= initialCharge + coinMultiplier, "Token charge did not increase appropriately");
        Assert.ok(newValue == initialValue, "Token value should not increase");

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }

        (uint256 finalCharge, , uint256 finalValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(finalCharge >= newCharge + coinMultiplier * 9, "Token charge did not increase appropriately");
        Assert.ok(finalValue == newValue, "Token value should not increase");
    }

    /// #sender: account-0
    /// #value: 1000000000000000
    function testChargeTokenWithIncreasedValue() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Charge With Increased Value");

        (uint256 initialCharge, , uint256 initialValue, , ) = digil.tokenCharge(tokenId);

        digil.chargeToken{value: incrementalValue * 10}(tokenId, coinMultiplier);

        (uint256 newCharge, , uint256 newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= initialCharge + coinMultiplier, "Token charge did not increase appropriately");
        Assert.ok(newValue >= initialValue + incrementalValue * 9, "Token value did not increase appropriately");
    }

    // #sender: account-0
    /// #value: 1700000000000000
    function testDischargeToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 15 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Discharge");

        (uint256 initialCharge, , uint256 initialValue, , ) = digil.tokenCharge(tokenId);

        for (uint256 accountIndex; accountIndex < 15; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }

        (uint256 newCharge, , uint256 newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= initialCharge + coinMultiplier * 15, "Token charge did not increase appropriately");
        Assert.ok(newValue == initialValue, "Token value should not increase");

        (, , , , , , uint256 contributionEpoch, uint256 distributionIndex, ) = digil.tokenData(tokenId);
        Assert.ok(contributionEpoch == 0, "Token contribution epoch in invalid state > 0");
        Assert.ok(distributionIndex == 0, "Token distribution in invalid state > 0");

        while(!digil.dischargeToken{value: incrementalValue}(tokenId)) {
            (, , , , , , , distributionIndex, ) = digil.tokenData(tokenId);
            Assert.ok(distributionIndex > 0, "Token distribution in invalid state (0)");
        }

        (, , , , , , contributionEpoch, distributionIndex, ) = digil.tokenData(tokenId);
        Assert.equal(contributionEpoch, 1, "Token contribution epoch in invalid state != 1");
        Assert.ok(distributionIndex == 0, "Token distribution in invalid state > 0");

        (uint256 finalCharge, , uint256 finalValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(finalCharge == initialCharge, "Token charge did not decrease appropriately");
        Assert.ok(finalValue == initialValue, "Token value should not change");
    }

    // #sender: account-0
    /// #value: 5000000000000000
    function testActivateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 45 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Activate");

        for (uint256 accountIndex; accountIndex < 15; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }
        
        uint256 currentSeed = 1;
        for (uint256 accountIndex = 0; accountIndex < 29; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, tokenId, coinMultiplier);
        }

        (uint256 newCharge, uint256 newActiveCharge, uint256 newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= coinMultiplier * 44, "Token charge did not increase appropriately");
        Assert.ok(newActiveCharge == 0, "Token active charge should not increase");
        Assert.ok(newValue == 0, "Token value should not increase");

        digil.chargeToken{value: incrementalValue * 6}(tokenId, coinMultiplier);

        (newCharge, newActiveCharge, newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= coinMultiplier * 45, "Token charge did not increase appropriately");
        Assert.ok(newActiveCharge == 0, "Token active charge should not increase");
        Assert.ok(newValue == incrementalValue * 5, "Token value did not increase appropriately");

        (bool isActive, bool isActivating, bool isDischarging, , , , , , ) = digil.tokenData(tokenId);
        Assert.ok(!isActive, "Token activation in invalid state (active)");
        Assert.ok(!isActivating, "Token activation in invalid state (activating)");
        Assert.ok(!isDischarging, "Token distribution in invalid state (discharging)");

        bool activationComplete = digil.activateToken(tokenId);
        while(!activationComplete) {
            (, isActivating, , , , , , , ) = digil.tokenData(tokenId);
            Assert.ok(isActivating, "Token activation in invalid state (not activating)");
            activationComplete = digil.activateToken(tokenId);
        }
        (isActive, isActivating, , , , , , , ) = digil.tokenData(tokenId);
        Assert.ok(isActive, "Token activation in invalid state (active == false)");
        Assert.ok(!isActivating, "Token activation in invalid state (activating)");

        (newCharge, newActiveCharge, newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge == 0, "Token charge did not decrease appropriately");
        Assert.ok(newActiveCharge == coinMultiplier * 45, "Token active charge did not increase appropriately");
        Assert.ok(newValue == 0, "Token value should not change");
    }

    // #sender: account-0
    /// #value: 5000000000000000
    function testRestrictToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 4 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken{value: incrementalValue}(incrementalValue, 1 * coinMultiplier, true, 4, "Test Restrict");

        (uint256 charge, , uint256 value, , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == 0, "New token should not be charged");
        Assert.ok(value == incrementalValue, "Restricted token should have value equal to incremental value");

        address nonWhitelisted = TestsAccounts.getAccount(1);
        try digil.chargeTokenAs{value: incrementalValue}(nonWhitelisted, tokenId, coinMultiplier) {
            Assert.ok(false, "Non-whitelisted address should not charge restricted token");
        } catch {
            Assert.ok(true, "Incorrect error for restricted charging");
        }

        (charge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == 0, "Restricted token should not be charged");

        address whitelisted = TestsAccounts.getAccount(2);
        address[] memory whitelist = new address[](1);
        whitelist[0] = whitelisted;
        digil.restrictToken(tokenId, whitelist);
        digil.chargeTokenAs{value: incrementalValue}(whitelisted, tokenId, coinMultiplier);
        (charge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == coinMultiplier, "Whitelisted address should charge restricted token");

        tokenId = digil.createToken(incrementalValue, 1 * coinMultiplier, false, 4, "Test Restrict");

        (charge, , value, , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == 0, "New token should not be charged");
        Assert.ok(value == 0, "Non-restricted token should have no value");

        try digil.chargeTokenAs{value: incrementalValue}(nonWhitelisted, tokenId, coinMultiplier) {
            Assert.ok(true, "Non-whitelisted address should charge non-restricted token");
        } catch {
            Assert.ok(false, "Non-whitelisted address should charge non-restricted token");
        }

        (charge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == coinMultiplier, "Non-restricted token should be charged");

        digil.restrictToken{value: incrementalValue}(tokenId, whitelist);
        (, , value, , ) = digil.tokenCharge(tokenId);
        Assert.ok(value == incrementalValue, "Restricted token should have value equal to incremental value");

        digil.chargeTokenAs{value: incrementalValue}(whitelisted, tokenId, coinMultiplier);
        (charge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(charge == 2 * coinMultiplier, "Whitelisted address should charge restricted token");
    }
}