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
contract GammaTestSuite {
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

    /// #sender: account-7
    /// #value: 1011000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken(1000000000000000, 1000000000000000000, false, 4, "Test Withdraw");

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 5000 * 10 ** 18, "First withdrawl should be 5000 coins");
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

    /// #sender: account-7
    /// #value: 5100000000000000
    function testLinkToken() external payable {
        uint256 coinMultiplier = 10 ** 18;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 9694 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(0, 0, false, 4, "Source Plane");
        (, , , , , uint256 links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 1, "Invalid Link Count (!=1)");
        (uint256 charge, uint256 activeCharge, uint256 value, , ) = digil.tokenCharge(tokenId);
        Assert.equal(charge, 0, "Invalid initial Source charge");
        Assert.equal(activeCharge, 0, "Invalid initial Source active charge");
        Assert.equal(value, 0, "Invalid initial Source value");

        (uint256 linkId, uint8 base, uint256 affinityBonus, , ,) = digil.tokenLinkAt(tokenId, links - 1);
        Assert.equal(linkId, 4, "Invalid planar link ID");
        Assert.equal(base, 100, "Invalid planar link base efficiency");
        Assert.equal(affinityBonus, 0, "Invalid planar link affinity bonus");

        uint256 fireTokenId = digil.createToken(0, 0, false, 4, "Fire Destination Plane");
        uint256 airTokenId = digil.createToken(0, 0, false, 5, "Air Destination Plane");
        uint256 earthTokenId = digil.createToken(100000000000000, 0, false, 6, "Earth Destination Plane");
        uint256 waterTokenId = digil.createToken(0, 0, false, 7, "Water Destination Plane");

        digil.linkToken(tokenId, fireTokenId, 10);                           // coins: 1000 base: 10 bonus: 10
        (, , , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 2, "Invalid Link Count (!=2)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(fireTokenId);
        Assert.equal(charge, 0, "Invalid initial Fire Destination charge");
        Assert.equal(activeCharge, 0, "Invalid Fire Destination active charge");
        Assert.equal(value, 0, "Invalid initial Fire Destination value");

        (linkId, base, affinityBonus, , ,) = digil.tokenLinkAt(tokenId, links - 1);
        Assert.equal(linkId, fireTokenId, "Invalid fire link ID");
        Assert.equal(base, 10, "Invalid fire link base efficiency");
        Assert.equal(affinityBonus, 10, "Invalid fire link affinity bonus");
        
        digil.linkToken(tokenId, airTokenId, 10);                            // coins: 1000 base: 10 bonus: 20
        (, , , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 3, "Invalid Link Count (!=3)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(airTokenId);
        Assert.equal(charge, 0, "Invalid initial Air Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Air Destination active charge");
        Assert.equal(value, 0, "Invalid initial Air Destination value");

        (linkId, base, affinityBonus, , ,) = digil.tokenLinkAt(tokenId, links - 1);
        Assert.equal(linkId, airTokenId, "Invalid air link ID");
        Assert.equal(base, 10, "Invalid air link base efficiency");
        Assert.equal(affinityBonus, 20, "Invalid air link affinity bonus");

        digil.linkToken{value: 100000000000000}(tokenId, earthTokenId, 10);  // coins: 1000 base: 10 bonus: 0
        (, , , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 4, "Invalid Link Count (!=4)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(earthTokenId);
        Assert.equal(charge, 0, "Invalid initial Earth Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Earth Destination active charge");
        Assert.equal(value, 50000000000000, "Invalid initial Earth Destination value");

        (linkId, base, affinityBonus, , ,) = digil.tokenLinkAt(tokenId, links - 1);
        Assert.equal(linkId, earthTokenId, "Invalid earth link ID");
        Assert.equal(base, 10, "Invalid earth link base efficiency");
        Assert.equal(affinityBonus, 0, "Invalid earth link affinity bonus");

        digil.linkToken(tokenId, waterTokenId, 5);                          // coins: 1000 base: 5 bonus: 0
        (, , , , , links, , , , ) = digil.tokenData(tokenId);
        Assert.equal(links, 5, "Invalid Link Count (!=5)");
        (charge, activeCharge, value, , ) = digil.tokenCharge(waterTokenId);
        Assert.equal(charge, 0, "Invalid initial Water Destination charge");
        Assert.equal(activeCharge, 0, "Invalid initial Water Destination active charge");
        Assert.equal(value, 0, "Invalid initial Water Destination value");

        (linkId, base, affinityBonus, , ,) = digil.tokenLinkAt(tokenId, links - 1);
        Assert.equal(linkId, waterTokenId, "Invalid water link ID");
        Assert.equal(base, 5, "Invalid water link base efficiency");
        Assert.equal(affinityBonus, 0, "Invalid water link affinity bonus");
    }

    /// #sender: account-7
    /// #value: 1000000000000000
    function testChargeTokenAs() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 10 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Charge With Value");

        digil.chargeToken{value: incrementalValue}(tokenId, coinMultiplier);

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            address contributor = TestsAccounts.getAccount(accountIndex);
            (uint256 charge, uint256 value, bool exists, , , ) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(charge, 0, "Invalid initial charge");
            Assert.equal(value, 0, "Invalid initial value");
            Assert.equal(exists, false, "Invalid initial exists");

            digil.chargeTokenAs{value: incrementalValue}(contributor, tokenId, coinMultiplier);

            (charge, value, exists, , , ) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(charge, coinMultiplier, "Invalid new charge");
            Assert.equal(value, incrementalValue, "Invalid new value");
            Assert.equal(exists, true, "Invalid new exists");
        }

        digil.activateToken(tokenId);
    }

    /// #sender: account-7
    /// #value: 3000000000000000
    function testChargeTokenAsEpoch() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 20 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        uint256 tokenId = digil.createToken(incrementalValue, 10 * coinMultiplier, false, 4, "Test Charge With Value");

        digil.chargeToken{value: incrementalValue}(tokenId, coinMultiplier);

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            address contributor = TestsAccounts.getAccount(accountIndex);
            (, , , bool distributed, , uint256 epoch) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(distributed, false, "Invalid initial distributed");
            Assert.equal(epoch, 0, "Invalid initial epoch");

            digil.chargeTokenAs{value: incrementalValue}(contributor, tokenId, coinMultiplier);

            (, , , distributed, , epoch) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(distributed, false, "Invalid new distributed");
            Assert.equal(epoch, 0, "Invalid new epoch");
        }

        digil.activateToken(tokenId);
        digil.deactivateToken(tokenId);
        digil.dischargeToken{value: incrementalValue}(tokenId);

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            address contributor = TestsAccounts.getAccount(accountIndex);
            (, , , bool distributed, , uint256 epoch) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(distributed, true, "Invalid active distributed");
            Assert.equal(epoch, 0, "Invalid active epoch");

            digil.chargeTokenAs{value: incrementalValue}(contributor, tokenId, coinMultiplier);

            (, , , distributed, , epoch) = digil.tokenContribution(tokenId, contributor);
            Assert.equal(distributed, false, "Invalid new distributed");
            Assert.equal(epoch, 1, "Invalid new epoch");
        }
    }
}