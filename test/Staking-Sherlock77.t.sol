pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import "../contracts/Staking.sol";
import "../contracts/SlashingIndicator.sol";
import "../contracts/SystemReward.sol";
import "../contracts/StakingPool.sol";
import "../contracts/Governance.sol";
import "../contracts/ChainConfig.sol";
import "../contracts/RuntimeUpgrade.sol";
import "../contracts/DeployerProxy.sol";
import "../contracts/Tokenomics.sol";

contract StakingSherlock77 is Test {
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

        address[] memory valAddrArray = new address[](0);
        uint256[] memory initialStakeArray = new uint256[](0);

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

    function testAudit_GetValiators() public {
        address validatorA = makeAddr("validatorA");
        address validatorB = makeAddr("validatorB");
        address validatorC = makeAddr("validatorC");
        address validatorD = makeAddr("validatorD");

        vm.startPrank(vm.addr(20));
        // Set Active validator length to 2
        chainConfig.setActiveValidatorsLength(2);
        // Add validators
        staking.addValidator(validatorA);
        vm.warp(block.timestamp + 1);
        staking.addValidator(validatorB);
        vm.warp(block.timestamp + 1);
        staking.addValidator(validatorC);
        vm.warp(block.timestamp + 1);
        staking.addValidator(validatorD);
        vm.stopPrank();

        address delegator = makeAddr("Delegator");
        deal(delegator, 50 ether);
        vm.startPrank(delegator);
        staking.delegate{value: 10 ether}(validatorA);
        staking.delegate{value: 10 ether}(validatorB);
        staking.delegate{value: 20 ether}(validatorC);
        staking.delegate{value: 10 ether}(validatorD);
        vm.stopPrank();

        // The returned valdiators should be validatorC and validatorA
        address[] memory validatorAddresses = staking.getValidatorsAtEpoch(1);
        assertEq(validatorAddresses.length, 2);
        assertEq(validatorAddresses[0], validatorC);
        assertEq(validatorAddresses[1], validatorA);

        // undelegate everything from validatorA
        vm.prank(delegator);
        staking.undelegate(validatorA, 10 ether);

        // delete validatorA
        vm.prank(vm.addr(20));
        staking.removeValidator(validatorA);

        // The returned valdiators should be validatorC and validatorB
        validatorAddresses = staking.getValidatorsAtEpoch(1);
        assertEq(validatorAddresses.length, 2);
        assertEq(validatorAddresses[0], validatorC);
        assertEq(validatorAddresses[1], validatorB);
    }
}
