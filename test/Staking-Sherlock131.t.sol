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

import {Staking} from "../contracts/Staking.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract StakingSherlock131 is Test {
    Staking public staking;
    ChainConfig public chainConfig;
    uint16 public constant EPOCH_LEN = 100;
    event Claimed(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);

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
        initialStakeArray[0] = 1000 ether;

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

        vm.deal(address(staking), 1000 ether);
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

    function test_sherlock131() public {
        vm.roll(block.number + EPOCH_LEN * 100);

        address staker = vm.addr(1);
        address validator = vm.addr(5);

        // delegate
        vm.deal(staker, 1000 ether);
        uint256 stakeAmount = 100 ether;
        vm.prank(staker);
        staking.delegate{value: stakeAmount}(validator);

        // go to epoch 103
        vm.roll(block.number + EPOCH_LEN*2);

        // undelegate
        vm.prank(staker);
        staking.undelegate(validator, stakeAmount * 999 / 1000);

        // send rewards
        uint256 rewards = 20 ether;
        vm.deal(block.coinbase, rewards);
        vm.prank(block.coinbase);
        staking.deposit{value: rewards}(validator);


        // go to epoch 104
        vm.roll(block.number + EPOCH_LEN);

        uint256 delegatorFeeBeforeClaim = staking.getDelegatorFee(validator, staker);
        uint256 stakingBalanceBeforeClaim = address(staking).balance;
        console.log("delegatorFeeBeforeClaim", delegatorFeeBeforeClaim);
        console.log("stakingBalanceBeforeClaim", stakingBalanceBeforeClaim);

        // claim
        // uint256 expectedClaim = (1-0/1e4)*rewards*stakeAmount/(1000 ether + stakeAmount / 1000);
        // if we receive the expectedClaim above, it's incorrect.

        uint256 expectedClaim = (1-0/1e4)*rewards*stakeAmount/(1000 ether + stakeAmount);
        vm.expectEmit(true, true, true, true);
        emit Claimed(validator, staker, expectedClaim, staking.currentEpoch());
        vm.prank(staker);
        staking.claimDelegatorFee(validator);
    }
}
