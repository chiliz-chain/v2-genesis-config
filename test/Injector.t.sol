// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {JsTruffleFixture} from "./JsTruffleFixture.sol";

/**
 * @title InjectorTest
 * @notice Replaces `genesis/test/injector.js`, which asserted per-contract getters that no longer exist on `Injector`.
 *         Instead we assert `RuntimeUpgrade.getSystemContracts()` returns the canonical ordered system addresses.
 */
contract InjectorTest is JsTruffleFixture {
    MockChain internal chain;

    function setUp() public {
        chain = deployDefaultMockChain();
    }

    /// @notice Order must match `RuntimeUpgrade.getSystemContracts`: staking, slashing, systemReward, stakingPool,
    ///         governance, chainConfig, runtimeUpgrade, deployerProxy, then any extra deployed system contracts.
    function test_systemContractAddressesMatchInjectorWiring() public view {
        address[] memory registered = chain.runtimeUpgrade.getSystemContracts();

        assertEq(registered[0], address(chain.staking), "staking");
        assertEq(registered[1], address(chain.slashingIndicator), "slashingIndicator");
        assertEq(registered[2], address(chain.systemReward), "systemReward");
        assertEq(registered[3], address(chain.stakingPool), "stakingPool");
        assertEq(registered[4], address(chain.governance), "governance");
        assertEq(registered[5], address(chain.chainConfig), "chainConfig");
        assertEq(registered[6], address(chain.runtimeUpgrade), "runtimeUpgrade");
        assertEq(registered[7], address(chain.deployerProxy), "deployerProxy");
    }
}
