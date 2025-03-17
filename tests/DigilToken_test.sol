// SPDX-License-Identifier: GPL-3.0
        
pragma solidity >=0.4.22 <0.9.0;

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
    /// #value: 10000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw{value: msg.value}();
        Assert.equal(withdrawlCoins, 100 * 10 ** 18, "First withdrawl should be 100 coins");
        Assert.equal(withdrawlValue, 0, "First withdrawl should be 0 value");

        balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 100 * 10 ** 18, "Coin balance should be 100 coins");
    }

    /// #sender: account-0
    function testCreateToken() public {
        uint256 incrementalValue = 100000000000000;
        uint256 activationThreshold = 100000000000000000;
        bool restricted = false;
        uint256 plane = 4;                    
        bytes memory data = "Test Token";

        uint256 balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 0, "Token balance should be 0");

        uint256 tokenId = digil.createToken(incrementalValue, activationThreshold, restricted, plane, data);

        balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 1, "Token balance should be 1");
       
        (bool active, bool activating, bool discharging, bool tokenRestricted, uint256 links, uint256 contributors, uint256 dischargeIndex, uint256 distributionIndex, bytes memory tokenData) = digil.tokenData(tokenId);
        Assert.ok(active == false, "Token should be inactive initially");
        Assert.ok(activating == false, "Token should not be activating at creation");
        Assert.ok(discharging == false, "Token should not be discharging at creation");
        Assert.ok(tokenRestricted == restricted, "Token restriction flag mismatch");
        Assert.ok(links == 1, "Token should have a plane link if plane > 0");
        Assert.ok(contributors == 0, "Token should have no contributors at creation, including creator");
        Assert.ok(dischargeIndex == 0, "Token should not be discharging");
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
            digil.chargeTokenAs(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }

        (uint256 fullCharge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(fullCharge >= newCharge + coinMultiplier * 9, "Token charge did not increase appropriately (10)");

        (uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold) = digil.tokenCharge(tokenId);
        Assert.ok(charge == fullCharge, "Token should be at full charge");
        Assert.ok(activeCharge == 0, "Active charge should be 0");
        Assert.ok(value == 0, "Value should be 0");
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

        (, , , , , , uint256 dischargeIndex, uint256 distributionIndex, ) = digil.tokenData(tokenId);
        Assert.ok(dischargeIndex == 0 && distributionIndex == 0, "Token distribution in invalid state > 0");

        while(!digil.dischargeToken{value: incrementalValue}(tokenId)) {
            (, , , , , , dischargeIndex, distributionIndex, ) = digil.tokenData(tokenId);
            Assert.ok(dischargeIndex > 0 || distributionIndex > 0, "Token distribution in invalid state (0)");
        }

        (, , , , , , dischargeIndex, distributionIndex, ) = digil.tokenData(tokenId);
        Assert.ok(dischargeIndex == 0 && distributionIndex == 0, "Token distribution in invalid state > 0");

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

contract BetaTestSuite {
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

    /// #sender: account-1
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

    /// #sender: account-0
    /// #value: 55000000000000000
    function testActivateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 515 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Activate");

        for (uint256 accountIndex; accountIndex < 15; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(TestsAccounts.getAccount(accountIndex), tokenId, coinMultiplier);
        }
        
        uint256 currentSeed = 1;
        for (uint256 accountIndex = 0; accountIndex < 499; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, tokenId, coinMultiplier);
        }

        (uint256 newCharge, uint256 newActiveCharge, uint256 newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= coinMultiplier * 514, "Token charge did not increase appropriately");
        Assert.ok(newActiveCharge == 0, "Token active charge should not increase");
        Assert.ok(newValue == 0, "Token value should not increase");

        digil.chargeToken{value: incrementalValue * 6}(tokenId, coinMultiplier);

        (newCharge, newActiveCharge, newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= coinMultiplier * 515, "Token charge did not increase appropriately");
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
        Assert.ok(newActiveCharge == coinMultiplier * 515, "Token active charge did not increase appropriately");
        Assert.ok(newValue == 0, "Token value should reset");
    }

    /// #sender: account-0
    /// #value: 5100000000000000
    function testLinkToken() external payable {
        uint256 coinMultiplier = 10 ** 18;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 9694 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(0, 0, false, 4, "Source Plane");
        (, , , , uint256 links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 1, "Invalid Link Count (!=1)");
        (uint256 charge, uint256 activeCharge, uint256 value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(charge, 0, "Invalid initial Source charge");
        Assert.equal(activeCharge, 0, "Invalid initial Source active charge");
        Assert.equal(value, 0, "Invalid initial Source value");

        uint256 fireTokenId = digil.createToken(0, 0, false, 4, "Fire Destination Plane");
        uint256 airTokenId = digil.createToken(0, 0, false, 5, "Air Destination Plane");
        uint256 earthTokenId = digil.createToken(100000000000000, 0, false, 6, "Earth Destination Plane");
        uint256 waterTokenId = digil.createToken(0, 0, false, 7, "Water Destination Plane");

        digil.linkToken(tokenId, fireTokenId, 10);                           // coins: 1000 base: 10 bonus: 10
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 2, "Invalid Link Count (!=2)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 0, "Invalid initial Fire Destination charge");
        Assert.equal(activeCharge, 0, "Invalid Fire Destination active charge");
        Assert.equal(value, 0, "Invalid initial Fire Destination value");
        
        digil.linkToken(tokenId, airTokenId, 10);                            // coins: 1000 base: 10 bonus: 20
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 3, "Invalid Link Count (!=3)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 0, "Invalid initial Air Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Air Destination active charge");
        Assert.equal(value, 0, "Invalid initial Air Destination value");

        digil.linkToken{value: 100000000000000}(tokenId, earthTokenId, 10);  // coins: 1000 base: 10 bonus: 0
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 4, "Invalid Link Count (!=4)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 0, "Invalid initial Earth Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Earth Destination active charge");
        Assert.equal(value, 50000000000000, "Invalid initial Earth Destination value");

        digil.linkToken(tokenId, waterTokenId, 10);                          // coins: 1000 base: 10 bonus: 0
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 5, "Invalid Link Count (!=5)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 0, "Invalid initial Water Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Water Destination active charge");
        Assert.equal(value, 0, "Invalid initial Water Destination value");

        (, , value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(value, 50000000000000, "Invalid Source value (!=50000000000000)");

        digil.activateToken(tokenId);

        (, , value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(value, 0, "Invalid Source value (!=0)");

        digil.chargeToken(tokenId, coinMultiplier * 5);
        (charge, activeCharge, value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(charge, 0, "Invalid Source charge after first active charge");
        Assert.equal(activeCharge, 300000000000000000, "Invalid Source active charge after first active charge");
        Assert.equal(value, 0, "Invalid Source value after first active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 0, "Invalid Fire charge after first active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 1000000000000000000, "Invalid Air charge after first active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 0, "Invalid Earth charge after first active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 0, "Invalid Water charge after first active charge");

        digil.chargeToken(tokenId, coinMultiplier * 500);

        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 10000000000000000000, "Invalid Fire charge after second active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 11000000000000000000, "Invalid Air charge after second active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 0, "Invalid Earth charge after second active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 10000000000000000000, "Invalid Water charge after second active charge");

        digil.chargeToken{value: 5000000000000000}(tokenId, coinMultiplier * 500);

        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 20000000000000000000, "Invalid Fire charge after third active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 21000000000000000000, "Invalid Air charge after third active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 10000000000000000000, "Invalid Earth charge after third active charge");

        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 20000000000000000000, "Invalid Water charge after third active charge");
    }

    // #sender: account-0
    /// #value: 200000000000000
    function testZeroCharge() external payable {
        uint256 tokenId = digil.createToken(100000000000000, 1000000000000000000, false, 4, "Zero Coins Test");
        
        try digil.chargeToken{value: 100000000000000}(tokenId, 0) {
            Assert.ok(false, "Charging with zero coins should fail");
        } catch {
            Assert.ok(true, "Incorrect error for zero coins");
        }

        tokenId = digil.createToken(100000000000000, 1000000000000000000, false, 4, "Zero Value Test");
        bool approved = coins.approve(address(digil), 1000000000000000000);
        Assert.ok(approved, "Coin approval failed");

        try digil.chargeToken{value: 0}(tokenId, 1000000000000000000) {
            Assert.ok(false, "Charging with zero value should fail");
        } catch {
            Assert.ok(true, "Incorrect error for zero value");
        }
    }
}

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

contract DeltaTestSuite {
    IERC20 public coins;
    IDigilToken public digil;
    uint256 dischargeTokenId;

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

    /// #sender: account-3
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

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testDischargeTokenPartOne() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 350 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        dischargeTokenId = digil.createToken(incrementalValue, 350 * coinMultiplier, false, 4, "Test Discharge");

        uint256 currentSeed = 1;
        for (uint256 accountIndex = 0; accountIndex < 350; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, dischargeTokenId, coinMultiplier);
        }
    }

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testDischargeTokenPartTwo() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 350 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 currentSeed = 350;
        for (uint256 accountIndex = 0; accountIndex < 350; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, dischargeTokenId, coinMultiplier);
        }
    }

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testDischargeTokenPartThree() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 350 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 currentSeed = 700;
        for (uint256 accountIndex = 0; accountIndex < 350; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, dischargeTokenId, coinMultiplier);
        }
    }

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testDischargeTokenPartFour() external payable {
        uint256 incrementalValue = 100000000000000;

        bool dischargeComplete = digil.dischargeToken{value: incrementalValue}(dischargeTokenId);
        while (!dischargeComplete) {
            dischargeComplete = digil.dischargeToken{value: incrementalValue}(dischargeTokenId);
        }

        (, , , , , , uint256 dischargeIndex, uint256 distributionIndex, ) = digil.tokenData(dischargeTokenId);
        Assert.ok(dischargeIndex == 0 && distributionIndex == 0, "Token distribution in invalid state > 0");

        (uint256 finalCharge, , uint256 finalValue, , ) = digil.tokenCharge(dischargeTokenId);
        Assert.ok(finalCharge == 0, "Token charge did not decrease appropriately");
        Assert.ok(finalValue == 0, "Token value should not change");
    }
}

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
        digil.deactivateToken{value: incrementalValue}(tokenId);
        
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