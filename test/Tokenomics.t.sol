// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {JsTruffleFixture} from "./JsTruffleFixture.sol";
import {Tokenomics} from "../contracts/Tokenomics.sol";

/**
 * @title TokenomicsTest
 * @notice Forge port of `genesis/test/tokenomics.js`. Does not replay historical `eth.call` at past blocks.
 */
contract TokenomicsTest is JsTruffleFixture {
    event SharesUpdated(uint16 shareStaking, uint16 shareSystem);

    MockChain internal chain;

    function setUp() public {
        // One genesis validator so `Tokenomics.deposit` can forward staking share to an existing validator.
        address[] memory genesisValidators = new address[](1);
        genesisValidators[0] = vm.addr(100);
        uint256[] memory genesisStakes = new uint256[](1);
        genesisStakes[0] = 0;

        address[] memory systemRewardAccounts = new address[](1);
        systemRewardAccounts[0] = address(0);
        uint16[] memory systemRewardShares = new uint16[](1);
        systemRewardShares[0] = 10000;

        address[] memory genesisDeployers = new address[](0);
        chain = deployMockChain(
            genesisValidators, genesisStakes, systemRewardAccounts, systemRewardShares, genesisDeployers, vm.addr(1), 10, 2
        );
    }

    /// @notice Constructor path: 65/35 split, fixed initial supply, zero inflation until first deposit.
    function test_initialState() public view {
        Tokenomics.State memory state = chain.tokenomics.getState();
        assertEq(state.shareStaking, 6500);
        assertEq(state.shareSystem, 3500);
        assertEq(state.totalSupply, 8888888888000000000000000000);
        assertEq(state.totalIntroducedSupply, 0);
        assertEq(state.introducedSupply, 0);
        assertEq(state.inflationPct, 0);
    }

    /// @notice `updateShares` must sum to 10000 (basis points); invalid pairs revert with Tokenomics error.
    function test_updateShares_andRevertWhenInvalid() public {
        Tokenomics.State memory stateBefore = chain.tokenomics.getState();
        assertEq(stateBefore.shareStaking, 6500);
        assertEq(stateBefore.shareSystem, 3500);

        uint16 newStakingShareBps = 2400;
        uint16 newSystemShareBps = 7600;
        vm.expectEmit(true, true, true, true);
        emit SharesUpdated(newStakingShareBps, newSystemShareBps);
        chain.tokenomics.updateShares(newStakingShareBps, newSystemShareBps);

        Tokenomics.State memory stateAfter = chain.tokenomics.getState();
        assertEq(stateAfter.shareStaking, newStakingShareBps);
        assertEq(stateAfter.shareSystem, newSystemShareBps);

        vm.expectRevert();
        chain.tokenomics.updateShares(newStakingShareBps + 1, newSystemShareBps);
        vm.expectRevert();
        chain.tokenomics.updateShares(newStakingShareBps - 1, newSystemShareBps);
    }

    /// @notice Coinbase-style deposit: splits value to staking/system, updates totals; `msg.value == 0` reverts.
    function test_deposit_updatesState_andRevertsOnZeroValue() public {
        address validator = vm.addr(100);
        uint256 initialTotalSupply = 8888888888000000000000000000;
        uint256 inflationPctWei = 88000000000000000000;
        uint256 introducedThisDepositWei = (initialTotalSupply * inflationPctWei / 1e18 / 100) / 10512000;
        uint256 expectedNewTotalSupply = initialTotalSupply + introducedThisDepositWei;

        // `introducedThisDepositWei` is ~7e23 wei; fund explicitly (too large for a generic `setUp` top-up).
        vm.deal(address(this), introducedThisDepositWei);
        vm.txGasPrice(0);
        chain.tokenomics.deposit{value: introducedThisDepositWei}(validator, expectedNewTotalSupply, inflationPctWei);

        Tokenomics.State memory state = chain.tokenomics.getState();
        assertEq(state.inflationPct, inflationPctWei);
        assertEq(state.introducedSupply, introducedThisDepositWei);
        assertEq(state.totalIntroducedSupply, introducedThisDepositWei);
        assertEq(state.totalSupply, expectedNewTotalSupply);

        vm.expectRevert();
        chain.tokenomics.deposit{value: 0}(validator, expectedNewTotalSupply, inflationPctWei);
    }
}
