// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "remix_tests.sol";

// Invoked only by the runner's self-tests, never as a passing protocol suite.
contract RunnerFailureProbe {
    function falseAssertion() external {
        Assert.equal(uint256(1), uint256(2), "deliberately failing assertion");
    }

    function falseReturn() external pure returns (bool) {
        return false;
    }

    function revertingCall() external pure {
        revert();
    }
}
