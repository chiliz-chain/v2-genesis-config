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

contract Base is Test {
    StakingPool public stakingPool;
    Staking public staking;
    ChainConfig public chainConfig;

    address[] public validators;

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
            1000 ether, // minValidatorStakeAmount
            1 ether // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](5);
        valAddrArray[0] = vm.addr(5);
        valAddrArray[1] = vm.addr(6);
        valAddrArray[2] = vm.addr(7);
        valAddrArray[3] = vm.addr(8);
        valAddrArray[4] = vm.addr(9);
        uint256[] memory initialStakeArray = new uint256[](5);
        initialStakeArray[0] = 100000 ether;
        initialStakeArray[1] = 1000 ether;
        initialStakeArray[2] = 1000 ether;
        initialStakeArray[3] = 1000 ether;
        initialStakeArray[4] = 1000 ether;

        bytes memory ctoStaking =
            abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 700);
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

        vm.deal(address(staking), 104000 ether);
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

        // Getting Validators
        validators = stakingContract.getValidators();
    }

    function test_stake() public {
        // user stakes on validator 2
        uint256 i;
        address user;
        uint16 loop = 1;
        for (i = 1; i <= loop; i++) {
            user = vm.addr(i);
            vm.deal(user, 3000 ether);
            vm.prank(user);
            stakingPool.stake{value: 500 ether}(vm.addr(6));
        }
        for (i = 1; i <= loop; i++) {
            user = vm.addr(i);
            vm.prank(user);
            stakingPool.unstake(vm.addr(6), 1 ether);
        }

        vm.roll(block.number + 10 * 28800);

        vm.prank(vm.addr(1));
        vm.startSnapshotGas("A");

        stakingPool.claim(vm.addr(6));

        uint256 gasUsed = vm.stopSnapshotGas();
        console.log("Gas used for claim: ", gasUsed);
    }

    function test_sherlock121() public {
        address user;
        address validator = vm.addr(6);

        uint256 totalDelegated;

        user = vm.addr(1);
        vm.deal(user, 3000 ether);
        vm.startPrank(user);
        stakingPool.stake{value: 500 ether}(validator);

        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        console.log("Total Delegated: ", totalDelegated);
        assertEq(totalDelegated, 1500 ether);

        vm.roll(block.number + 5 * EPOCH_LEN);
        uint64 currentEpoch = staking.currentEpoch();

        stakingPool.stake{value: 500 ether}(validator);
        (,, totalDelegated,,,,,,) = staking.getValidatorStatusAtEpoch(validator, currentEpoch);
        console.log("Total Delegated previous epoch: ", totalDelegated);
        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        console.log("Total Delegated at changedAt epoch: ", totalDelegated);
        (,, totalDelegated,,,,,,) = staking.getValidatorStatusAtEpoch(validator, currentEpoch + 1);
        console.log("Total Delegated next epoch: ", totalDelegated);

        // assertEq(totalDelegated, 2000 ether);
    }
}
