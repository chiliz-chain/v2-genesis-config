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
import {Governance} from "../contracts/Governance.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract GovernanceSherlock66 is Test {
    Staking public staking;
    Governance public governance;

    uint16 public constant EPOCH_LEN = 100;

    function setUp() public {
        bytes memory ctorChainConfig = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            3, // number of main validators
            EPOCH_LEN, // epoch len
            50, // misdemeanorThreshold
            75, // felonyThreshold
            1, // validatorJailEpochLength
            1, // undelegatePeriod
            0, // minValidatorStakeAmount
            0 // minStakingAmount
        );
        ChainConfig chainConfig = new ChainConfig(ctorChainConfig);

        address[] memory valAddrArray = new address[](4);
        valAddrArray[0] = vm.addr(5);
        valAddrArray[1] = vm.addr(6);
        valAddrArray[2] = vm.addr(7);
        valAddrArray[3] = vm.addr(8);
        uint256[] memory initialStakeArray = new uint256[](4);
        initialStakeArray[0] = 40 ether;
        initialStakeArray[1] = 30 ether;
        initialStakeArray[2] = 20 ether;
        initialStakeArray[3] = 10 ether;

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        staking = new Staking(ctoStaking);

        bytes memory ctorGovernance = abi.encodeWithSignature("ctor(uint256)", EPOCH_LEN);
        governance = new Governance(ctorGovernance);

        IStaking stakingContract = IStaking(staking);
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(vm.addr(20));
        IGovernance governanceContract = IGovernance(governance);
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

        vm.deal(address(staking), 100 ether);
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
    }

    function test_quorum() public {
        uint256 initialQuorum = (90e18) * 2/3;
        assertEq(governance.quorum(block.number), initialQuorum);

        staking.delegate{value: 50 ether}(vm.addr(8));

        vm.roll(block.number + EPOCH_LEN);

        uint256 newQuorum = (120e18) * 2/3;

        assertEq(governance.quorum(block.number - EPOCH_LEN), initialQuorum);
        assertEq(governance.quorum(block.number), newQuorum);
    }
}
