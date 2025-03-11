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

import {RuntimeUpgrade} from "../contracts/RuntimeUpgrade.sol";
import {InjectorContextHolderV2} from "../contracts/InjectorV2.sol";

// Mock contract to simulate the EVM hook
contract MockRuntimeUpgradeEvmHook is IRuntimeUpgradeEvmHook, Test {
    mapping(address => bytes) public contractCode;

    function upgradeTo(address contractAddress, bytes calldata byteCode) external override {
        contractCode[contractAddress] = byteCode;

        vm.etch(contractAddress, byteCode);
    }

    function getCode(address contractAddress) external view returns (bytes memory) {
        return contractCode[contractAddress];
    }
}

// Test system contract that implements IInjectorV2 directly
contract TestSystemContract is InjectorContextHolderV2 {
    uint256 public initializedValue;
    bool public ctorCalled;

    constructor() {
        console.log("TestSystemContract constructor called !!!");
    }

    function ctor(uint256 value) external {
        console.log("ctor called");
        // This is the function that should be called by _invokeContractConstructor
        initializedValue = value;
        ctorCalled = true;
    }
}

contract RuntimeUpgradeSherlock32 is Test {
    RuntimeUpgrade public runtimeUpgrade;
    MockRuntimeUpgradeEvmHook public evmHook;
    address public dummyContractAddress;
    address public governanceAddress;

    function setUp() public {
        // Deploy the mock EVM hook
        evmHook = new MockRuntimeUpgradeEvmHook();

        // Set up governance address
        governanceAddress = vm.addr(5);

        // Deploy RuntimeUpgrade with the mock EVM hook
        bytes memory ctorRuntimeUpgrade = abi.encodeWithSignature("ctor(address)", address(evmHook));

        runtimeUpgrade = new RuntimeUpgrade(ctorRuntimeUpgrade);

        // Initialize the RuntimeUpgrade contract
        IStaking stakingContract = IStaking(vm.addr(1));
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(2));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(3));
        IStakingPool stakingPoolContract = IStakingPool(vm.addr(4));
        IGovernance governanceContract = IGovernance(governanceAddress);
        IChainConfig chainConfigContract = IChainConfig(vm.addr(6));
        IRuntimeUpgrade runtimeUpgradeContract = IRuntimeUpgrade(address(runtimeUpgrade));
        IDeployerProxy deployerProxyContract = IDeployerProxy(vm.addr(8));
        ITokenomics tokenomicsContract = ITokenomics(vm.addr(9));

        runtimeUpgrade.initManually(
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

        // Set up a test contract address
        dummyContractAddress = address(0x1234567890123456789012345678901234567890);
    }

    function test_RuntimeDeploymentShouldCallCtorAsApplyFunction() public {
        assertEq(address(dummyContractAddress).code.length, 0, "dummyContract Address  should not have code yet");

        // Create constructor parameters for our test contract
        uint256 initValue = 42;
        bytes memory constructorParams = abi.encodeWithSignature("ctor(uint256)", initValue);

        // call runtimeUpgrade.deploySystemSmartContract
        vm.prank(governanceAddress);
        bytes memory runtimeCode = vm.getDeployedCode("TestSystemContract");
        runtimeUpgrade.deploySystemSmartContract(dummyContractAddress, runtimeCode, constructorParams);

        assertGt(address(dummyContractAddress).code.length, 0, "Deployed contract should have code now");

        // Now check if the contract was properly initialized
        TestSystemContract deployedContract = TestSystemContract(dummyContractAddress);

        // This should be false because ctor() was never called with the initialization value
        assertEq(deployedContract.ctorCalled(), true, "ctor() should have been called");
        assertEq(deployedContract.initializedValue(), initValue);
    }
}
