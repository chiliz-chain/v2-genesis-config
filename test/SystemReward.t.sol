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
import {SystemReward} from "../contracts/SystemReward.sol";
import {ChainConfig} from "../contracts/ChainConfig.sol";

contract NotPayable {
    receive() external payable {
         revert();
    }
}

contract SystemRewardTest is Test {
    SystemReward public systemReward;
    ChainConfig public chainConfig;

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

        address[] memory accounts = new address[](2);
        accounts[0] = vm.addr(1);
        accounts[1] = vm.addr(2);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;

        bytes memory ctorSystemReward = abi.encodeWithSignature("ctor(address[],uint16[])", accounts, shares);
        systemReward = new SystemReward(ctorSystemReward);

        IStaking stakingContract = IStaking(vm.addr(20));
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(systemReward);
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

        systemReward.initManually(
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

    // @notice updateDistributionShare() should revert if a new account is not able to receive CHZ
    function test_updateDistributionShare_RevertWhen_AccountNotPayable() public {
        NotPayable npa = new NotPayable();
        address[] memory accounts = new address[](2);
        accounts[0] = vm.addr(3);
        accounts[1] = address(npa);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;

        vm.prank(vm.addr(20)); // governance
        vm.expectRevert(bytes("SystemReward: account cannot receive CHZ"));
        systemReward.updateDistributionShare(accounts, shares);
    }
}
