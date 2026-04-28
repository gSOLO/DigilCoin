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

import "@openzeppelin/contracts/utils/Strings.sol";

import "hardhat/console.sol";

// File name has to end with '_test.sol', this file can contain more than one testSuite contracts
contract CharlieTestSuite {
    IERC20 public coins;
    IDigilToken public digil;
    using Strings for uint256;

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

        digil.chargeToken{value: 30000000000000000000}(tokenId, 1000000000000000000);
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(withdrawlCoins, 300001 * 10 ** 18, "Coins from distribution should be 300001 bonus for value");
        Assert.equal(withdrawlValue, 28500095000000000000, "Distributed value should be 95% of 30000000000000000000 + 95% of 100000000000000");
    }

    /// #sender: account-2
    /// #value: 600000000000000
    function testUpdateToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        bool approved = coins.approve(address(digil), 2 * 1000 * 100 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        // Create a token with initial parameters
        uint256 tokenId = digil.createToken{value: 100000000000000}(100000000000000, 1000000000000000000, false, 4, "Update Test");

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

        try digil.updateToken{value: 200000000000000 + 1}(tokenId, 200000000000000, 2000000000000000000, "Overpay Data", "Overpay URI") {
            Assert.ok(false, "Overpaying updateToken with metadata/data change should revert");
        } catch {
            Assert.ok(true, "Overpaying updateToken correctly reverted");
        }

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

    /// #sender: account-2
    /// #value: 100000000000000
    function testReadOnlyViewSurfaceViaInterface() external payable {
        uint256 tokenId = digil.createToken{value: 100000000000000}(100000000000000, 1000000000000000000, false, 4, "Read Surface");

        {
            string memory uri = digil.tokenURI(tokenId);
            Assert.equal(uri, string.concat("https://digil.co.in/token/", tokenId.toString()), "Default token URI should not be empty");
        }

        {
            (uint256 charge, uint256 activeCharge, uint256 value, uint256 incrementalValue, uint256 activationThreshold) = digil.tokenCharge(tokenId);
            Assert.equal(charge, 0, "New token charge should be 0");
            Assert.equal(activeCharge, 0, "New token active charge should be 0");
            Assert.equal(value, 100000000000000, "New token value should match creation ETH");
            Assert.equal(incrementalValue, 100000000000000, "Incremental value should match creation input");
            Assert.equal(activationThreshold, 1000000000000000000, "Activation threshold should match creation input");
        }

        {
            (bool active, bool activating, bool discharging, bool restricted, uint256 links, uint256 contributors, uint256 contributionEpoch, uint256 distributionIndex, bytes memory data) = digil.tokenData(tokenId);
            Assert.equal(active, false, "New token should be inactive");
            Assert.equal(activating, false, "New token should not be activating");
            Assert.equal(discharging, false, "New token should not be discharging");
            Assert.equal(restricted, false, "Token should use open contribution mode");
            Assert.equal(links, 1, "Plane alignment should reserve one link slot");
            Assert.equal(contributors, 0, "New token should have no contributors");
            Assert.equal(contributionEpoch, 0, "New token contribution epoch should start at 0");
            Assert.equal(distributionIndex, 0, "New token distribution index should start at 0");
            Assert.ok(keccak256("Read Surface") == keccak256(data), "Token data should match the creation payload");
        }

        {
            (uint40 expiresAt, uint8 efficiencyBonus, uint8 attunement, uint8 amplification, uint16 flags, uint120 appearance) = digil.tokenBuff(tokenId);
            Assert.equal(uint256(expiresAt), 0, "New token should not have an active buff");
            Assert.equal(uint256(efficiencyBonus), 0, "Default efficiency bonus should be 0");
            Assert.equal(uint256(attunement), 0, "Default attunement should be 0");
            Assert.equal(uint256(amplification), 0, "Default amplification should be 0");
            Assert.equal(uint256(flags), 0, "Default buff flags should be 0");
            Assert.equal(uint256(appearance), 0, "Default buff appearance should be 0");
        }

        {
            (uint256 contributionCharge, uint256 contributionDischarge, uint256 contributionValue, bool exists, bool whitelisted, uint256 epoch) = digil.tokenContribution(tokenId, address(this));
            Assert.equal(contributionCharge, 0, "No contribution charge should exist for a fresh token");
            Assert.equal(contributionDischarge, 0, "No contribution discharge should exist for a fresh token");
            Assert.equal(contributionValue, 0, "No contribution value should exist for a fresh token");
            Assert.equal(exists, false, "Fresh token should not have a contributor record");
            Assert.equal(whitelisted, true, "Open token should auto-whitelist contributor because address(this) created the token");
            Assert.equal(epoch, 0, "Contributor epoch should default to 0");
        }

        {
            (uint256 linkId, uint8 baseEfficiency, uint256 affinityBonus) = digil.tokenLinkAt(tokenId, 0);
            Assert.equal(linkId, 4, "Plane alignment should be stored as the first link");
            Assert.equal(uint256(baseEfficiency), 100, "Plane link should have default base efficiency of 100");
            Assert.equal(affinityBonus, 0, "Plane link should initialize with zero affinity bonus");
        }

        {
            (address contractTokenAddress, uint256 externalTokenId, bool recallable, bool vaulted) = digil.tokenAttachment(tokenId);
            Assert.equal(contractTokenAddress, address(0), "Fresh token should not be attached to an external collection");
            Assert.equal(externalTokenId, 0, "Fresh token should not have an external token id");
            Assert.equal(recallable, false, "Fresh token should not be recallable");
            Assert.equal(vaulted, false, "Fresh token should not be vaulted");
        }
    }
}
