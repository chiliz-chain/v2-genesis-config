// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, stdStorage, StdStorage, console} from "forge-std/Test.sol";

import {IChainConfig} from "../contracts/interfaces/IChainConfig.sol";
import {IGovernance} from "../contracts/interfaces/IGovernance.sol";
import {ISlashingIndicator} from "../contracts/interfaces/ISlashingIndicator.sol";
import {ISystemReward} from "../contracts/interfaces/ISystemReward.sol";
import {IRuntimeUpgradeEvmHook} from "../contracts/interfaces/IRuntimeUpgradeEvmHook.sol";
import {IValidatorSet} from "../contracts/interfaces/IValidatorSet.sol";
import {IStaking} from "../contracts/interfaces/IStaking.sol";
import {IRuntimeUpgrade} from "../contracts/interfaces/IRuntimeUpgrade.sol";
import {IStakingPool} from "../contracts/interfaces/IStakingPool.sol";
import {IInjector} from "../contracts/interfaces/IInjector.sol";
import {IDeployerProxy} from "../contracts/interfaces/IDeployerProxy.sol";
import {ITokenomics} from "../contracts/interfaces/ITokenomics.sol";

import {StakingPool} from "../contracts/StakingPool.sol";
import {Staking} from "../contracts/Staking.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract StakingPoolTest is Test {
    using stdStorage for StdStorage;

    StakingPool public stakingPool;
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
            1 // minStakingAmount
        );
        ChainConfig chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        Staking staking = new Staking(ctoStaking);

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

    function test_StakeUnstakeClaimFlowWithMultipleStakers() public {
        address staker1 = vm.addr(1);
        address staker2 = vm.addr(2);
        address validator = vm.addr(5);
        uint256 initialBalance = 100_000 ether;
        vm.coinbase(vm.addr(256));
        vm.deal(staker1, initialBalance);
        vm.deal(staker2, initialBalance);
        vm.deal(block.coinbase, initialBalance);

        uint256 stakedAmount = 100 ether;

        // stake
        vm.prank(staker1);
        stakingPool.stake{value: stakedAmount}(validator);
        vm.prank(staker2);
        stakingPool.stake{value: stakedAmount}(validator);

        // verify that the state was updated
        assertEq(stakingPool.getStakedAmount(validator, staker1), stakedAmount);
        assertEq(stakingPool.getShares(validator, staker1), stakedAmount);
        assertEq(stakingPool.getStakedAmount(validator, staker2), stakedAmount);
        assertEq(stakingPool.getShares(validator, staker2), stakedAmount);
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, stakedAmount * 2);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, stakedAmount * 2);

        vm.roll(block.number + EPOCH_LEN);

        // simulate reward accumulation on the validator
        vm.prank(block.coinbase);
        staking.deposit{value: 20 ether}(validator);
        vm.roll(block.number + EPOCH_LEN);

        // make sure that the stakers received rewards
        uint256 staker1Stake = stakingPool.getStakedAmount(validator, staker1);
        uint256 staker2Stake = stakingPool.getStakedAmount(validator, staker2);
        assertGt(staker1Stake, stakedAmount);
        assertGt(staker2Stake, stakedAmount);

        // unstake from staker1
        uint256 unstakeAmount = staker1Stake - (staker1Stake % 1e10); // remove remainder
        uint256 stakerSharesBeforeUnstake = stakingPool.getShares(validator, staker1);
        StakingPool.ValidatorPool memory validatorPoolBeforeUnstake = stakingPool.getValidatorPool(validator);
        vm.prank(staker1);
        stakingPool.unstake(validator, unstakeAmount);

        // verify that the state was updated (staked amount & shares were decremented)
        assertEq(stakingPool.getStakedAmount(validator, staker1), staker1Stake % 1e10);
        assertLt(stakingPool.getShares(validator, staker1), stakerSharesBeforeUnstake);
        assertLt(stakingPool.getValidatorPool(validator).totalStakedAmount, validatorPoolBeforeUnstake.totalStakedAmount);
        assertLt(stakingPool.getValidatorPool(validator).sharesSupply, validatorPoolBeforeUnstake.sharesSupply);

        // verify that staker2 was not affected
        assertEq(stakingPool.getStakedAmount(validator, staker2), staker2Stake);

        // unstake from staker2
        vm.prank(staker2);
        stakingPool.unstake(validator, unstakeAmount);

        StakingPool.ValidatorPool memory validatorPoolBeforeClaim = stakingPool.getValidatorPool(validator);

        // claim
        vm.roll(block.number + EPOCH_LEN * 2); // cooldown period
        vm.prank(staker1);
        stakingPool.claim(validator);
        vm.prank(staker2);
        stakingPool.claim(validator);

        // verify that the staked amount & shares didn't change
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, validatorPoolBeforeClaim.totalStakedAmount);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, validatorPoolBeforeClaim.sharesSupply);

        // verify the balances
        assertEq(staker1.balance, initialBalance - stakedAmount + unstakeAmount);
        assertEq(staker2.balance, initialBalance - stakedAmount + unstakeAmount);
    }

    /// @notice verify that claim() function decrements staked amounts & shares
    ///         for accounts that unstaked before the upgrade
    function test_StakeUnstakeClaimFlowBeforeChange() public {
        address staker = vm.addr(1);
        address validator = vm.addr(5);
        uint256 stakeAmount = 100 ether;

        // stake
        vm.deal(staker, 1000 ether);
        vm.prank(staker);
        stakingPool.stake{value: stakeAmount}(validator);

        StakingPool.ValidatorPool memory validatorPoolBeforeUnstake = stakingPool.getValidatorPool(validator);
        uint256 stakerSharesBeforeUnstake = stakingPool.getShares(validator, staker);

        // unstake
        vm.prank(staker);
        stakingPool.unstake(validator, stakeAmount);

        // reset totalStake, shareSupply, _unstakedPostSherlockSupplyFixUpdate, staker shares
        bytes32 validatorPoolsSlot = keccak256(abi.encode(validator, 102));
        bytes32 stakerSharesSlot = keccak256(abi.encode(validator, 104));
        bytes32 postAuditFixMappingSlot = keccak256(abi.encode(staker, 105));

        vm.store(address(stakingPool), bytes32(uint256(validatorPoolsSlot) + 1), bytes32(validatorPoolBeforeUnstake.sharesSupply));
        vm.store(address(stakingPool), bytes32(uint256(validatorPoolsSlot) + 2), bytes32(validatorPoolBeforeUnstake.totalStakedAmount));
        vm.store(address(stakingPool), keccak256(abi.encode(staker, stakerSharesSlot)), bytes32(stakerSharesBeforeUnstake));
        vm.store(address(stakingPool), postAuditFixMappingSlot, bytes32(abi.encode(false)));

        // claim
        vm.roll(block.number + EPOCH_LEN * 2); // cooldown period
        vm.prank(staker);
        stakingPool.claim(validator);

        // verify that the staked amount & shares were decremented in claim()
        assertEq(stakingPool.getStakedAmount(validator, staker), 0);
        assertEq(stakingPool.getShares(validator, staker), 0);
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, 0);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, 0);
    }
}
