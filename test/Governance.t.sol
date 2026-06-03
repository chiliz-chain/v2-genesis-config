// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

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
import {JsTruffleFixture} from "./JsTruffleFixture.sol";

/// @notice `GovernancePepper8`: integrated staking + real `Governance`. `GovernanceJs*Test`: Fake staking/governance (`governance.js` parity), split by fixture.
contract GovernancePepper8 is Test {
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

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);
        initialStakeArray[0] = 5 ether;

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

        vm.deal(address(staking), 5 ether);
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

    function test_EmptyProposal() public {
        vm.roll(block.number + EPOCH_LEN);

        address validator1 = vm.addr(5);

        // create proposal from validator1 and cast vote
        vm.prank(validator1);
        uint256 proposalId = governance.proposeWithCustomVotingPeriod(new address[](1), new uint256[](1), new bytes[](1), "empty proposal", 2);
        vm.roll(block.number + 1);
        vm.prank(validator1);
        governance.castVote(proposalId, uint8(1));


        // end the voting period & try to execute the proposal
        vm.roll(block.number + 10);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        vm.prank(validator1);
        governance.execute(new address[](1), new uint256[](1), new bytes[](1), keccak256("empty proposal"));
    }

    function test_IsProposer() public {

        address validator = vm.addr(5);
        address proposer = vm.addr(6);

        vm.startPrank(address(governance));
        governance.activateProposerRegistry();
        governance.addProposer(proposer);
        vm.stopPrank();

        assertEq(governance.isProposer(validator), true, "validator should be a proposer");
        assertEq(governance.isProposer(proposer), true, "proposer should be a proposer");
        assertEq(governance.isProposer(vm.addr(7)), false, "non-proposer should not be a proposer");
    }
}

/// @notice Port of `genesis/test/governance.js`. `castVoteBySig` omitted (EIP-712 off-chain signing).
/// @dev Split into focused test contracts so each `setUp()` matches the scenario (stake splits and voting period differ).

contract GovernanceJsVotingPowerTest is JsTruffleFixture {
    MockChain internal chain;
    address internal delegatorAccount = vm.addr(200);
    address internal validatorA = vm.addr(201);
    address internal validatorB = vm.addr(202);
    address internal newOwnerA = vm.addr(203);
    address internal newOwnerB = vm.addr(204);

    function setUp() public {
        address[] memory genesisValidators = new address[](2);
        genesisValidators[0] = validatorA;
        genesisValidators[1] = validatorB;
        uint256[] memory genesisStakes = new uint256[](2);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;
        address[] memory noDeployers = new address[](0);

        chain = deployMockChain(
            genesisValidators, genesisStakes, rewardToBurn, fullShare, noDeployers, vm.addr(1), 10, 2
        );

        vm.deal(delegatorAccount, 10 ether);
        vm.prank(delegatorAccount);
        chain.staking.delegate{value: 1 ether}(validatorA);
        vm.prank(delegatorAccount);
        chain.staking.delegate{value: 1 ether}(validatorB);
        rollToNextEpoch(chain, 10);
    }

    /// @notice Total voting supply and per-owner power follow delegated stake; changing validator owner moves power to new owner.
    function test_votingPowerMovesWithValidatorOwner() public {
        assertEq(chain.governance.getVotingSupply(), 2 ether);
        assertEq(chain.governance.getVotingPower(validatorA), 1 ether);
        assertEq(chain.governance.getVotingPower(validatorB), 1 ether);

        vm.prank(validatorA);
        chain.staking.changeValidatorOwner(validatorA, newOwnerA);
        vm.prank(validatorB);
        chain.staking.changeValidatorOwner(validatorB, newOwnerB);

        assertEq(chain.governance.getVotingSupply(), 2 ether);
        assertEq(chain.governance.getVotingPower(newOwnerA), 1 ether);
        assertEq(chain.governance.getVotingPower(newOwnerB), 1 ether);
    }
}

contract GovernanceJsVoteAfterOwnerChangeTest is JsTruffleFixture {
    MockChain internal chain;
    address internal delegatorAccount = vm.addr(200);
    address internal validatorA = vm.addr(201);
    address internal validatorB = vm.addr(202);
    address internal newOwnerA = vm.addr(203);

    function setUp() public {
        address[] memory genesisValidators = new address[](2);
        genesisValidators[0] = validatorA;
        genesisValidators[1] = validatorB;
        uint256[] memory genesisStakes = new uint256[](2);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;
        address[] memory noDeployers = new address[](0);

        chain = deployMockChain(
            genesisValidators, genesisStakes, rewardToBurn, fullShare, noDeployers, vm.addr(1), 10, 5
        );

        vm.deal(delegatorAccount, 10 ether);
        vm.prank(delegatorAccount);
        chain.staking.delegate{value: 1 ether}(validatorA);
        vm.prank(delegatorAccount);
        chain.staking.delegate{value: 2 ether}(validatorB);
        rollToNextEpoch(chain, 10);
    }

    /// @notice Vote is keyed by validator identity: after owner transfer, new owner cannot vote again on same proposal; proposal ends Defeated.
    function test_cannotVoteAgainAfterValidatorOwnerChange() public {
        address[] memory targets = new address[](1);
        targets[0] = delegatorAccount;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(validatorA);
        uint256 proposalId = chain.governance.propose(targets, values, calldatas, "empty proposal");
        vm.roll(block.number + 2);
        assertEq(uint8(chain.governance.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.prank(validatorA);
        chain.governance.castVote(proposalId, uint8(1));
        assertEq(uint8(chain.governance.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.prank(validatorA);
        chain.staking.changeValidatorOwner(validatorA, newOwnerA);
        vm.expectRevert(bytes("GovernorVotingSimple: vote already cast"));
        vm.prank(newOwnerA);
        chain.governance.castVote(proposalId, uint8(1));

        rollToNextEpoch(chain, 10);
        assertEq(uint8(chain.governance.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }
}

contract GovernanceJsProposerRegistryTest is JsTruffleFixture {
    MockChain internal chain;
    address internal delegator = vm.addr(200);
    address internal valTopStake = vm.addr(201);
    address internal valSecondStake = vm.addr(202);
    address internal valThirdStake = vm.addr(203);
    address internal valCandidateLowStake = vm.addr(204);
    address internal registeredListProposer = vm.addr(205);
    address internal valTopIntermediateOwner = vm.addr(206);
    address internal valTopFinalOwner = vm.addr(207);

    function setUp() public {
        address[] memory genesisValidators = new address[](4);
        genesisValidators[0] = valTopStake;
        genesisValidators[1] = valSecondStake;
        genesisValidators[2] = valThirdStake;
        genesisValidators[3] = valCandidateLowStake;
        uint256[] memory genesisStakes = new uint256[](4);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;
        address[] memory noDeployers = new address[](0);

        chain = deployMockChain(
            genesisValidators, genesisStakes, rewardToBurn, fullShare, noDeployers, vm.addr(1), 10, 5
        );

        chain.governance.activateProposerRegistry();
        chain.governance.addProposer(registeredListProposer);

        vm.deal(delegator, 100 ether);
        vm.prank(delegator);
        chain.staking.delegate{value: 4 ether}(valTopStake);
        vm.prank(delegator);
        chain.staking.delegate{value: 3 ether}(valSecondStake);
        vm.prank(delegator);
        chain.staking.delegate{value: 2 ether}(valThirdStake);
        vm.prank(delegator);
        chain.staking.delegate{value: 1 ether}(valCandidateLowStake);
        rollToNextEpoch(chain, 10);
    }

    /// @notice Registry on: main validators + list proposer propose; candidate and delegator cannot; owner transfer updates proposer rights.
    function test_proposerRegistryAndMainValidators() public {
        address[] memory targets = new address[](1);
        targets[0] = delegator;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(valTopStake);
        chain.governance.propose(targets, values, calldatas, "test proposal 0");
        vm.prank(valSecondStake);
        chain.governance.propose(targets, values, calldatas, "test proposal 1");
        vm.prank(valThirdStake);
        chain.governance.propose(targets, values, calldatas, "test proposal 2");

        vm.expectRevert(bytes("Governance: only proposer or active main validator owner"));
        vm.prank(valCandidateLowStake);
        chain.governance.propose(targets, values, calldatas, "test proposal 4");

        vm.prank(registeredListProposer);
        chain.governance.propose(targets, values, calldatas, "test proposal 5");

        vm.expectRevert(bytes("Governance: only proposer or active main validator owner"));
        vm.prank(delegator);
        chain.governance.propose(targets, values, calldatas, "test proposal 6");

        vm.prank(valTopStake);
        chain.staking.changeValidatorOwner(valTopStake, valTopIntermediateOwner);
        vm.prank(valTopIntermediateOwner);
        chain.staking.changeValidatorOwner(valTopStake, valTopFinalOwner);
        vm.prank(valTopFinalOwner);
        chain.governance.propose(targets, values, calldatas, "test proposal 7");

        vm.expectRevert(bytes("Governance: only proposer or active main validator owner"));
        vm.prank(valTopIntermediateOwner);
        chain.governance.propose(targets, values, calldatas, "test proposal 8");
    }
}
