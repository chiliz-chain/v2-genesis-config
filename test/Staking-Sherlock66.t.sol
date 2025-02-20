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

contract StakingSherlock66 is Test {
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
        valAddrArray[0] = vm.addr(1);
        uint256[] memory initialStakeArray = new uint256[](1);

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

    function test_addValidator() public {
        address val1 = vm.addr(1);

        address val2 = vm.addr(2);
        address val3 = vm.addr(3);
        address val4 = vm.addr(4);
        vm.startPrank(vm.addr(20));
        staking.addValidator(val2);
        staking.addValidator(val3);
        staking.addValidator(val4);
        vm.stopPrank();

        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], val1);

        // at epoch 1 we should have 4 validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, 4);
        assertEq(avl[0], val1);
        assertEq(avl[1], val2);
        assertEq(avl[2], val3);
        assertEq(avl[3], val4);
    }

    function test_removeValidator() public {
        address val1 = vm.addr(1);
        address val2 = vm.addr(2);
        address val3 = vm.addr(3);
        address val4 = vm.addr(4);
        vm.startPrank(vm.addr(20));
        staking.addValidator(val2);
        staking.addValidator(val3);
        staking.addValidator(val4);
        vm.stopPrank();

        // go to epoch 1 & remove one validator
        vm.roll(block.number + EPOCH_LEN);

        vm.prank(vm.addr(20));
        vm.startSnapshotGas("A");
        staking.removeValidator(val3);
        uint256 gasUsed = vm.stopSnapshotGas();
        console.log("gasUsed: ", gasUsed);

        // at epoch 1 we should have 4 validators
        address[] memory avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, 4);
        assertEq(avl[0], val1);
        assertEq(avl[1], val2);
        assertEq(avl[2], val3);
        assertEq(avl[3], val4);

        // at epoch 2 we should have 3 validators
        avl = staking.getActiveValidatorsList(2);
        assertEq(avl.length, 3);
        assertEq(avl[0], val1);
        assertEq(avl[1], val2);
        assertEq(avl[2], val4);
    }
}
