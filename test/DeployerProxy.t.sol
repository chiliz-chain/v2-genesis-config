// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

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
import {JsTruffleFixture} from "./JsTruffleFixture.sol";
import {TestDeployerFactory} from "../contracts/tests/TestDeployerFactory.sol";

/// @notice `DeployerProxyTest`: real `DeployerProxy` + whitelist off. `DeployerProxyJsTest`: Fake deployer + Truffle JS parity (`deployer.js`).
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
            (uint8 state, address impl, address recordedDeployer) = deployerProxy.getContractState(contractAddrs[i]);
            assertEq(state, 0);
            assertEq(impl, address(0));
            assertEq(recordedDeployer, address(0));
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

/// @notice Port of `genesis/test/deployer.js` — whitelist, registry, ban/unban, enable/disable (uses `FakeDeployerProxy` via `JsTruffleFixture`).
contract DeployerProxyJsTest is JsTruffleFixture {
    event DeployerAdded(address indexed account);
    event DeployerRemoved(address indexed account);
    event ContractDeployed(address indexed account, address impl);
    event ContractDisabled(address indexed contractAddress);
    event ContractEnabled(address indexed contractAddress);
    event DeployerWhitelistEnabled(bool indexed state);

    address internal testOwner = vm.addr(100);

    MockChain internal chain;

    function setUp() public {
        chain = deployDefaultMockChain();
    }

    /// @notice Whitelist: add then remove a deployer; events and `isDeployer` must match.
    function test_addRemoveDeployer() public {
        address deployerAccount = address(1);

        assertFalse(chain.deployerProxy.isDeployer(deployerAccount));
        vm.expectEmit(true, true, true, true);
        emit DeployerAdded(deployerAccount);
        chain.deployerProxy.addDeployer(deployerAccount);
        assertTrue(chain.deployerProxy.isDeployer(deployerAccount));

        vm.expectEmit(true, true, true, true);
        emit DeployerRemoved(deployerAccount);
        chain.deployerProxy.removeDeployer(deployerAccount);
        assertFalse(chain.deployerProxy.isDeployer(deployerAccount));
    }

    /// @notice A genesis-whitelisted account can register a contract, then governance (Fake) can disable/re-enable it.
    function test_disableEnableContract() public {
        address whitelistedDeployer = address(1);
        address[] memory genesisDeployers = new address[](1);
        genesisDeployers[0] = whitelistedDeployer;

        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;

        MockChain memory customChain = deployMockChain(
            noValidators, noStakes, rewardToBurn, fullShare, genesisDeployers, vm.addr(1), 10, 2
        );

        address registeredImpl = address(0x222);
        customChain.deployerProxy.registerDeployedContract(whitelistedDeployer, registeredImpl);

        (uint8 state,,) = customChain.deployerProxy.getContractState(registeredImpl);
        assertEq(state, uint8(DeployerProxy.ContractState.Enabled));

        vm.expectEmit(true, true, true, true);
        emit ContractDisabled(registeredImpl);
        customChain.deployerProxy.disableContract(registeredImpl);
        (state,,) = customChain.deployerProxy.getContractState(registeredImpl);
        assertEq(state, uint8(DeployerProxy.ContractState.Disabled));

        vm.expectEmit(true, true, true, true);
        emit ContractEnabled(registeredImpl);
        customChain.deployerProxy.enableContract(registeredImpl);
        (state,,) = customChain.deployerProxy.getContractState(registeredImpl);
        assertEq(state, uint8(DeployerProxy.ContractState.Enabled));
    }

    /// @notice Registration fails until account is on whitelist; then state stores impl and deployer.
    function test_registerRequiresWhitelistUnlessDeployer() public {
        address newContract = address(0x123);

        vm.expectRevert(bytes("Deployer: deployer is not allowed"));
        chain.deployerProxy.registerDeployedContract(testOwner, newContract);

        chain.deployerProxy.addDeployer(testOwner);
        vm.expectEmit(true, true, true, true);
        emit ContractDeployed(testOwner, newContract);
        chain.deployerProxy.registerDeployedContract(testOwner, newContract);

        (uint8 state, address storedImpl, address recordedDeployer) = chain.deployerProxy.getContractState(newContract);
        assertEq(state, uint8(DeployerProxy.ContractState.Enabled));
        assertEq(storedImpl, newContract);
        assertEq(recordedDeployer, testOwner);
    }

    /// @notice With whitelist off, any account may register without being pre-added.
    function test_registerWhenWhitelistDisabled() public {
        assertTrue(chain.deployerProxy.isDeployerWhitelistEnabled());
        assertFalse(chain.deployerProxy.isDeployer(testOwner));

        chain.deployerProxy.toggleDeployerWhitelist(false);
        assertFalse(chain.deployerProxy.isDeployerWhitelistEnabled());

        address newContract = address(0x123);
        chain.deployerProxy.registerDeployedContract(testOwner, newContract);
        (uint8 state,,) = chain.deployerProxy.getContractState(newContract);
        assertEq(state, uint8(DeployerProxy.ContractState.Enabled));
    }

    /// @notice Constructor `address[]` seeds initial whitelist entries.
    function test_genesisDeployersInConstructor() public {
        address[] memory genesisDeployers = new address[](3);
        genesisDeployers[0] = address(1);
        genesisDeployers[1] = address(2);
        genesisDeployers[2] = address(3);

        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardToBurn = new address[](1);
        rewardToBurn[0] = address(0);
        uint16[] memory fullShare = new uint16[](1);
        fullShare[0] = 10000;

        MockChain memory genesisChain =
            deployMockChain(noValidators, noStakes, rewardToBurn, fullShare, genesisDeployers, vm.addr(1), 10, 2);

        assertFalse(genesisChain.deployerProxy.isDeployer(address(0)));
        assertTrue(genesisChain.deployerProxy.isDeployer(address(1)));
        assertTrue(genesisChain.deployerProxy.isDeployer(address(2)));
        assertTrue(genesisChain.deployerProxy.isDeployer(address(3)));
        assertFalse(genesisChain.deployerProxy.isDeployer(address(4)));
    }

    /// @notice Ban marks deployer unusable for registration; unban clears the flag (runs with whitelist on and off).
    function test_banUnbanDeployer() public {
        _runBanUnbanScenario(false);
        _runBanUnbanScenario(true);
    }

    function _runBanUnbanScenario(bool startWithWhitelistDisabled) internal {
        MockChain memory scenarioChain = deployDefaultMockChain();
        if (startWithWhitelistDisabled) {
            scenarioChain.deployerProxy.toggleDeployerWhitelist(false);
        }

        address deployerAccount = address(1);
        scenarioChain.deployerProxy.addDeployer(deployerAccount);
        assertTrue(scenarioChain.deployerProxy.isDeployer(deployerAccount));
        assertFalse(scenarioChain.deployerProxy.isBanned(deployerAccount));

        scenarioChain.deployerProxy.banDeployer(deployerAccount);
        assertTrue(scenarioChain.deployerProxy.isDeployer(deployerAccount));
        assertTrue(scenarioChain.deployerProxy.isBanned(deployerAccount));

        scenarioChain.deployerProxy.unbanDeployer(deployerAccount);
        assertTrue(scenarioChain.deployerProxy.isDeployer(deployerAccount));
        assertFalse(scenarioChain.deployerProxy.isBanned(deployerAccount));
    }

    /// @notice Registering a factory contract also whitelists the factory address as a deployer (JS `TestDeployerFactory`).
    function test_factoryRegisteredAsDeployer() public {
        chain.deployerProxy.addDeployer(testOwner);

        TestDeployerFactory factory = new TestDeployerFactory();
        chain.deployerProxy.registerDeployedContract(testOwner, address(factory));

        assertTrue(chain.deployerProxy.isDeployer(testOwner));
        assertTrue(chain.deployerProxy.isDeployer(address(factory)));

        chain.deployerProxy.toggleDeployerWhitelist(false);
        assertTrue(chain.deployerProxy.isDeployer(testOwner));
        assertTrue(chain.deployerProxy.isDeployer(address(factory)));
    }

    /// @notice Toggling whitelist: when off, `isDeployer` is vacuously true; when on, only listed accounts qualify.
    function test_toggleDeployerWhitelist() public {
        address arbitraryAccount = address(1);

        assertTrue(chain.deployerProxy.isDeployerWhitelistEnabled());
        assertFalse(chain.deployerProxy.isDeployer(arbitraryAccount));

        vm.expectEmit(true, true, true, true);
        emit DeployerWhitelistEnabled(false);
        chain.deployerProxy.toggleDeployerWhitelist(false);
        assertFalse(chain.deployerProxy.isDeployerWhitelistEnabled());
        assertTrue(chain.deployerProxy.isDeployer(arbitraryAccount));

        vm.expectEmit(true, true, true, true);
        emit DeployerWhitelistEnabled(true);
        chain.deployerProxy.toggleDeployerWhitelist(true);
        assertTrue(chain.deployerProxy.isDeployerWhitelistEnabled());
        assertFalse(chain.deployerProxy.isDeployer(arbitraryAccount));
    }
}
