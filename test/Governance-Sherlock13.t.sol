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

import {Governance} from "../contracts/Governance.sol";
import {Staking} from "../contracts/Staking.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract GovernanceSherlock13 is Test {
    Governance public governance;
    Staking public staking;
    ChainConfig public chainConfig;

    uint16 public constant EPOCH_LEN = 100;

    event ProposalExecuted(uint256 proposalId);

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

    /// @notice Validators shouldn't be able to manipulate proposal's quorum by deliberately going to jail.
    function test_sherlock13() public {
        vm.roll(block.number + EPOCH_LEN);

        address validator1 = vm.addr(5);
        address validator2 = vm.addr(6);

        // create proposal from validator1 and cast vote
        vm.prank(validator1);
        uint256 proposalId = governance.proposeWithCustomVotingPeriod(new address[](1), new uint256[](1), new bytes[](1), "dummy proposal", 2);
        vm.roll(block.number + 1);
        vm.prank(validator1);
        governance.castVote(proposalId, uint8(1));

        // jail validator1
        for (uint256 i = 0; i < 80; i++) {
            vm.prank(vm.addr(20));
            staking.slash(validator1);
        }
        (,uint8 status,,,,,,,) = staking.getValidatorStatus(validator1);
        assertEq(status, 3);

        // end the voting period & try to execute the proposal from validator2 (validator1 is jailed)
        vm.roll(block.number + 10);
        // vm.expectEmit(true, true, true, true);
        // emit ProposalExecuted(proposalId);
        vm.expectRevert(bytes("Governor: proposal not successful"));
        vm.prank(validator2);
        governance.execute(new address[](1), new uint256[](1), new bytes[](1), keccak256("dummy proposal"));

        // try to execute it in a future epoch when the quorum is decreased
        // should fail as well because the quorum for this proposal should be fetched from epoch when it was created
        vm.roll(block.number + EPOCH_LEN * 2);
        vm.expectRevert(bytes("Governor: proposal not successful"));
        vm.prank(validator2);
        governance.execute(new address[](1), new uint256[](1), new bytes[](1), keccak256("dummy proposal"));
    }
}
