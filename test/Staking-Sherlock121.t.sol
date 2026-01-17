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

contract StakingSherlock121 is Test {
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

    function test_CopyTheLatestValidSnapshot() public {
        address user;
        address validator = vm.addr(6);

        uint256 totalDelegated;
        uint256 totalRewards;

        user = vm.addr(1);
        vm.deal(user, 3000 ether);


        vm.startPrank(user);

        // Stake at epoch 0 but will modify next epoch (1)
        stakingPool.stake{value: 1 ether}(validator);

        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        assertEq(totalDelegated, 1001 ether);

        // Advance to epoch 5
        vm.roll(block.number + 5 * EPOCH_LEN);
        uint64 currentEpoch = staking.currentEpoch();

        // Stake at epoch 5 but will modify next epoch (6)
        stakingPool.stake{value: 1 ether}(validator);
        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        assertEq(totalDelegated, 1002 ether);
        vm.stopPrank();

        // Check values for epoch 5 (should be same as epoch 1)
        (,, totalDelegated,,,,,, totalRewards) = staking.getValidatorStatusAtEpoch(validator, currentEpoch);
        assertEq(totalDelegated, 1001 ether);

        // Deposit fees to validator that will modify the current epoch
        deal(block.coinbase, 3 ether);
        vm.prank(block.coinbase);
        // Deposit at epoch 5 but will modify current epoch (5) with copied data
        // from latest valid snapshot (here epoch 1)
        staking.deposit{value: 3 ether}(validator);

        (,, totalDelegated,,,,,, totalRewards) = staking.getValidatorStatusAtEpoch(validator, currentEpoch);

        // Make sure we dont copy future data to current epoch
        assertEq(totalDelegated, 1001 ether);
        assertEq(totalRewards, 3 ether);

    }

    function test_copyCurrentEpochSnapshot() public {
                address user;
        address validator = vm.addr(6);

        uint256 totalDelegated;
        uint256 totalRewards;

        user = vm.addr(1);
        vm.deal(user, 3000 ether);


        vm.startPrank(user);

        // Stake at epoch 0 but will modify next epoch (1)
        stakingPool.stake{value: 1 ether}(validator);

        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        assertEq(totalDelegated, 1001 ether);

        // Advance to epoch 100
        vm.roll(block.number + 100 * EPOCH_LEN);
        uint64 currentEpoch = staking.currentEpoch();

        // Stake at epoch 100 but will modify next epoch (101)
        stakingPool.stake{value: 1 ether}(validator);
        (,, totalDelegated,,,,,,) = staking.getValidatorStatus(validator);
        assertEq(totalDelegated, 1002 ether);
        vm.stopPrank();

        (,, totalDelegated,,,,,, totalRewards) = staking.getValidatorStatusAtEpoch(validator, currentEpoch);
        assertEq(totalDelegated, 0);
        assertEq(totalRewards, 0);

        deal(block.coinbase, 3 ether);
        vm.prank(block.coinbase);
        // Deposit at epoch 100 but will modify current epoch (100) with copied data
        // from CURRENT  snapshot cause all MAX_NB_EPOCH_TO_CHECK are empty
        staking.deposit{value: 3 ether}(validator);

        (,, totalDelegated,,,,,, totalRewards) = staking.getValidatorStatusAtEpoch(validator, currentEpoch);

        // Make sure we dont copy future data to current epoch
        assertEq(totalDelegated, 0 ether);
        assertEq(totalRewards, 3 ether);

    }
}
