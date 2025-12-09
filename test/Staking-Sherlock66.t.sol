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
    uint256 public constant MAX_VALIDATORS = 102;

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

        // Add a bunch of validators for epoch 1
        vm.startPrank(vm.addr(20));
        for (uint256 i = 2; i <= MAX_VALIDATORS; i++) {
            staking.addValidator(vm.addr(i));
        }
        vm.stopPrank();
    }

    function test_addValidator() public {
        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], vm.addr(1));

        // at epoch 1 we should have `MAX_VALIDATORS` validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, MAX_VALIDATORS);
        for (uint256 i = 0; i < avl.length; i++) {
            assertEq(avl[i], vm.addr(i+1));
        }
    }

    function test_removeValidator() public {
        // go to epoch 1 & remove one validator
        vm.roll(block.number + EPOCH_LEN);
        vm.prank(vm.addr(20));
        staking.removeValidator(vm.addr(MAX_VALIDATORS/2));

        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], vm.addr(1));

        // at epoch 1 we should have `MAX_VALIDATORS` validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, MAX_VALIDATORS);
        // at epoch 2 we should have `MAX_VALIDATORS-1` validators
        avl = staking.getActiveValidatorsList(2);
        assertEq(avl.length, MAX_VALIDATORS-1);
        for (uint256 i = 0; i < avl.length; i++) {
            if (i + 1 == MAX_VALIDATORS/2) {
                i++; // skip the removed validator
            }
            assertEq(avl[i], vm.addr(i+1));
        }
    }

    function test_activateValidator() public {
        vm.prank(vm.addr(MAX_VALIDATORS+1));
        staking.registerValidator(vm.addr(MAX_VALIDATORS+1), 0);

        vm.prank(vm.addr(20));
        staking.activateValidator(vm.addr(MAX_VALIDATORS+1));

        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], vm.addr(1));

        // at epoch 1 we should have `MAX_VALIDATORS+1` validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, MAX_VALIDATORS+1);
        for (uint256 i = 0; i < avl.length; i++) {
            assertEq(avl[i], vm.addr(i+1));
        }
    }

    function test_slash() public {
        // go to epoch 1 & jail one validator
        vm.roll(block.number + EPOCH_LEN);
        vm.startPrank(vm.addr(20));
        for (uint8 i = 0; i < 74; i++) {
            staking.slash(vm.addr(MAX_VALIDATORS/2));
        }
        // slash again to jail it
        staking.slash(vm.addr(MAX_VALIDATORS/2));
        vm.stopPrank();

        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], vm.addr(1));

        // at epoch 1 we should have `MAX_VALIDATORS` validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, MAX_VALIDATORS);
        // at epoch 2 we should have `MAX_VALIDATORS-1` validators
        avl = staking.getActiveValidatorsList(2);
        assertEq(avl.length, MAX_VALIDATORS-1);
        for (uint256 i = 0; i < avl.length; i++) {
            if (i + 1 == MAX_VALIDATORS/2) {
                i++; // skip the removed validator
            }
            assertEq(avl[i], vm.addr(i+1));
        }
    }

    function test_releaseValidatorFromJail() public {
        // go to epoch 1 & jail one validator
        vm.roll(block.number + EPOCH_LEN);
        vm.startPrank(vm.addr(20));
        for (uint8 i = 0; i < 74; i++) {
            staking.slash(vm.addr(MAX_VALIDATORS/2));
        }
        // slash again to jail it for epoch 3
        staking.slash(vm.addr(MAX_VALIDATORS/2));
        vm.stopPrank();

        // go to epoch 3 & release it for epoch 4
        vm.roll(block.number + EPOCH_LEN*2);
        staking.getValidatorStatus(vm.addr(MAX_VALIDATORS/2));
        staking.currentEpoch();
        vm.prank(vm.addr(MAX_VALIDATORS/2));
        staking.releaseValidatorFromJail(vm.addr(MAX_VALIDATORS/2));

        // at epoch 0 we should only have 1 validator
        address[] memory avl = staking.getActiveValidatorsList(0);
        assertEq(avl.length, 1);
        assertEq(avl[0], vm.addr(1));

        // at epoch 1 we should have `MAX_VALIDATORS` validators
        avl = staking.getActiveValidatorsList(1);
        assertEq(avl.length, MAX_VALIDATORS);
        // at epoch 2 we should have `MAX_VALIDATORS-1` validators
        avl = staking.getActiveValidatorsList(2);
        assertEq(avl.length, MAX_VALIDATORS-1);
        for (uint256 i = 0; i < avl.length; i++) {
            if (i + 1 == MAX_VALIDATORS/2) {
                i++; // skip the removed validator
            }
            assertEq(avl[i], vm.addr(i+1));
        }

        // at epoch 3 we should have `MAX_VALIDATORS-1` validators
        avl = staking.getActiveValidatorsList(3);
        assertEq(avl.length, MAX_VALIDATORS-1);
        for (uint256 i = 0; i < avl.length; i++) {
            if (i + 1 == MAX_VALIDATORS/2) {
                i++; // skip the removed validator
            }
            assertEq(avl[i], vm.addr(i+1));
        }

        // at epoch 4 we should have `MAX_VALIDATORS` validators again
        avl = staking.getActiveValidatorsList(4);
        assertEq(avl.length, MAX_VALIDATORS);
        for (uint256 i = 0; i < avl.length; i++) {
            // the unjailed validator will be added at the end of the list
            // that's why we need to skip the address at it's original position (if block)
            // and check the last element (else if block)
            if (i + 1 == MAX_VALIDATORS/2) {
                i++; // skip the removed validator
            } else if (i == avl.length - 1) {
                assertEq(avl[i], vm.addr(MAX_VALIDATORS/2));
            } else {
                assertEq(avl[i], vm.addr(i+1));
            }
        }
    }
}
