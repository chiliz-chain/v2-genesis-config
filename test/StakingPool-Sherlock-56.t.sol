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

import {StakingPool} from "../contracts/StakingPool.sol";
import {Staking} from "../contracts/Staking.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract StakingPoolSherlock56 is Test {
    StakingPool public stakingPool;
    Staking public staking;
    ChainConfig public chainConfig;

    uint16 public constant EPOCH_LEN = 100;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            5, // number of main validators
            EPOCH_LEN, // epoch len
            50, // misdemeanorThreshold
            75, // felonyThreshold
            1, // validatorJailEpochLength
            1, // undelegatePeriod
            0, // minValidatorStakeAmount
            0 // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 0;

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        staking = new Staking(ctoStaking);

        bytes memory ctorStakingPool = abi.encodeWithSignature("ctor()");
        stakingPool = new StakingPool(ctorStakingPool);

        IStaking stakingContract = IStaking(staking);
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(stakingPool);
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

        stakingPool.initManually(
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

    /// @notice Last user to unstake from StakingPool shouldn't leave rewards stuck in the contract.
    ///         If another user stakes afer that they shouldn't have 0 shares.
    function test_Sherlock56() public {
        address staker1 = vm.addr(1);
        address staker2 = vm.addr(2);
        address validator = vm.addr(5);
        uint256 initialBalance = 1000 ether;
        vm.coinbase(vm.addr(256));
        vm.deal(staker1, initialBalance);
        vm.deal(staker2, initialBalance);
        vm.deal(block.coinbase, initialBalance);

        uint256 stakeAmount = 100 ether;

        // staker1 stake
        vm.prank(staker1);
        stakingPool.stake{value: stakeAmount}(validator);
        vm.roll(block.number + EPOCH_LEN);

        StakingPool.ValidatorPool memory validatorPoolBeforeUnstake = stakingPool.getValidatorPool(validator);
        // staker1 unstake
        vm.prank(staker1);
        stakingPool.unstake(validator, stakeAmount);
        StakingPool.ValidatorPool memory validatorPoolAfterUnstake = stakingPool.getValidatorPool(validator);

        // simulate reward accumulation on the validator
        uint256 rewards = 20 ether;
        vm.prank(block.coinbase);
        staking.deposit{value: rewards}(validator);
        vm.roll(block.number + EPOCH_LEN);

        // if sherlock-125 wasn't fixed we also need to claim
        if (validatorPoolBeforeUnstake.totalStakedAmount == validatorPoolAfterUnstake.totalStakedAmount) {
            vm.roll(block.number + EPOCH_LEN*2);
            vm.prank(staker1);
            stakingPool.claim(validator);
        }

        // make sure that staker1 can still read state
        assertEq(stakingPool.getStakedAmount(validator, staker1), 0);
        assertEq(stakingPool.getShares(validator, staker1), 0);

        // make sure totalStake is non-zero and share supply is 0
        assertGt(stakingPool.getValidatorPool(validator).totalStakedAmount, 0);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, 0);

        // staker2 stake
        vm.prank(staker2);
        stakingPool.stake{value: stakeAmount}(validator);

        // staker2 should have non-zero shares, and receive rewards meant for staker1
        assertGt(stakingPool.getStakedAmount(validator, staker2), stakeAmount);
        assertEq(stakingPool.getShares(validator, staker2), stakeAmount);
    }
}
