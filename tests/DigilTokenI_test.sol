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
contract IndiaTestSuite {
    IERC20 public coins;
    IDigilToken public digil;
    uint256 activeTokenId;

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

    /// #sender: account-8
    /// #value: 1011000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken(1000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 1 * 10 ** 18, "First withdrawl should be 1 coin");
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

    /// #sender: account-8
    /// #value: 55000000000000000
    function testActivateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 515 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        activeTokenId = digil.createToken(incrementalValue, 0, false, 0, "Source Plane");

        for (uint256 accountIndex; accountIndex < 15; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(TestsAccounts.getAccount(accountIndex), activeTokenId, coinMultiplier);
        }
        
        uint256 currentSeed = 1;
        for (uint256 accountIndex = 0; accountIndex < 497; accountIndex++) {
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, accountIndex))); // Generate a new seed for each address
            address addr = address(uint160(currentSeed)); // Convert the seed to an address
            digil.chargeTokenAs{value: incrementalValue}(addr, activeTokenId, coinMultiplier);
        }

        (uint256 newCharge, uint256 newActiveCharge, uint256 newValue, , ) = digil.tokenCharge(activeTokenId);
        Assert.ok(newCharge >= coinMultiplier * 512, "Token charge did not increase appropriately");
        Assert.ok(newActiveCharge == 0, "Token active charge should not increase");
        Assert.ok(newValue == 0, "Token value should not increase");

        (bool isActive, bool isActivating, bool isDischarging, , , , , , ) = digil.tokenData(activeTokenId);
        Assert.ok(!isActive, "Token activation in invalid state (active)");
        Assert.ok(!isActivating, "Token activation in invalid state (activating)");
        Assert.ok(!isDischarging, "Token distribution in invalid state (discharging)");

        bool activationComplete = digil.activateToken(activeTokenId);
        while(!activationComplete) {
            (, isActivating, , , , , , , ) = digil.tokenData(activeTokenId);
            Assert.ok(isActivating, "Token activation in invalid state (not activating)");
            activationComplete = digil.activateToken(activeTokenId);
        }
        (isActive, isActivating, , , , , , , ) = digil.tokenData(activeTokenId);
        Assert.ok(isActive, "Token activation in invalid state (active == false)");
        Assert.ok(!isActivating, "Token activation in invalid state (activating)");

        (newCharge, newActiveCharge, newValue, , ) = digil.tokenCharge(activeTokenId);
        Assert.ok(newCharge == 0, "Token charge did not decrease appropriately");
        Assert.ok(newActiveCharge == coinMultiplier * 512, "Token active charge did not increase appropriately");
        Assert.ok(newValue == 0, "Token value should reset");
    }

    /// #sender: account-8
    /// #value: 6100000000000000
    function testBuffToken() external payable {
        uint256 coinMultiplier = 10 ** 18;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 9694 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        (, , , , uint256 links, , , , ) = digil.tokenData(activeTokenId);
        Assert.equal(links, 0, "Invalid Link Count (!=0)");
        (uint256 charge, uint256 activeCharge, uint256 value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid initial Source charge");
        Assert.equal(activeCharge, coinMultiplier * 512, "Invalid initial Source active charge");
        Assert.equal(value, 0, "Invalid initial Source value");

        uint256 fireTokenId = digil.createToken(0, 0, false, 4, "Fire Destination Plane");

        digil.linkToken{value: 100000000000000}(activeTokenId, fireTokenId, 10);
        (, , , , links, , , , ) = digil.tokenData(activeTokenId);
        Assert.equal(links, 1, "Invalid Link Count (!=1)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 0, "Invalid initial Fire Destination charge");
        Assert.equal(activeCharge, 0, "Invalid Fire Destination active charge");
        Assert.equal(value, 50000000000000, "Invalid initial Fire Destination value");

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid new Source charge");
        Assert.equal(activeCharge, coinMultiplier * 512, "Invalid new Source active charge");

        digil.buffToken(activeTokenId, 30, 0, 0, false, false, 24);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post buff Source charge");
        Assert.equal(activeCharge, coinMultiplier * 412, "Invalid post buff Source active charge");

        digil.deactivateToken(activeTokenId);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post deactivate Source charge");
        Assert.equal(activeCharge, coinMultiplier * 206, "Invalid post deactivate Source active charge");

        bool activationComplete = digil.activateToken(activeTokenId);
        while(!activationComplete) {
            activationComplete = digil.activateToken(activeTokenId);
        }

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post activate Source charge");
        Assert.equal(activeCharge, coinMultiplier * 206, "Invalid post activate Source active charge");

        digil.overchargeToken{value: 100000000000000 * 306 * 2}(activeTokenId, 306 * coinMultiplier);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post overcharge 1 Source charge");
        Assert.equal(activeCharge, coinMultiplier * 512, "Invalid post overcharge 1 Source active charge");

        digil.overchargeToken{value: 100000000000000 * 813 * 2}(activeTokenId, 813 * coinMultiplier);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post overcharge 2 Source charge");
        Assert.equal(activeCharge, coinMultiplier * 1325, "Invalid post overcharge 2 Source active charge");

        digil.stabilizeToken(activeTokenId);
        digil.deactivateToken(activeTokenId);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid post stabilize and deactivate Source charge");
        Assert.equal(activeCharge, coinMultiplier * 1325, "Invalid post stabilize and deactivate Source active charge");

        activationComplete = digil.activateToken(activeTokenId);
        while(!activationComplete) {
            activationComplete = digil.activateToken(activeTokenId);
        }

        digil.buffToken(activeTokenId, 0, 0, 0, true, false, 36);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid final buff Source charge");
        Assert.equal(activeCharge, coinMultiplier * 1200, "Invalid final buff Source active charge");

        digil.deactivateToken(activeTokenId);

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid final deactivate Source charge");
        Assert.equal(activeCharge, coinMultiplier * 600, "Invalid final deactivate Source active charge");

        bool dischargeComplete = digil.dischargeToken{value: 100000000000000}(activeTokenId);
        while (!dischargeComplete) {
            dischargeComplete = digil.dischargeToken(activeTokenId);
        }

        (charge, activeCharge, value, , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, 0, "Invalid final discharge Source charge");
        Assert.equal(activeCharge, coinMultiplier * 150, "Invalid final discharge Source active charge");
    }
}