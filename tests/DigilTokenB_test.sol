// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

// This import is automatically injected by Remix
import "remix_tests.sol"; 

// This import is required to use custom transaction context
// Although it may fail compilation in 'Solidity Compiler' plugin
// But it will work fine in 'Solidity Unit Testing' plugin
import "remix_accounts.sol";

import "../contracts/IDigilToken.sol";
import "../contracts/DigilTestLibrary.sol";

import "hardhat/console.sol";

// File name has to end with '_test.sol', this file can contain more than one testSuite contracts
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
    /// #value: 1011300000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken{value: 100000000000000}(1000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 1 * 10 ** 18, "First withdrawl should be 1 coin");
        Assert.equal(withdrawlValue, 0, "First withdrawl should be 0 value");

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 11 * 10 ** 18, "Coins from distribution should be 11 bonus for value");
        Assert.equal(withdrawlValue, 1045000000000000, "Distributed value shopuld be 95% of 1000000000000000 + 95% of 100000000000000");

        tokenId = digil.createToken{value: 100000000000000}(10000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 10000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 101 * 10 ** 18, "Coins from distribution should be 101 bonus for value");
        Assert.equal(withdrawlValue, 9595000000000000, "Distributed value should be 95% of 10000000000000000 + 95% of 100000000000000");

        tokenId = digil.createToken{value: 100000000000000}(10000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 10001 * 10 ** 18, "Coins from distribution should be 10001 bonus for value");
        Assert.equal(withdrawlValue, 950095000000000000, "Distributed value should be 95% of 1000000000000000000 + 95% of 100000000000000");
    }

    /// #sender: account-0
    /// #value: 55000000000000000
    function testActivateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 515 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken{value: 100000000000000}(incrementalValue, 10 * coinMultiplier, false, 4, "Test Activate");

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
        Assert.ok(newValue == 100000000000000, "Token value should not increase");

        digil.chargeToken{value: incrementalValue * 6}(tokenId, coinMultiplier);

        (newCharge, newActiveCharge, newValue, , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= coinMultiplier * 515, "Token charge did not increase appropriately");
        Assert.ok(newActiveCharge == 0, "Token active charge should not increase");
        Assert.ok(newValue == (100000000000000 + incrementalValue * 5), "Token value did not increase appropriately");

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

        uint256 tokenId = digil.createToken{value: 100000000000000}(0, 0, false, 4, "Source Plane");
        (, , , , uint256 links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 1, "Invalid Link Count (!=1)");
        (uint256 charge, uint256 activeCharge, uint256 value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(charge, 0, "Invalid initial Source charge");
        Assert.equal(activeCharge, 0, "Invalid initial Source active charge");
        Assert.equal(value, 100000000000000, "Invalid initial Source value");

        uint256 fireTokenId = digil.createToken{value: 100000000000000}(0, 0, false, 4, "Fire Destination Plane");
        uint256 airTokenId = digil.createToken{value: 100000000000000}(0, 0, false, 5, "Air Destination Plane");
        uint256 earthTokenId = digil.createToken{value: 100000000000000}(100000000000000, 0, false, 6, "Earth Destination Plane");
        uint256 waterTokenId = digil.createToken{value: 100000000000000}(0, 0, false, 7, "Water Destination Plane");

        digil.linkToken(tokenId, fireTokenId, 10);                           // coins: 1000 base: 10 bonus: 10
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 2, "Invalid Link Count (!=2)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 0, "Invalid initial Fire Destination charge");
        Assert.equal(activeCharge, 0, "Invalid Fire Destination active charge");
        Assert.equal(value, 100000000000000, "Invalid initial Fire Destination value");
        
        digil.linkToken(tokenId, airTokenId, 10);                            // coins: 1000 base: 10 bonus: 20
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 3, "Invalid Link Count (!=3)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 0, "Invalid initial Air Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Air Destination active charge");
        Assert.equal(value, 100000000000000, "Invalid initial Air Destination value");

        digil.linkToken{value: 100000000000000}(tokenId, earthTokenId, 10);  // coins: 1000 base: 10 bonus: 0
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 4, "Invalid Link Count (!=4)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 0, "Invalid initial Earth Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Earth Destination active charge");
        Assert.equal(value, 50000000000000 + 100000000000000, "Invalid initial Earth Destination value");

        digil.linkToken(tokenId, waterTokenId, 10);                          // coins: 1000 base: 10 bonus: 0
        (, , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 5, "Invalid Link Count (!=5)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 0, "Invalid initial Water Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Water Destination active charge");
        Assert.equal(value, 100000000000000, "Invalid initial Water Destination value");

        (, , value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(value, 150000000000000, "Invalid Source value (!=150000000000000)");

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
        uint256 tokenId = digil.createToken{value: 100000000000000}(100000000000000, 1000000000000000000, false, 4, "Zero Coins Test");
        
        try digil.chargeToken{value: 100000000000000}(tokenId, 0) {
            Assert.ok(false, "Charging with zero coins should fail");
        } catch {
            Assert.ok(true, "Incorrect error for zero coins");
        }

        tokenId = digil.createToken{value: 100000000000000}(100000000000000, 1000000000000000000, false, 4, "Zero Value Test");
        bool approved = coins.approve(address(digil), 1000000000000000000);
        Assert.ok(approved, "Coin approval failed");

        try digil.chargeToken{value: 0}(tokenId, 1000000000000000000) {
            Assert.ok(false, "Charging with zero value should fail");
        } catch {
            Assert.ok(true, "Incorrect error for zero value");
        }
    }
}