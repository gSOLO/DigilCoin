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
contract JuiletTestSuite {
    IERC20 public coins;
    IDigilToken public digil;
    uint256 activeTokenId;
    uint256 linkTokenId;

    receive() external payable {}

    /// 'beforeAll' runs before all other tests
    /// More special functions are: 'beforeEach', 'beforeAll', 'afterEach' & 'afterAll'
    function beforeAll() public {
        // <instantiate contract>
        coins = DigilTestLibrary.getCoins();
        digil = DigilTestLibrary.getToken();
        Assert.equal(uint(1), uint(1), "1 should be equal to 1");
    }

    /// #sender: account-9
    /// #value: 1011000000000000000
    function testWithdrawl() public payable {
        uint256 balanceCoins = coins.balanceOf(address(this));
        Assert.equal(balanceCoins, 0, "Coin balance should be 0 coins");

        uint256 tokenId = digil.createToken(
            1000000000000000,
            1000000000000000000,
            false,
            4,
            "Test Withdraw"
        );

        (uint256 withdrawlCoins, uint256 withdrawlValue) = digil.withdraw();
        Assert.equal(
            withdrawlCoins,
            5000 * 10 ** 18,
            "First withdrawl should be 5000 coins"
        );
        Assert.equal(withdrawlValue, 0, "First withdrawl should be 0 value");

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000}(
            tokenId,
            1000000000000000000
        );
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(
            withdrawlCoins,
            10 * 10 ** 18,
            "Coins from distribution should be 10 bonus for value"
        );
        Assert.equal(
            withdrawlValue,
            950000000000000,
            "Distributed value shopuld be 95% of 1000000000000000"
        );

        tokenId = digil.createToken(
            10000000000000000,
            1000000000000000000,
            false,
            4,
            "Test Withdraw"
        );

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 10000000000000000}(
            tokenId,
            1000000000000000000
        );
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(
            withdrawlCoins,
            100 * 10 ** 18,
            "Coins from distribution should be 100 bonus for value"
        );
        Assert.equal(
            withdrawlValue,
            9500000000000000,
            "Distributed value should be 95% of 10000000000000000"
        );

        tokenId = digil.createToken(
            10000000000000000,
            1000000000000000000,
            false,
            4,
            "Test Withdraw"
        );

        approved = coins.approve(address(digil), 1 * 10 ** 18);
        Assert.ok(approved, "Coin approval failed");

        digil.chargeToken{value: 1000000000000000000}(
            tokenId,
            1000000000000000000
        );
        digil.activateToken(tokenId);

        (withdrawlCoins, withdrawlValue) = digil.withdraw();
        Assert.equal(
            withdrawlCoins,
            10000 * 10 ** 18,
            "Coins from distribution should be 10000 bonus for value"
        );
        Assert.equal(
            withdrawlValue,
            950000000000000000,
            "Distributed value should be 95% of 1000000000000000000"
        );
    }

    /// #sender: account-9
    /// #value: 55000000000000000
    function testActivatePrimedToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 515 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        activeTokenId = digil.createToken(
            incrementalValue,
            10 * coinMultiplier,
            false,
            4,
            "Source Plane"
        );

        digil.primeToken(activeTokenId);

        for (uint256 accountIndex; accountIndex < 5; accountIndex++) {
            digil.chargeTokenAs{value: incrementalValue}(
                TestsAccounts.getAccount(accountIndex),
                activeTokenId,
                coinMultiplier
            );
        }

        (uint256 charge, , , , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(charge, coinMultiplier * 5, "Invalid Source charge");

        digil.activateToken(activeTokenId);

        (, uint256 activeCharge, , , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(
            activeCharge,
            coinMultiplier * 5,
            "Invalid Source active charge"
        );

        digil.overchargeToken{value: 2043 * 2 * incrementalValue}(
            activeTokenId,
            2043 * coinMultiplier
        );

        (, activeCharge, , , ) = digil.tokenCharge(activeTokenId);
        Assert.equal(
            activeCharge,
            coinMultiplier * 2048,
            "Invalid Source final active charge"
        );
    }

    /// #sender: account-9
    /// #value: 5100000000000000
    function testBuffToken() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 9694 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        linkTokenId = digil.createToken(
            incrementalValue,
            10 * coinMultiplier,
            false,
            4,
            "Fire Destination Plane"
        );

        digil.linkToken{value: 200000000000000}(activeTokenId, linkTokenId, 25);

        (
            uint256 linkId,
            uint8 base,
            uint256 affinityBonus,
            uint8 efficiencyBonus,
            uint8 attunement,
            uint8 amplification,
            uint8 flags,
            uint64 expiresAt,
            uint256 effectiveBase
        ) = digil.tokenLinkAt(activeTokenId, 1);
        Assert.equal(linkId, linkTokenId, "Invalid Link ID");
        Assert.equal(base, 25, "Invalid Link Base Efficiency");
        Assert.equal(affinityBonus, 25, "Invalid Link Base Affinity Bonus");
        Assert.equal(efficiencyBonus, 0, "Invalid Link Base Efficiency Bonus");
        Assert.equal(attunement, 0, "Invalid Attunement");
        Assert.equal(amplification, 0, "Invalid Amplification");
        Assert.equal(flags, 0, "Invalid Flags");
        Assert.equal(expiresAt, 0, "Invalid Buff Expires");
        Assert.equal(effectiveBase, 25, "Invalid Link Effective Base Efficiency" );

        digil.buffToken(activeTokenId, 25, 0, 0, false, 24);
    }

    /// @dev Ensure amplification buff increases activeCharge gained by a direct charge.
    /// #sender: account-8
    function testAmplificationBuff() public {
        uint256 coinMultiplier = 10 ** 18;

        // 1. Create a simple token (no plane, no threshold, unrestricted).
        uint256 tokenId = digil.createToken(0, 0, false, 0, "");

        // Activate so that subsequent charges go into activeCharge.
        bool activated = digil.activateToken(tokenId);
        Assert.ok(
            activated,
            "Token should activate with 0 activation threshold"
        );

        // 2. Overcharge to 512 Coins of activeCharge.
        uint256 initialAC = 512 * coinMultiplier;
        digil.overchargeToken{value: 100000000000000 * 512 * 2}(
            tokenId,
            initialAC
        );

        (, uint256 acBeforeBuff, , , ) = digil.tokenCharge(tokenId);
        Assert.equal(
            acBeforeBuff,
            initialAC,
            "Unexpected initial activeCharge before buff"
        );

        // 3. Apply a pure amplification buff: +50% for 30 minutes, no attunement/anchor.
        uint8 amplification = 50;
        uint256 duration = 30; // minutes

        digil.buffToken(tokenId, 0, 0, amplification, false, duration);

        // Expected buff cost:
        // cost = magnitude * duration * linkCount * _coinRate / LINK_BUFF_COST_FACTOR
        // magnitude = amplification = 50
        // duration = 30
        // linkCount = 1 (no links => treated as 1)
        // _coinRate = 100 * 10**18
        uint256 expectedCost = (50 * 30 * 100 * coinMultiplier) / 1440;
        // = 104166666666666666666

        (, uint256 acAfterBuff, , , ) = digil.tokenCharge(tokenId);
        uint256 expectedAfterBuff = initialAC - expectedCost;

        Assert.equal(
            acAfterBuff,
            expectedAfterBuff,
            "Buff cost did not reduce activeCharge by the expected amount"
        );

        // 4. Charge the token once while the amplification buff is active.
        uint256 chargeCoins = 100 * coinMultiplier;

        // incrementalValue == 0, so no ETH required here.
        bool charged = digil.chargeToken{value: 0}(tokenId, chargeCoins);
        Assert.ok(charged, "Direct charge should succeed on active token");

        (, uint256 acAfterCharge, , , ) = digil.tokenCharge(tokenId);

        // Gain from this single charge:
        uint256 gained = acAfterCharge - acAfterBuff;

        // Expected gain:
        // totalIncoming = coins
        // boost         = coins * amplification / 100
        // gain          = coins + boost
        uint256 expectedGain = chargeCoins +
            (chargeCoins * amplification) / 100;

        Assert.equal(
            gained,
            expectedGain,
            "Amplification buff did not increase activeCharge by the expected amount"
        );
    }
}
