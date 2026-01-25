// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import "../contracts/interfaces/IChainConfig.sol";
import "../contracts/interfaces/IGovernance.sol";
import "../contracts/interfaces/ISlashingIndicator.sol";
import "../contracts/interfaces/ISystemReward.sol";
import "../contracts/interfaces/IRuntimeUpgradeEvmHook.sol";
import "../contracts/interfaces/IValidatorSet.sol";
import "../contracts/interfaces/IStaking.sol";
import "../contracts/interfaces/IRuntimeUpgrade.sol";
import "../contracts/interfaces/IStakingPool.sol";
import "../contracts/interfaces/IInjector.sol";
import "../contracts/interfaces/IDeployerProxy.sol";
import "../contracts/interfaces/ITokenomics.sol";

import {ChainConfig} from "../contracts/ChainConfig.sol";
import {Staking} from "../contracts/Staking.sol";

/// @notice Test to verify gas optimization in _calcDelegatorRewardsAndPendingUndelegates
/// @dev The optimization uses storage instead of memory to avoid copying entire arrays
contract StakingCalcDelegatorRewardsGas is Test {
    Staking public staking;
    ChainConfig public chainConfig;

    uint16 public constant EPOCH_LEN = 1;
    uint256 public constant NUM_DELEGATIONS = 100;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            3, // number of main validators
            EPOCH_LEN, // epoch len
            50, // misdemeanorThreshold
            150, // felonyThreshold
            1, // validatorJailEpochLength
            0, // undelegatePeriod
            0, // minValidatorStakeAmount
            0 // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(1);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 0;

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        staking = new Staking(ctoStaking);

        IStaking stakingContract = IStaking(staking);
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(vm.addr(20));
        IGovernance governanceContract = IGovernance(vm.addr(20));
        IChainConfig chainConfigContract = IChainConfig(chainConfig);
        IRuntimeUpgrade runtimeUpgradeContract = IRuntimeUpgrade(vm.addr(20));
        IDeployerProxy deployerProxyContract = IDeployerProxy(vm.addr(20));
        ITokenomics tokenomicsContract = ITokenomics(vm.addr(20));

        chainConfig.initManually(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            runtimeUpgradeContract,
            deployerProxyContract,
            tokenomicsContract
        );

        staking.initManually(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            runtimeUpgradeContract,
            deployerProxyContract,
            tokenomicsContract
        );
    }

    /// @notice Test that getDelegatorFee gas usage is proportional to unprocessed queue items,
    ///         not total array size. After processing, gas should decrease significantly.
    function test_getDelegatorFee_GasScalesWithUnprocessedItems() public {
        address validator = vm.addr(1);
        address staker = vm.addr(2);
        vm.coinbase(vm.addr(256));
        vm.deal(staker, 10000 ether);
        vm.deal(block.coinbase, 10000 ether);

        // Create many delegations to build up the queue
        for (uint256 i = 0; i < NUM_DELEGATIONS; i++) {
            vm.prank(staker);
            staking.delegate{value: 1 ether}(validator);
            vm.roll(block.number + EPOCH_LEN);
            // Deposit rewards each epoch
            vm.prank(block.coinbase);
            staking.deposit{value: 0.1 ether}(validator);
        }
        vm.roll(block.number + EPOCH_LEN);

        // Measure gas for getDelegatorFee with large unprocessed queue (cold storage)
        uint256 gasBeforeLargeQueue = gasleft();
        uint256 fee1 = staking.getDelegatorFee(validator, staker);
        uint256 gasAfterLargeQueue = gasleft();
        uint256 gasUsedFirstCall = gasBeforeLargeQueue - gasAfterLargeQueue;

        console.log("=== Before processing queue ===");
        console.log("Queue size (delegations):", NUM_DELEGATIONS);
        console.log("Gas used for getDelegatorFee (1st call):", gasUsedFirstCall);
        console.log("Pending rewards:", fee1);

        // Process the queue by claiming rewards
        vm.prank(staker);
        uint256 gasBeforeClaim = gasleft();
        staking.claimDelegatorFee(validator);
        uint256 gasAfterClaim = gasleft();
        uint256 gasUsedClaim = gasBeforeClaim - gasAfterClaim;
        console.log("Gas used for claimDelegatorFee:", gasUsedClaim);

        // Measure gas for getDelegatorFee after queue is processed
        uint256 gasBeforeSmallQueue = gasleft();
        uint256 fee2 = staking.getDelegatorFee(validator, staker);
        uint256 gasAfterSmallQueue = gasleft();
        uint256 gasUsedSmallQueue = gasBeforeSmallQueue - gasAfterSmallQueue;

        console.log("=== After processing queue ===");
        console.log("Gas used for getDelegatorFee:", gasUsedSmallQueue);
        console.log("Pending rewards:", fee2);

        // Verify gas decreased significantly after processing
        console.log("=== Gas comparison ===");
        console.log("Gas reduction:", gasUsedFirstCall - gasUsedSmallQueue);
        console.log("Gas reduction percentage:", (gasUsedFirstCall - gasUsedSmallQueue) * 100 / gasUsedFirstCall, "%");

        assertLt(gasUsedSmallQueue, 4000);

        // Assert rewards were claimed
        assertEq(fee2, 0, "Rewards should be 0 after claiming");
    }
}
