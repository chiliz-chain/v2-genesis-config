// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {ChainConfig} from "../contracts/ChainConfig.sol";
import {SlashingIndicator} from "../contracts/SlashingIndicator.sol";
import {StakingPool} from "../contracts/StakingPool.sol";
import {FakeStaking} from "../contracts/tests/FakeStaking.sol";
import {FakeSystemReward} from "../contracts/tests/FakeSystemReward.sol";
import {FakeGovernance} from "../contracts/tests/FakeGovernance.sol";
import {FakeRuntimeUpgrade} from "../contracts/tests/FakeRuntimeUpgrade.sol";
import {FakeDeployerProxy} from "../contracts/tests/FakeDeployerProxy.sol";
import {FakeTokenomics} from "../contracts/tests/FakeTokenomics.sol";

/**
 * @title JsTruffleFixture
 * @notice Shared deployment matching `genesis/test/helper.js` `newMockContract`: the same Fake* system
 *         contracts and `initManually` wiring used by the legacy Truffle JS tests.
 */
abstract contract JsTruffleFixture is Test {
    /// @dev Live references to every system contract after `deployMockChain` (or helpers below).
    struct MockChain {
        FakeStaking staking;
        SlashingIndicator slashingIndicator;
        FakeSystemReward systemReward;
        StakingPool stakingPool;
        FakeGovernance governance;
        ChainConfig chainConfig;
        FakeRuntimeUpgrade runtimeUpgrade;
        FakeDeployerProxy deployerProxy;
        FakeTokenomics tokenomics;
    }

    /**
     * @notice Default mock: no genesis validators, system reward 100% to `address(0)`, no genesis deployers,
     *         runtime hook `vm.addr(1)`, epoch length 10 blocks, governance voting period 2 blocks.
     */
    function deployDefaultMockChain() internal returns (MockChain memory chain) {
        return deployDefaultMockChain(10, 2);
    }

    /// @param epochBlockInterval blocks per epoch (`ChainConfig` / staking epoch math).
    /// @param governanceVotingPeriod passed to `Governance.ctor` as voting period length in blocks.
    function deployDefaultMockChain(uint32 epochBlockInterval, uint256 governanceVotingPeriod)
        internal
        returns (MockChain memory chain)
    {
        address[] memory genesisValidators = new address[](0);
        uint256[] memory genesisStakes = new uint256[](0);
        address[] memory systemRewardAccounts = new address[](1);
        systemRewardAccounts[0] = address(0);
        uint16[] memory systemRewardShares = new uint16[](1);
        systemRewardShares[0] = 10000;
        address[] memory genesisDeployers = new address[](0);
        return deployMockChain(
            genesisValidators,
            genesisStakes,
            systemRewardAccounts,
            systemRewardShares,
            genesisDeployers,
            vm.addr(1),
            epochBlockInterval,
            governanceVotingPeriod
        );
    }

    /**
     * @notice Full mock deployment with explicit constructor args (see `helper.js` defaults: activeValidatorsLength 3,
     *         misdemeanor 50, felony 150, jail epochs 7, min stake 1 ether).
     */
    function deployMockChain(
        address[] memory genesisValidators,
        uint256[] memory genesisStakes,
        address[] memory systemRewardAccounts,
        uint16[] memory systemRewardShares,
        address[] memory genesisDeployers,
        address runtimeUpgradeHook,
        uint32 epochBlockInterval,
        uint256 governanceVotingPeriod
    ) internal returns (MockChain memory chain) {
        bytes memory chainConfigCtor = abi.encodeWithSignature(
            "ctor(uint32,uint32,uint32,uint32,uint32,uint32,uint256,uint256)",
            uint32(3), // activeValidatorsLength (top-N main validators)
            epochBlockInterval,
            uint32(50), // misdemeanorThreshold
            uint32(150), // felonyThreshold
            uint32(7), // validatorJailEpochLength
            uint32(0), // undelegatePeriod
            uint256(1 ether), // minValidatorStakeAmount
            uint256(1 ether) // minStakingAmount
        );
        chain.chainConfig = new ChainConfig(chainConfigCtor);

        bytes memory stakingCtor =
            abi.encodeWithSignature("ctor(address[],uint256[],uint16)", genesisValidators, genesisStakes, uint16(0));
        chain.staking = new FakeStaking(stakingCtor);

        chain.slashingIndicator = new SlashingIndicator(abi.encodeWithSignature("ctor()"));

        bytes memory systemRewardCtor =
            abi.encodeWithSignature("ctor(address[],uint16[])", systemRewardAccounts, systemRewardShares);
        chain.systemReward = new FakeSystemReward(systemRewardCtor);

        chain.stakingPool = new StakingPool(abi.encodeWithSignature("ctor()"));

        bytes memory governanceCtor = abi.encodeWithSignature("ctor(uint256)", governanceVotingPeriod);
        chain.governance = new FakeGovernance(governanceCtor);

        bytes memory runtimeCtor = abi.encodeWithSignature("ctor(address)", runtimeUpgradeHook);
        chain.runtimeUpgrade = new FakeRuntimeUpgrade(runtimeCtor);

        bytes memory deployerCtor = abi.encodeWithSignature("ctor(address[])", genesisDeployers);
        chain.deployerProxy = new FakeDeployerProxy(deployerCtor);

        bytes memory tokenomicsCtor = abi.encodeWithSignature("ctor(uint16,uint16)", uint16(6500), uint16(3500));
        chain.tokenomics = new FakeTokenomics(tokenomicsCtor);

        _initAllInjectors(chain);
    }

    /// @dev Calls `initManually` on each contract with the same nine-address tuple (stack-safe single encoding).
    function _initAllInjectors(MockChain memory chain) private {
        bytes memory data = abi.encodeWithSignature(
            "initManually(address,address,address,address,address,address,address,address,address)",
            address(chain.staking),
            address(chain.slashingIndicator),
            address(chain.systemReward),
            address(chain.stakingPool),
            address(chain.governance),
            address(chain.chainConfig),
            address(chain.runtimeUpgrade),
            address(chain.deployerProxy),
            address(chain.tokenomics)
        );
        require(_initCall(address(chain.slashingIndicator), data));
        require(_initCall(address(chain.staking), data));
        require(_initCall(address(chain.systemReward), data));
        require(_initCall(address(chain.stakingPool), data));
        require(_initCall(address(chain.governance), data));
        require(_initCall(address(chain.chainConfig), data));
        require(_initCall(address(chain.runtimeUpgrade), data));
        require(_initCall(address(chain.deployerProxy), data));
        require(_initCall(address(chain.tokenomics), data));
    }

    function _initCall(address to, bytes memory data) private returns (bool ok) {
        (ok,) = to.call(data);
    }

    /**
     * @notice Advances `block.number` in steps of `epochBlockInterval` until `staking.currentEpoch()` increases.
     * @dev Mirrors JS `waitForNextEpoch(parlia)`; required because many staking views are epoch-keyed.
     */
    function rollToNextEpoch(MockChain memory chain, uint32 epochBlockInterval) internal {
        uint64 epochBefore = chain.staking.currentEpoch();
        for (uint256 i = 0; i < 500 && chain.staking.currentEpoch() == epochBefore; i++) {
            vm.roll(block.number + uint256(epochBlockInterval));
        }
        require(chain.staking.currentEpoch() != epochBefore, "epoch stuck");
    }
}
