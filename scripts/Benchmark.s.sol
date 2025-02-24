// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

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

contract BenchmarkScriptEnv is Script {
    Staking internal staking;
    ChainConfig internal chainConfig;

    uint16 internal constant EPOCH_LEN = 100;
    uint256 internal constant MAX_GAS = 24_000_000;


    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            type(uint32).max, // number of main validators
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
}

contract AddValidatorBenchmarkScript is BenchmarkScriptEnv {
    function run() public {
        // keep adding validators until addValidator exceeds block gas limit
        uint256 counter = 2;
        uint256 addValidatorGas = 0;
        uint256 firstCallGas = 0;
        uint256 lastUsage = 0;
        vm.startPrank(vm.addr(20));
        while(addValidatorGas < MAX_GAS){
            lastUsage = addValidatorGas;
            addValidatorGas = addValidatorGasUsage(vm.addr(counter));
            if (counter == 2) {
                firstCallGas = addValidatorGas;
            }
            counter++;
            vm.roll(block.number + EPOCH_LEN);
        }
        vm.stopPrank();

        console.log("addValidator");
        console.log("Number of validators: ", --counter);
        console.log("First Call Gas: ", firstCallGas);
        console.log("Total Gas: ", lastUsage);
        console.log("====");
    }

    function addValidatorGasUsage(address newValidator) internal returns (uint256 gasUsed) {
        vm.startSnapshotGas("addValidatorGasUsage");
        staking.addValidator(newValidator);
        gasUsed = vm.stopSnapshotGas();
    }
}

contract GetValidatorsPerEpochBenchmarkScript is BenchmarkScriptEnv {
    function run() public {
        // keep adding validators until getValidators exceeds block gas limit
        uint64 nextEpoch = staking.nextEpoch();
        uint256 getValidatorsGas = getValidatorsGasUsage(nextEpoch);
        uint256 counter = 2;
        uint256 firstCallGas = 0;
        uint256 lastUsage = 0;
        vm.startPrank(vm.addr(20));
        while(getValidatorsGas < MAX_GAS){
            staking.addValidator(vm.addr(counter));
            lastUsage = getValidatorsGas;
            getValidatorsGas = getValidatorsGasUsage(nextEpoch);
            if (counter == 2) {
                firstCallGas = getValidatorsGas;
            }
            counter++;
        }
        vm.stopPrank();

        console.log("getValidators");
        console.log("Number of validators: ", counter--);
        console.log("First Call Gas: ", firstCallGas);
        console.log("Total Gas: ", lastUsage);
        console.log("====");
    }

    function getValidatorsGasUsage(uint64 epoch) internal returns (uint256 gasUsed) {
        vm.startSnapshotGas("getValidatorsGasUsage");
        staking.getValidatorsAtEpoch(epoch);
        gasUsed = vm.stopSnapshotGas();
    }
}

contract GetValidatorsBenchmarkScript is BenchmarkScriptEnv {
    function run() public {
        // keep adding validators until getValidators exceeds block gas limit
        uint256 getValidatorsGas = getValidatorsGasUsage();
        uint256 counter = 2;
        uint256 firstCallGas = 0;
        uint256 lastUsage = 0;
        vm.startPrank(vm.addr(20));
        while(getValidatorsGas < MAX_GAS){
            staking.addValidator(vm.addr(counter));
            lastUsage = getValidatorsGas;
            getValidatorsGas = getValidatorsGasUsage();
            if (counter == 2) {
                firstCallGas = getValidatorsGas;
            }
            counter++;
        }
        vm.stopPrank();

        console.log("getValidators");
        console.log("Number of validators: ", --counter);
        console.log("First Call Gas: ", firstCallGas);
        console.log("Total Gas: ", lastUsage);
        console.log("====");
    }

    function getValidatorsGasUsage() internal returns (uint256 gasUsed) {
        vm.startSnapshotGas("getValidatorsGasUsage");
        staking.getValidators();
        gasUsed = vm.stopSnapshotGas();
    }
}

contract RemoveValidatorBenchmarkScript is BenchmarkScriptEnv {
    // add validator
    // go to next epoch
    // remove the validator (at last index)
    function run() public {
        // keep adding validators until removeValidator exceeds block gas limit
        uint256 removeValidatorGas;
        uint256 counter = 2;
        uint256 firstCallGas = 0;
        uint256 lastUsage = 0;
        vm.startPrank(vm.addr(20));
        while(removeValidatorGas < MAX_GAS) {
            // adds validators in next epoch
            for (uint256 i = counter; i <= counter * 2; i++) {
                staking.addValidator(vm.addr(i));
            }

            vm.roll(block.number + EPOCH_LEN);

            // removes validator in next epoch
            // validator with addreee = vm.addr(counter), will be at the end of validators list
            // that will be the worst case scenario
            lastUsage = removeValidatorGas;
            removeValidatorGas = removeValidatorGasUsage(vm.addr(counter * 2));
            if (counter == 2) {
                firstCallGas = removeValidatorGas;
            }
            counter = counter * 2 + 1;
        }
        vm.stopPrank();

        console.log("removeValidator");
        console.log("Number of validators: ", (counter - 1) / 2);
        console.log("First Call Gas: ", firstCallGas);
        console.log("Total Gas: ", lastUsage);
        console.log("====");
    }

    function removeValidatorGasUsage(address validator) internal returns (uint256 gasUsed) {
        vm.startSnapshotGas("removeValidatorGasUsage");
        staking.removeValidator(validator);
        gasUsed = vm.stopSnapshotGas();
    }
}
