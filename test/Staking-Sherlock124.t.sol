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

contract StakingSherlock124 is Test {
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

    function test_Sherlock124() public {
        address staker1 = vm.addr(1);
        address staker2 = vm.addr(2);
        address validator = vm.addr(5);
        uint256 initialBalance = 1000 ether;
        vm.coinbase(vm.addr(256));
        vm.deal(staker1, initialBalance);
        vm.deal(staker2, initialBalance);
        vm.deal(validator, initialBalance);
        vm.deal(block.coinbase, initialBalance);

        // staker1 stake
        uint256 stakeAmount = 1 ether;
        vm.prank(staker1);
        stakingPool.stake{value: stakeAmount}(validator);
        vm.roll(block.number + EPOCH_LEN);

        // distritube rewards
        uint256 rewards = 10000050000000000;
        vm.prank(block.coinbase);
        staking.deposit{value: rewards}(validator);
        vm.roll(block.number + EPOCH_LEN);

        assertEq(stakingPool.getShares(validator, staker1), stakeAmount);
        assertEq(stakingPool.getStakedAmount(validator, staker1), stakeAmount + rewards); // the staked amount will be 1010000049999999999

        // unstake & claim
        vm.prank(staker1);
        uint256 unstakeAmount = stakeAmount + rewards - 1; // will fail here, cause the unstake amount must be evenly divisible by Staking.BALANCE_COMPACT_PRECISION = 1e10
        stakingPool.unstake(validator, unstakeAmount);
        vm.roll(block.number + EPOCH_LEN * 2);
        vm.prank(staker1);
        stakingPool.claim(validator);

        assertEq(stakingPool.getShares(validator, staker1), 0);
        assertEq(stakingPool.getStakedAmount(validator, staker1), 1);
        StakingPool.ValidatorPool memory vp = stakingPool.getValidatorPool(validator);
        assertEq(vp.sharesSupply, 0);
        assertEq(vp.totalStakedAmount, 1);
    }
}
