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
contract testSuite {
    IERC20 public coins;
    IDigilToken public digil;

    /// 'beforeAll' runs before all other tests
    /// More special functions are: 'beforeEach', 'beforeAll', 'afterEach' & 'afterAll'
    function beforeAll() public {
        // <instantiate contract>
        coins = IERC20(0xd9145CCE52D386f254917e481eB44e9943F39138);
        digil = IDigilToken(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8);
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
        uint256 incrementalValue = 100 * 1e9;
        uint256 activationThreshold = 10;
        bool restricted = false;
        uint256 plane = 4;                    
        bytes memory data = "Test Token";

        uint256 balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 0, "Token balance should be 0");

        uint256 tokenId = digil.createToken(incrementalValue, activationThreshold, restricted, plane, data);

        balanceTokens = digil.balanceOf(address(this));
        Assert.equal(balanceTokens, 1, "Token balance should be 1");
       
        (bool active, bool activating, bool tokenRestricted, uint256 links, uint256 contributors, uint256 dischargeIndex, uint256 distributionIndex, bytes memory tokenData) = digil.tokenData(tokenId);
        Assert.ok(active == false, "Token should be inactive initially");
        Assert.ok(activating == false, "Token should not be activating at creation");
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

        uint256 tokenId = digil.createToken(0, 0, false, 4, "Test Charge");

        uint256 coinAmount = 1 * coinMultiplier;
        (uint256 initialCharge, , , , ) = digil.tokenCharge(tokenId);

        digil.chargeToken(tokenId, coinAmount);

        (uint256 newCharge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(newCharge >= initialCharge + coinAmount, "Token charge did not increase appropriately");

        for (uint256 accountIndex; accountIndex < 9; accountIndex++) {
            digil.chargeTokenAs(TestsAccounts.getAccount(accountIndex), tokenId, coinAmount);
        }

        (uint256 fullCharge, , , , ) = digil.tokenCharge(tokenId);
        Assert.ok(fullCharge >= newCharge + coinAmount * 9, "Token charge did not increase appropriately");
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
    