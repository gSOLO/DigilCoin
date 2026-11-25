// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.39;

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
        Assert.ok(address(coins).code.length > 0, "Coin fixture must be deployed");
        Assert.ok(address(digil).code.length > 0, "Token fixture must be deployed");
        Assert.ok(address(coins) != address(digil), "Fixtures must be distinct");
    }

    /// #sender: account-3
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

    /// #sender: account-3
    /// #value: 3000000000000000000
    function testPrepareCharges() external payable {
        uint256 coinMultiplier = 10 ** 18;
        uint256 incrementalValue = 100000000000000;

        // Approve the Digil Token contract to spend the specified coinAmount.
        bool approved = coins.approve(address(digil), 1050 * coinMultiplier);
        Assert.ok(approved, "Coin approval failed");

        dischargeTokenId = digil.createToken{value: 100000000000000}(incrementalValue, 350 * coinMultiplier, false, 4, "Test Discharge");

    }

    uint256 private _batchSeed = 1;
    uint256 private _batchIndex;

    function _chargeBatch() private {
        for (uint256 i; i < 50; ++i) {
            _batchSeed = uint256(keccak256(abi.encodePacked(_batchSeed, _batchIndex++)));
            digil.chargeTokenAs{value: 100000000000000}(address(uint160(_batchSeed)), dischargeTokenId, 1e18);
        }
    }

    function testChargeBatch01() external { _chargeBatch(); }
    function testChargeBatch02() external { _chargeBatch(); }
    function testChargeBatch03() external { _chargeBatch(); }
    function testChargeBatch04() external { _chargeBatch(); }
    function testChargeBatch05() external { _chargeBatch(); }
    function testChargeBatch06() external { _chargeBatch(); }
    function testChargeBatch07() external { _chargeBatch(); }
    function testChargeBatch08() external { _chargeBatch(); }
    function testChargeBatch09() external { _chargeBatch(); }
    function testChargeBatch10() external { _chargeBatch(); }
    function testChargeBatch11() external { _chargeBatch(); }
    function testChargeBatch12() external { _chargeBatch(); }
    function testChargeBatch13() external { _chargeBatch(); }
    function testChargeBatch14() external { _chargeBatch(); }
    function testChargeBatch15() external { _chargeBatch(); }
    function testChargeBatch16() external { _chargeBatch(); }
    function testChargeBatch17() external { _chargeBatch(); }
    function testChargeBatch18() external { _chargeBatch(); }
    function testChargeBatch19() external { _chargeBatch(); }
    function testChargeBatch20() external { _chargeBatch(); }
    function testChargeBatch21() external { _chargeBatch(); }

    function testStartDischarge() external {
        Assert.ok(!digil.dischargeToken{value: 100000000000000}(dischargeTokenId), "Discharge should require continuation");
    }

    function testContinueDischarge1() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge2() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge3() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge4() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge5() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge6() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testContinueDischarge7() external {
        Assert.ok(!digil.dischargeToken(dischargeTokenId), "More discharge batches must remain");
    }

    function testDischargeToken() external {
        Assert.ok(digil.dischargeToken(dischargeTokenId), "Final discharge batch must complete");

        (, , , , , , uint256 contributionEpoch, uint256 distributionIndex, ) = digil.tokenData(dischargeTokenId);
        Assert.equal(contributionEpoch, 1, "Token contribution epoch in invalid state != 1");
        Assert.ok(distributionIndex == 0, "Token distribution in invalid state > 0");

        (uint256 finalCharge, , uint256 finalValue, , ) = digil.tokenCharge(dischargeTokenId);
        Assert.ok(finalCharge == 0, "Token charge did not decrease appropriately");
        Assert.ok(finalValue == 0, "Token value should be 0");
    }
}
