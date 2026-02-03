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
import {DeployerProxy} from "../contracts/DeployerProxy.sol";

contract DeployerProxyTest is Test {
    event ContractDeployed(address indexed account, address impl);
    event ContractDeleted(address indexed contractAddress);

    using stdStorage for StdStorage;

    DeployerProxy deployerProxy;
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

        address[] memory valAddrArray = new address[](0);
        uint256[] memory initialStakeArray = new uint256[](0);

        bytes memory ctorDeployerProxy = abi.encodeWithSignature("ctor(address[])", valAddrArray);
        deployerProxy = new DeployerProxy(ctorDeployerProxy);

        IStaking stakingContract = IStaking(vm.addr(20));
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(vm.addr(20));
        IGovernance governanceContract = IGovernance(vm.addr(20));
        IChainConfig chainConfigContract = IChainConfig(chainConfig);
        IRuntimeUpgrade runtimeUpgradeContract = IRuntimeUpgrade(vm.addr(20));
        IDeployerProxy deployerProxyContract = IDeployerProxy(deployerProxy);
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

        deployerProxy.initManually(
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

        vm.prank(vm.addr(20));
        deployerProxy.toggleDeployerWhitelist(false);
    }

    function test_removeContracts() public {
        // register some addresses
        address[] memory contractAddrs = new address[](2);
        contractAddrs[0] = 0x000000000000b361194cfe6312EE3210d53C15AA;
        contractAddrs[1] = 0x00000000000001E4A82b33373DE1334E7d8F4879;
        address deployer = 0x6D9FB3C412a269Df566a5c92b85a8dc334F0A797;
        for (uint256 i = 0; i < contractAddrs.length; i++) {
            vm.prank(block.coinbase);
            vm.expectEmit(true, true, true, true);
            emit ContractDeployed(deployer, contractAddrs[i]);
            deployerProxy.registerDeployedContract(deployer, contractAddrs[i]);
        }

        // delete them
        vm.prank(vm.addr(20));
        vm.expectEmit(true, true, true, true);
        emit ContractDeleted(contractAddrs[0]);
        emit ContractDeleted(contractAddrs[1]);
        deployerProxy.removeContracts(contractAddrs);

        // make sure the state is "reset"
        for (uint256 i = 0; i < contractAddrs.length; i++) {
            (uint8 state, address impl, address deployer) = deployerProxy.getContractState(contractAddrs[i]);
            assertEq(state, 0);
            assertEq(impl, address(0));
            assertEq(deployer, address(0));
        }

        // Adding the contracts again should be successful
        for (uint256 i = 0; i < contractAddrs.length; i++) {
            vm.prank(block.coinbase);
            vm.expectEmit(true, true, true, true);
            emit ContractDeployed(deployer, contractAddrs[i]);
            deployerProxy.registerDeployedContract(deployer, contractAddrs[i]);
        }
    }
}
