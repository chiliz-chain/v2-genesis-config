// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
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

import {Governance} from "../contracts/Governance.sol";
import {Staking} from "../contracts/Staking.sol";
import {StakingPool} from "../contracts/StakingPool.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract StakingPoolSherlock134 is Test {
    StakingPool public stakingPool;
    Staking public staking;
    ChainConfig public chainConfig;
    Governance public governance;

    uint16 public constant EPOCH_LEN = 100;

    address public staker;
    address public validator;

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

        address[] memory valAddrArray = new address[](2);
        valAddrArray[0] = vm.addr(5);
        valAddrArray[1] = vm.addr(6);
        uint256[] memory initialStakeArray = new uint256[](2);
        initialStakeArray[0] = 5 ether;
        initialStakeArray[1] = 5 ether;

        bytes memory ctoStaking =
            abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        staking = new Staking(ctoStaking);

        bytes memory ctorStakingPool = abi.encodeWithSignature("ctor()");
        stakingPool = new StakingPool(ctorStakingPool);

        bytes memory ctorGovernance = abi.encodeWithSignature("ctor(uint256)", EPOCH_LEN);
        governance = new Governance(ctorGovernance);

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

        vm.deal(address(staking), 10 ether);

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

        governance.initManually(
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

        staker = vm.addr(1);
        vm.deal(staker, 1000 ether);
        validator = vm.addr(5);
    }

    function testDustRewardsManagement() public {
        IStakingPool.ValidatorPool memory vp;

        // Add some fake funds to the StakingPool contract
        vm.deal(address(stakingPool), 1000 ether);

        vm.prank(staker);
        stakingPool.stake{value: 100 ether}(validator);

        // Create a mock implementation for redelegateDelegatorFee
        uint256 dustRewards = 300 * 1e18; // 300 CHZ
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IStaking.redelegateDelegatorFee.selector, validator),
            abi.encode(0, dustRewards)
        );

        // Trigger the advanceStakingRewards modifier by calling stake
        vm.prank(staker);
        stakingPool.stake{value: 1 ether}(validator);

        // Verify dust rewards are accumulated but not yet sent
        vp = stakingPool.getValidatorPool(validator);
        assertEq(vp.dustRewards, dustRewards, "Dust rewards should be accumulated");

        // Add more dust rewards to exceed the threshold
        uint256 additionalDustRewards = 250 * 1e18; // 250 CHZ
        // Total should now be 550 CHZ, exceeding the 500 CHZ threshold

        // Update the redelegateDelegatorFee mock
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IStaking.redelegateDelegatorFee.selector, validator),
            abi.encode(0, additionalDustRewards)
        );

        // Verify the deposit function was called with the correct amount
        uint256 expectedDepositAmount = dustRewards + additionalDustRewards;
        vm.expectCall(
            address(staking), expectedDepositAmount, abi.encodeWithSelector(IStaking.deposit.selector, validator)
        );

        // Trigger the advanceStakingRewards modifier again
        // and it should trigger the deposit function as well
        vm.prank(staker);
        stakingPool.stake{value: 1 ether}(validator);

        // Verify dust rewards were sent to the staking contract
        vp = stakingPool.getValidatorPool(validator);
        assertEq(vp.dustRewards, 0, "Dust rewards should be reset to 0 after deposit");
    }
}
