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

        digil.chargeToken{value: 30000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 300000 * 10 ** 18, "Coins from distribution should be 300000 bonus for value");
        Assert.equal(withdrawlValue, 28500000000000000000, "Distributed value should be 95% of 30000000000000000000");
    }

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testChargeTokenPartOne() external payable {
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
    function testChargeTokenPartTwo() external payable {
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
    function testChargeTokenPartThree() external payable {
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
    function testDischargeToken() external payable {
        uint256 incrementalValue = 100000000000000;

        bool dischargeComplete = digil.dischargeToken{value: incrementalValue}(dischargeTokenId);
        while (!dischargeComplete) {
            dischargeComplete = digil.dischargeToken(dischargeTokenId);
        }

        (, , , , , , uint256 contributionEpoch, uint256 distributionIndex, ) = digil.tokenData(dischargeTokenId);
        Assert.equal(contributionEpoch, 1, "Token contribution epoch in invalid state != 1");
        Assert.ok(distributionIndex == 0, "Token distribution in invalid state > 0");

        (uint256 finalCharge, , uint256 finalValue, , ) = digil.tokenCharge(dischargeTokenId);
        Assert.ok(finalCharge == 0, "Token charge did not decrease appropriately");
        Assert.ok(finalValue == 0, "Token value should not change");
    }
}