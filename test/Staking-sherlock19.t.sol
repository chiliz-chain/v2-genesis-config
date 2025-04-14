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

contract StakingSherlock19 is Test {
    Staking public staking;
    ChainConfig public chainConfig;
    uint16 public constant EPOCH_LEN = 100;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            1, // number of main validators
            EPOCH_LEN, // epoch len
            50, // misdemeanorThreshold
            75, // felonyThreshold
            1, // validatorJailEpochLength
            1, // undelegatePeriod
            1000 ether, // minValidatorStakeAmount
            1 ether // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 100000 ether;

        bytes memory ctorStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 3000);
        staking = new Staking(ctorStaking);

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

    function test_claimSystemFee() public {
        vm.roll(block.number + EPOCH_LEN);

        // simulate reward distribution
        vm.deal(block.coinbase, 10 ether);
        vm.prank(block.coinbase);
        staking.deposit{value: 10 ether}(vm.addr(5));

        // slash the validator `misdemeanorThreshold` times
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(vm.addr(20));
            staking.slash(vm.addr(5));
        }

        // claim the system fee & make sure that systemRewards received the funds
        staking.claimSystemFee(vm.addr(5), 2);

        assertEq(vm.addr(20).balance, 10 ether);
    }

    /// @notice calling claimValidatorFee() after claimSystemFee() shouldn't double count the system fee
    function test_claimSystemFee_DoubleCount() public {
        vm.roll(block.number + EPOCH_LEN);

        // simulate reward distribution for epoch 2
        vm.deal(block.coinbase, 20 ether);
        vm.prank(block.coinbase);
        staking.deposit{value: 10 ether}(vm.addr(5));

        // go to epoch 3
        vm.roll(block.number + 2*EPOCH_LEN);

        // simulate reward distribution for epoch 3
        vm.deal(block.coinbase, 10 ether);
        vm.prank(block.coinbase);
        staking.deposit{value: 10 ether}(vm.addr(5));

        // slash the validator `misdemeanorThreshold` times in epoch 3
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(vm.addr(20));
            staking.slash(vm.addr(5));
        }

        // go to epoch 4
        vm.roll(block.number + EPOCH_LEN);

        // claim the system fee & make sure that systemRewards received the funds
        staking.claimSystemFee(vm.addr(5), 4);

        assertEq(vm.addr(20).balance, 10 ether);

        // claim the validator fee & make sure that the validator received the funds and systemRewards balance didn't change
        vm.prank(vm.addr(5));
        staking.claimValidatorFeeAtEpoch(vm.addr(5), 4);
        assertEq(vm.addr(5).balance, 10 ether * 3000/10000);
        assertEq(vm.addr(20).balance, 10 ether);
    }
}
