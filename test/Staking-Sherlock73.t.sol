// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm, console} from "forge-std/Test.sol";

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

import {ChainConfig} from "../contracts/ChainConfig.sol";
import {Staking} from "../contracts/Staking.sol";

contract StakingSherlock73 is Test {
    Staking public staking;
    ChainConfig public chainConfig;

    uint16 public constant EPOCH_LEN = 1;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            3, // number of main validators
            EPOCH_LEN, // epoch len
            50, // misdemeanorThreshold
            150, // felonyThreshold
            1, // validatorJailEpochLength
            0, // undelegatePeriod
            0, // minValidatorStakeAmount
            0 // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(1);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 0;

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

    /// @notice the fees shouldn't get stuck if a user provides an epoch
    ///         which is between the epoch of two consecutive delegations.
    function test_claimDelegatorFeeAtEpoch_PartialProcessing() public {
        address validator = vm.addr(1);
        address staker = vm.addr(2);
        vm.coinbase(vm.addr(256));
        vm.deal(staker, 1000 ether);
        vm.deal(block.coinbase, 1000 ether);

        vm.prank(staker);
        staking.delegate{value: 1 ether}(validator);
        console.log("First delegate epoch: ", staking.currentEpoch());

        for (uint256 i = 0; i < 5; i++) {
            console.log("Rewards deposited at epoch: ", staking.currentEpoch());
            vm.roll(block.number + EPOCH_LEN);
            vm.prank(block.coinbase);
            staking.deposit{value: 1 ether}(validator);
        }

        vm.roll(block.number + EPOCH_LEN);
        vm.prank(staker);
        staking.delegate{value: 1 ether}(validator);
        console.log("Second delegate epoch: ", staking.currentEpoch());
        console.log("Accrued rewards: ", staking.getDelegatorFee(validator, staker));
        assertEq(staking.getDelegatorFee(validator, staker), 5 ether);

        vm.prank(staker);
        vm.recordLogs();
        staking.claimDelegatorFeeAtEpoch(validator, 4);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (uint256 claimedRewards,) = abi.decode(entries[0].data, (uint256,uint64));
        console.log("Rewards for epochs 1, 2, 3: ", claimedRewards);
        console.log("Rewards left after partial claim: ", staking.getDelegatorFee(validator, staker));
        assertEq(claimedRewards, 2 ether);
        assertEq(staking.getDelegatorFee(validator, staker), 3 ether);
    }

    function test_claimDelegatorFeeAtEpoch_FullProcessing() public {
        address validator = vm.addr(1);
        address staker = vm.addr(2);
        vm.coinbase(vm.addr(256));
        vm.deal(staker, 1000 ether);
        vm.deal(block.coinbase, 1000 ether);

        vm.prank(staker);
        staking.delegate{value: 1 ether}(validator);
        console.log("First delegate epoch: ", staking.currentEpoch());

        for (uint256 i = 0; i < 5; i++) {
            console.log("Rewards deposited at epoch: ", staking.currentEpoch());
            vm.roll(block.number + EPOCH_LEN);
            vm.prank(block.coinbase);
            staking.deposit{value: 1 ether}(validator);
        }

        vm.roll(block.number + EPOCH_LEN);
        vm.prank(staker);
        staking.delegate{value: 1 ether}(validator);
        console.log("Second delegate epoch: ", staking.currentEpoch());
        console.log("Accrued rewards: ", staking.getDelegatorFee(validator, staker));
        assertEq(staking.getDelegatorFee(validator, staker), 5 ether);

        vm.prank(staker);
        vm.recordLogs();
        staking.claimDelegatorFeeAtEpoch(validator, 7);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (uint256 claimedRewards,) = abi.decode(entries[0].data, (uint256,uint64));
        console.log("Claimed rewards: ", claimedRewards);
        console.log("Remaining rewards: ", staking.getDelegatorFee(validator, staker));
        assertEq(claimedRewards, 5 ether);
        assertEq(staking.getDelegatorFee(validator, staker), 0);
    }
}
