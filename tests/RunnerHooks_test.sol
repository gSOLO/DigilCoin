// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.39;

import "remix_tests.sol";
import "remix_accounts.sol";

contract RunnerHooksTest {
    uint256 private beforeCount;
    uint256 private afterCount;
    bool private initialized;

    function beforeAll() public { initialized = true; }

    function beforeEach() public {
        Assert.ok(initialized, "beforeAll must run first");
        beforeCount++;
    }

    /// #sender: account-1
    /// #value: 3
    function testFirst() public payable {
        Assert.equal(msg.sender, TestsAccounts.getAccount(1), "sender annotation");
        Assert.equal(msg.value, uint256(3), "value annotation");
        Assert.equal(beforeCount, uint256(1), "first beforeEach");
        Assert.equal(afterCount, uint256(0), "afterEach has not run yet");
    }

    function testSecond() public view returns (bool) {
        return beforeCount == 2 && afterCount == 1;
    }

    function afterEach() public { afterCount++; }

    function afterAll() public {
        Assert.equal(beforeCount, uint256(2), "all beforeEach calls");
        Assert.equal(afterCount, uint256(2), "all afterEach calls");
    }
}
