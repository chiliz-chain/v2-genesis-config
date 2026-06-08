// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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
import {ChainConfig} from "../contracts/ChainConfig.sol";
import {JsTruffleFixture} from "./JsTruffleFixture.sol";
import {FakeRuntimeUpgradeEvmHook} from "../contracts/tests/FakeRuntimeUpgradeEvmHook.sol";

/// @dev Uses Forge `vm.etch` so `upgradeSystemSmartContract` can swap bytecode in `RuntimeUpgradeTest`.
contract VmEtchRuntimeUpgradeHook is IRuntimeUpgradeEvmHook {
    Vm internal vm;
    event Upgraded(address contractAddress, bytes byteCode);
    constructor(Vm _vm) {
        vm = _vm;
    }
    function upgradeTo(address contractAddress, bytes calldata byteCode) external override {
        vm.etch(contractAddress, byteCode);
        emit Upgraded(contractAddress, byteCode);
    }
}

contract DummyContract {
    uint8 public dummyValue = 5;
    function isInitialized() public pure returns (bool) {
        return true;
    }
}

contract DummyContract1 is DummyContract{
    event DummyEvent();
    function dummyFunction() public {
        dummyValue += 3;
        emit DummyEvent();
    }
}

contract RuntimeUpgradeTest is Test {
    RuntimeUpgrade public runtimeUpgrade;
    ChainConfig public chainConfig;
    DummyContract dummyContract;

    uint16 public constant EPOCH_LEN = 100;

    event DummyEvent();

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
            0  // minStakingAmount
        );
        chainConfig = new ChainConfig(ctorChainConfig);

        VmEtchRuntimeUpgradeHook fakeRuntimeUpgradeEvmHook = new VmEtchRuntimeUpgradeHook(vm);

        bytes memory ctorRuntimeUpgrade = abi.encodeWithSignature("ctor(address)", address(fakeRuntimeUpgradeEvmHook));
        runtimeUpgrade = new RuntimeUpgrade(ctorRuntimeUpgrade);

        dummyContract = new DummyContract();

        IStaking stakingContract = IStaking(address(dummyContract));
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(vm.addr(20));
        IGovernance governanceContract = IGovernance(vm.addr(20));
        IChainConfig chainConfigContract = IChainConfig(chainConfig);
        IRuntimeUpgrade runtimeUpgradeContract = IRuntimeUpgrade(runtimeUpgrade);
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
    }

    /// @notice we're using DummyContract as StakingContract
    function test_upgradeSystemSmartContract_ApplyFunctionGetsCalledAfterUpgrade() public {
        assertEq(dummyContract.dummyValue(), 5);

        // upgrade DummyContract to DummyContract1 and make sure the 'applyFunction' gets called
        // by checking the emitted event from the function & the state variable
        vm.expectEmit(true, true, true, true);
        emit DummyEvent();
        vm.prank(vm.addr(20));
        runtimeUpgrade.upgradeSystemSmartContract(address(dummyContract), vm.getDeployedCode("DummyContract1"), abi.encodeWithSignature("dummyFunction()"));
        assertEq(dummyContract.dummyValue(), 8);
    }
}

/// @notice Port of `genesis/test/runtime-upgrade.js` — full mock chain + `FakeRuntimeUpgrade` upgrades staking slot (`getSystemContracts()[0]`).
contract RuntimeUpgradeJsTest is JsTruffleFixture {
    event Upgraded(address contractAddress, bytes byteCode);
    event SmartContractUpgrade(address contractAddress, bytes newByteCode);

    FakeRuntimeUpgradeEvmHook internal evmHook;
    MockChain internal chain;

    function setUp() public {
        evmHook = new FakeRuntimeUpgradeEvmHook();

        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;
        address[] memory noDeployers = new address[](0);

        chain = deployMockChain(noValidators, noStakes, rewardToBurn, fullShare, noDeployers, address(evmHook), 10, 2);
    }

    /// @notice EVM hook emits `Upgraded`, then `RuntimeUpgrade` emits `SmartContractUpgrade` with the same target and bytecode.
    function test_migration_upgradeEmitsAndSetsBytecode() public {
        assertEq(chain.runtimeUpgrade.getEvmHookAddress(), address(evmHook));

        address stakingContract = chain.runtimeUpgrade.getSystemContracts()[0];
        bytes memory placeholderBytecode = hex"badcab1e";

        vm.expectEmit(true, true, true, true);
        emit Upgraded(stakingContract, placeholderBytecode);
        vm.expectEmit(true, true, true, true);
        emit SmartContractUpgrade(stakingContract, placeholderBytecode);
        chain.runtimeUpgrade.upgradeSystemSmartContract(stakingContract, placeholderBytecode, "");
    }
}
