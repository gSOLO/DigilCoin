// SPDX-License-Identifier: GPL-3.0
        
pragma solidity >=0.4.22 <0.9.0;

// This import is automatically injected by Remix
import "remix_tests.sol"; 

// This import is required to use custom transaction context
// Although it may fail compilation in 'Solidity Compiler' plugin
// But it will work fine in 'Solidity Unit Testing' plugin
import "remix_accounts.sol";
import "../contracts/IDigilToken.sol";

// File name has to end with '_test.sol', this file can contain more than one testSuite contracts
contract BasicTestSuite {
    IERC20 public coins;
    IDigilToken public digil;

    /// 'beforeAll' runs before all other tests
    /// More special functions are: 'beforeEach', 'beforeAll', 'afterEach' & 'afterAll'
    function beforeAll() public {
        // <instantiate contract>
        coins = IERC20(0x391209eC7C62713F2DC48E6582Cc264872A5aCcD);
        digil = IDigilToken(0xF4EF13a0c667B0dF23197106Df29ffBd491ddd0B);
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
        uint256 activationThreshold = 10;
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

    function checkSuccess() public {
        // Use 'Assert' methods: https://remix-ide.readthedocs.io/en/latest/assert_library.html
        Assert.ok(2 == 2, 'should be true');
        Assert.greaterThan(uint(2), uint(1), "2 should be greater than to 1");
        Assert.lesserThan(uint(2), uint(3), "2 should be lesser than to 3");
    }

    function checkSuccess2() public pure returns (bool) {
        // Use the return value (true or false) to test the contract
        return true;
    }

    /// Custom Transaction Context: https://remix-ide.readthedocs.io/en/latest/unittesting.html#customization
    /// #sender: account-1
    /// #value: 100
    function checkSenderAndValue() public payable {
        // account index varies 0-9, value is in wei
        Assert.equal(msg.sender, TestsAccounts.getAccount(1), "Invalid sender");
        Assert.equal(msg.value, 100, "Invalid value");
    }
}
    