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

contract StakingSherlock23 is Test {
    Staking public staking;
    ChainConfig public chainConfig;

    uint16 public constant EPOCH_LEN = 100;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            5, // number of main validators
            EPOCH_LEN, // epoch len
            5, // misdemeanorThreshold
            10, // felonyThreshold
            1, // validatorJailEpochLength
            1, // undelegatePeriod
            0, // minValidatorStakeAmount
            0 // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 100000 ether;

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 3000);
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

        vm.deal(address(staking), 100000 ether);
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

    /// @notice validators shouldn't be able to change misdemeanorThreshold
    ///         and claim more fees than they accumulated in the past.
    function test_getValidatorFeeAtEpoch() public {
        vm.roll(block.number + EPOCH_LEN);
        address validator = vm.addr(5);
        vm.coinbase(vm.addr(256));
        vm.deal(block.coinbase, 100_000 ether);

        // distribute rewards to staking in epoch 1
        vm.prank(block.coinbase);
        staking.deposit{value: 100 ether}(validator);

        // slash validator
        uint64 startEpoch = staking.currentEpoch();
        uint32 misdemeanorThreshold = chainConfig.getMisdemeanorThreshold(startEpoch);
        for (uint32 i = 0; i <= misdemeanorThreshold; i++) {
            vm.prank(vm.addr(20)); // slashing indicator address
            staking.slash(validator);
        }

        // increase misdemeanorThreshold
        vm.prank(vm.addr(20)); // governance address
        chainConfig.setMisdemeanorThreshold(misdemeanorThreshold*2);
        assertEq(chainConfig.getMisdemeanorThreshold(startEpoch + 1), misdemeanorThreshold*2);

        // advance the epochs
        vm.roll(block.number + EPOCH_LEN*2);

        // call getValidatorFeeAtEpoch for epochs 0 & 1 - the validator fee should be 0
        assertEq(staking.getValidatorFeeAtEpoch(validator, startEpoch + 1), 0);
    }
}
