// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";

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
import {JsTruffleFixture} from "./JsTruffleFixture.sol";

/// @notice `StakingPoolTest`: real staking + pool. `StakingPoolJsTest`: Fake staking + pool (`staking-pool.js` parity).
contract StakingPoolTest is Test {
    StakingPool public stakingPool;
    Staking public staking;
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

        address[] memory valAddrArray = new address[](1);
        valAddrArray[0] = vm.addr(5);
        uint256[] memory initialStakeArray = new uint256[](1);

        bytes memory ctoStaking = abi.encodeWithSignature("ctor(address[],uint256[],uint16)", valAddrArray, initialStakeArray, 0);
        staking = new Staking(ctoStaking);

        bytes memory ctorStakingPool = abi.encodeWithSignature("ctor()");
        stakingPool = new StakingPool(ctorStakingPool);

        IStaking stakingContract = IStaking(staking);
        ISlashingIndicator slashingIndicatorContract = ISlashingIndicator(vm.addr(20));
        ISystemReward systemRewardContract = ISystemReward(vm.addr(20));
        IStakingPool stakingPoolContract = IStakingPool(stakingPool);
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

        stakingPool.initManually(
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

    function test_StakeUnstakeClaimFlowWithMultipleStakers() public {
        address staker1 = vm.addr(1);
        address staker2 = vm.addr(2);
        address validator = vm.addr(5);
        uint256 initialBalance = 100_000 ether;
        vm.coinbase(vm.addr(256));
        vm.deal(staker1, initialBalance);
        vm.deal(staker2, initialBalance);
        vm.deal(block.coinbase, initialBalance);

        uint256 stakedAmount = 100 ether;

        // stake
        vm.prank(staker1);
        stakingPool.stake{value: stakedAmount}(validator);
        vm.prank(staker2);
        stakingPool.stake{value: stakedAmount}(validator);

        // verify that the state was updated
        assertEq(stakingPool.getStakedAmount(validator, staker1), stakedAmount);
        assertEq(stakingPool.getShares(validator, staker1), stakedAmount);
        assertEq(stakingPool.getStakedAmount(validator, staker2), stakedAmount);
        assertEq(stakingPool.getShares(validator, staker2), stakedAmount);
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, stakedAmount * 2);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, stakedAmount * 2);

        vm.roll(block.number + EPOCH_LEN);

        // simulate reward accumulation on the validator
        vm.prank(block.coinbase);
        staking.deposit{value: 20 ether}(validator);
        vm.roll(block.number + EPOCH_LEN);

        // make sure that the stakers received rewards
        uint256 staker1Stake = stakingPool.getStakedAmount(validator, staker1);
        uint256 staker2Stake = stakingPool.getStakedAmount(validator, staker2);
        assertGt(staker1Stake, stakedAmount);
        assertGt(staker2Stake, stakedAmount);

        // unstake from staker1
        uint256 unstakeAmount = staker1Stake - (staker1Stake % 1e10); // remove remainder
        uint256 stakerSharesBeforeUnstake = stakingPool.getShares(validator, staker1);
        StakingPool.ValidatorPool memory validatorPoolBeforeUnstake = stakingPool.getValidatorPool(validator);
        vm.prank(staker1);
        stakingPool.unstake(validator, unstakeAmount);

        // verify that the state was updated (staked amount & shares were decremented)
        assertEq(stakingPool.getStakedAmount(validator, staker1), staker1Stake % 1e10);
        assertLt(stakingPool.getShares(validator, staker1), stakerSharesBeforeUnstake);
        assertLt(stakingPool.getValidatorPool(validator).totalStakedAmount, validatorPoolBeforeUnstake.totalStakedAmount);
        assertLt(stakingPool.getValidatorPool(validator).sharesSupply, validatorPoolBeforeUnstake.sharesSupply);

        // verify that staker2 was not affected
        assertEq(stakingPool.getStakedAmount(validator, staker2), staker2Stake);

        // unstake from staker2
        vm.prank(staker2);
        stakingPool.unstake(validator, unstakeAmount);

        StakingPool.ValidatorPool memory validatorPoolBeforeClaim = stakingPool.getValidatorPool(validator);

        // claim
        vm.roll(block.number + EPOCH_LEN * 2); // cooldown period
        vm.prank(staker1);
        stakingPool.claim(validator);
        vm.prank(staker2);
        stakingPool.claim(validator);

        // verify that the staked amount & shares didn't change
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, validatorPoolBeforeClaim.totalStakedAmount);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, validatorPoolBeforeClaim.sharesSupply);

        // verify the balances
        assertEq(staker1.balance, initialBalance - stakedAmount + unstakeAmount);
        assertEq(staker2.balance, initialBalance - stakedAmount + unstakeAmount);
    }

    /// @notice verify that claim() function decrements staked amounts & shares
    ///         for accounts that unstaked before the upgrade
    function test_StakeUnstakeClaimFlowBeforeChange() public {
        address staker = vm.addr(1);
        address validator = vm.addr(5);
        uint256 stakeAmount = 100 ether;

        // stake
        vm.deal(staker, 1000 ether);
        vm.prank(staker);
        stakingPool.stake{value: stakeAmount}(validator);

        StakingPool.ValidatorPool memory validatorPoolBeforeUnstake = stakingPool.getValidatorPool(validator);
        uint256 stakerSharesBeforeUnstake = stakingPool.getShares(validator, staker);

        // unstake
        vm.prank(staker);
        stakingPool.unstake(validator, stakeAmount);

        // reset totalStake, shareSupply, _unstakedPostSherlockSupplyFixUpdate, staker shares
        bytes32 validatorPoolsSlot = keccak256(abi.encode(validator, 102));
        bytes32 stakerSharesSlot = keccak256(abi.encode(validator, 104));
        bytes32 postAuditFixMappingSlot1 = keccak256(abi.encode(staker, 105)); // _unstakedPostSherlockSupplyFixUpdate
        bytes32 postAuditFixMappingSlot2 = keccak256(abi.encode(validator, 106)); // _decrementedSharesAtUnstake

        vm.store(address(stakingPool), bytes32(uint256(validatorPoolsSlot) + 1), bytes32(validatorPoolBeforeUnstake.sharesSupply));
        vm.store(address(stakingPool), bytes32(uint256(validatorPoolsSlot) + 2), bytes32(validatorPoolBeforeUnstake.totalStakedAmount));
        vm.store(address(stakingPool), keccak256(abi.encode(staker, stakerSharesSlot)), bytes32(stakerSharesBeforeUnstake));
        vm.store(address(stakingPool), postAuditFixMappingSlot1, bytes32(abi.encode(false)));
        vm.store(address(stakingPool), keccak256(abi.encode(staker, postAuditFixMappingSlot2)), bytes32(abi.encode(false)));

        // claim
        vm.roll(block.number + EPOCH_LEN * 2); // cooldown period
        vm.prank(staker);
        stakingPool.claim(validator);

        // verify that the staked amount & shares were decremented in claim()
        assertEq(stakingPool.getStakedAmount(validator, staker), 0);
        assertEq(stakingPool.getShares(validator, staker), 0);
        assertEq(stakingPool.getValidatorPool(validator).totalStakedAmount, 0);
        assertEq(stakingPool.getValidatorPool(validator).sharesSupply, 0);
    }

    /// @notice Regression for the claim() guard bug: a pending unstake created under the FIRST fix
    ///         (shares already decremented at unstake, per-staker flag `_unstakedPostSherlockSupplyFixUpdate`
    ///         set, per-validator flag `decrementedSharesAtUnstake` absent) must NOT be decremented again
    ///         at claim. With the buggy `||` condition this double-subtracts; with the `&&` fix it does not.
    function test_ClaimAfterFirstFixUnstakeDoesNotDoubleSubtract() public {
        address staker = vm.addr(1);
        address coStaker = vm.addr(2);
        address validator = vm.addr(5);
        uint256 stakeAmount = 100 ether;

        vm.deal(staker, 1000 ether);
        vm.deal(coStaker, 1000 ether);

        // both stake so the pool keeps supply after the partial unstake (no underflow => visible corruption)
        vm.prank(staker);
        stakingPool.stake{value: stakeAmount}(validator);
        vm.prank(coStaker);
        stakingPool.stake{value: stakeAmount}(validator);

        // partial unstake; no rewards accrued => ratio is 1e18 => shares == amount
        uint256 unstakeAmount = 50 ether;
        vm.prank(staker);
        stakingPool.unstake(validator, unstakeAmount);

        // simulate that this pending unstake was created under the FIRST-fix code:
        // shares/supply/staked were already decremented at unstake, B=true, A=false.
        bytes32 unstakedPostSlot = keccak256(abi.encode(staker, uint256(105))); // _unstakedPostSherlockSupplyFixUpdate[staker]
        bytes32 decrementedSlot = keccak256(abi.encode(staker, keccak256(abi.encode(validator, uint256(106))))); // decrementedSharesAtUnstake[validator][staker]
        vm.store(address(stakingPool), unstakedPostSlot, bytes32(uint256(1))); // B = true
        vm.store(address(stakingPool), decrementedSlot, bytes32(uint256(0))); // A = false

        // snapshot pool + staker shares right before claim
        StakingPool.ValidatorPool memory poolBeforeClaim = stakingPool.getValidatorPoolWithoutRewards(validator);
        uint256 sharesBeforeClaim = stakingPool.getShares(validator, staker);

        // claim after cooldown; must NOT decrement shares/supply/staked again
        vm.roll(block.number + EPOCH_LEN * 2);
        vm.prank(staker);
        stakingPool.claim(validator);

        assertEq(stakingPool.getValidatorPoolWithoutRewards(validator).sharesSupply, poolBeforeClaim.sharesSupply, "sharesSupply must be unchanged by claim");
        assertEq(stakingPool.getValidatorPoolWithoutRewards(validator).totalStakedAmount, poolBeforeClaim.totalStakedAmount, "totalStakedAmount must be unchanged by claim");
        assertEq(stakingPool.getShares(validator, staker), sharesBeforeClaim, "staker shares must be unchanged by claim");
    }

    /// @notice Regression for the claim() guard bug: a pending unstake created under the SECOND fix
    ///         (per-validator flag A=true) whose staker also carries a leftover per-staker flag B=true
    ///         must NOT be decremented again at claim. The buggy `||` condition double-subtracts because
    ///         `... || _unstakedPostSherlockSupplyFixUpdate` is true; the `&&` fix does not.
    function test_ClaimSecondFixWithLegacyStakerFlagDoesNotDoubleSubtract() public {
        address staker = vm.addr(1);
        address coStaker = vm.addr(2);
        address validator = vm.addr(5);
        uint256 stakeAmount = 100 ether;

        vm.deal(staker, 1000 ether);
        vm.deal(coStaker, 1000 ether);

        vm.prank(staker);
        stakingPool.stake{value: stakeAmount}(validator);
        vm.prank(coStaker);
        stakingPool.stake{value: stakeAmount}(validator);

        // partial unstake under current (second-fix) code => decrementedSharesAtUnstake[validator][staker] = true (A=true)
        uint256 unstakeAmount = 50 ether;
        vm.prank(staker);
        stakingPool.unstake(validator, unstakeAmount);

        // simulate a leftover deprecated per-staker flag from a previous first-fix unstake: B=true (A stays true)
        bytes32 unstakedPostSlot = keccak256(abi.encode(staker, uint256(105))); // _unstakedPostSherlockSupplyFixUpdate[staker]
        vm.store(address(stakingPool), unstakedPostSlot, bytes32(uint256(1))); // B = true

        StakingPool.ValidatorPool memory poolBeforeClaim = stakingPool.getValidatorPoolWithoutRewards(validator);
        uint256 sharesBeforeClaim = stakingPool.getShares(validator, staker);

        vm.roll(block.number + EPOCH_LEN * 2);
        vm.prank(staker);
        stakingPool.claim(validator);

        assertEq(stakingPool.getValidatorPoolWithoutRewards(validator).sharesSupply, poolBeforeClaim.sharesSupply, "sharesSupply must be unchanged by claim");
        assertEq(stakingPool.getValidatorPoolWithoutRewards(validator).totalStakedAmount, poolBeforeClaim.totalStakedAmount, "totalStakedAmount must be unchanged by claim");
        assertEq(stakingPool.getShares(validator, staker), sharesBeforeClaim, "staker shares must be unchanged by claim");
    }

    function test_readUnstakedPostSherlockSupplyFixUpdateSlot() public {
        bytes32 postAuditFixMappingSlot1 = keccak256(abi.encode(address(0), 105)); // _unstakedPostSherlockSupplyFixUpdate[address(0)]
        bytes32 postAuditFixMappingSlot2 = keccak256(abi.encode(address(0), keccak256(abi.encode(address(0), 106)))); // _decrementedSharesAtUnstake[address(0)][address(0)]

        assertEq(vm.load(address(stakingPool), postAuditFixMappingSlot1), bytes32(abi.encode(false)));
        assertEq(vm.load(address(stakingPool), postAuditFixMappingSlot2), bytes32(abi.encode(false)));

        vm.prank(vm.addr(20));
        stakingPool.setUnstakedPostSherlockSupplyFixUpdate();

        assertEq(vm.load(address(stakingPool), postAuditFixMappingSlot1), bytes32(abi.encode(true)));
        assertEq(vm.load(address(stakingPool), postAuditFixMappingSlot2), bytes32(abi.encode(true)));
    }

    /// @notice Pins the StakingPool storage layout. Slots 102-106 are live on Spicy and mainnet; slot 107
    ///         held the COR-111 guard and STILL HOLDS 1 on Spicy, because SetCode upgrades never wipe
    ///         storage. If this fails because a variable was appended, that variable must start at 108.
    function test_storageLayoutIsPinned() public {
        address v = vm.addr(5);
        address s = vm.addr(1);
        vm.deal(s, 1000 ether);
        vm.prank(s);
        stakingPool.stake{value: 100 ether}(v);

        // 102 _validatorPools: {validatorAddress@0, sharesSupply@1, totalStakedAmount@2, ...}
        bytes32 poolBase = keccak256(abi.encode(v, uint256(102)));
        assertEq(uint256(vm.load(address(stakingPool), bytes32(uint256(poolBase) + 1))), 100 ether, "102 sharesSupply");
        assertEq(uint256(vm.load(address(stakingPool), bytes32(uint256(poolBase) + 2))), 100 ether, "102 totalStaked");

        // 104 _stakerShares[v][s]
        assertEq(
            uint256(vm.load(address(stakingPool), keccak256(abi.encode(s, keccak256(abi.encode(v, uint256(104))))))),
            100 ether, "104 _stakerShares"
        );

        // 106 decrementedSharesAtUnstake[v][s] -- public getter must agree with the raw slot
        vm.prank(s);
        stakingPool.unstake(v, 100 ether);
        assertTrue(stakingPool.decrementedSharesAtUnstake(v, s), "106 getter");
        assertEq(
            uint256(vm.load(address(stakingPool), keccak256(abi.encode(s, keccak256(abi.encode(v, uint256(106))))))),
            1, "106 raw slot"
        );

        // 107 must remain correctionsApplied, and nothing in this contract may ever write it
        assertEq(uint256(vm.load(address(stakingPool), bytes32(uint256(107)))), 0, "107 unwritten");
        vm.store(address(stakingPool), bytes32(uint256(107)), bytes32(uint256(1)));
        assertTrue(stakingPool.correctionsApplied(), "107 is correctionsApplied");
    }
}

/// @notice Port of `genesis/test/staking-pool.js` — FakeStaking + pool stake/unstake/claim and delegator fee edge cases.
contract StakingPoolJsTest is JsTruffleFixture {
    event Stake(address indexed validator, address indexed staker, uint256 amount);
    event Unstake(address indexed validator, address indexed staker, uint256 amount);
    event Claim(address indexed validator, address indexed staker, uint256 amount);

    MockChain internal chain;
    address internal validator = vm.addr(11);
    address internal delegator = vm.addr(12);
    address internal stakerAlice = vm.addr(1);
    address internal stakerBob = vm.addr(2);

    function setUp() public {
        chain = deployDefaultMockChain(50, 2);
        chain.staking.addValidator(validator);
        vm.coinbase(vm.addr(256));
        vm.deal(block.coinbase, 100 ether);
        vm.deal(stakerAlice, 100 ether);
        vm.deal(stakerBob, 100 ether);
    }

    function test_emptyDelegatorClaimDoesNotRevert() public {
        vm.prank(delegator);
        chain.staking.claimDelegatorFee(validator);
    }

    function test_simpleStakingEventsAndBalances() public {
        vm.expectEmit(true, true, true, true);
        emit Stake(validator, stakerAlice, 1 ether);
        vm.prank(stakerAlice);
        chain.stakingPool.stake{value: 1 ether}(validator);

        vm.expectEmit(true, true, true, true);
        emit Stake(validator, stakerAlice, 1 ether);
        vm.prank(stakerAlice);
        chain.stakingPool.stake{value: 1 ether}(validator);

        vm.expectEmit(true, true, true, true);
        emit Stake(validator, stakerBob, 1 ether);
        vm.prank(stakerBob);
        chain.stakingPool.stake{value: 1 ether}(validator);

        assertEq(chain.stakingPool.getStakedAmount(validator, stakerAlice), 2 ether);
        assertEq(chain.stakingPool.getStakedAmount(validator, stakerBob), 1 ether);
    }

    function test_stakeUnstakeClaimWithRewards() public {
        vm.prank(stakerAlice);
        chain.stakingPool.stake{value: 50 ether}(validator);
        assertEq(chain.stakingPool.getStakedAmount(validator, stakerAlice), 50 ether);

        rollToNextEpoch(chain, 50);

        vm.prank(block.coinbase);
        vm.txGasPrice(0);
        chain.staking.deposit{value: 1010000000000000000}(validator);
        rollToNextEpoch(chain, 50);

        assertEq(chain.stakingPool.getStakedAmount(validator, stakerAlice), 51009999999999999964);

        vm.expectEmit(true, true, true, true);
        emit Unstake(validator, stakerAlice, 50 ether);
        vm.prank(stakerAlice);
        chain.stakingPool.unstake(validator, 50 ether);
        rollToNextEpoch(chain, 50);

        vm.expectEmit(true, true, true, true);
        emit Claim(validator, stakerAlice, 50 ether);
        vm.prank(stakerAlice);
        chain.stakingPool.claim(validator);

        assertEq(chain.stakingPool.getStakedAmount(validator, stakerAlice), 1009999999999999999);
    }
}
