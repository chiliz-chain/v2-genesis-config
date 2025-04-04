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

contract PayableWithHighGasCost {
    mapping(uint256 => uint256) public data;
    bool reentrant;
    SystemReward target;

    constructor(bool _reentrant, address _target) {
        reentrant = _reentrant;
        target = SystemReward(payable(_target));
    }

    receive() external payable {
        data[0] = 1;
        if (reentrant) {
            // keep calling claimSystemFeeExcluded until it fails
            // and ignore the revert error
            try target.claimSystemFeeExcluded(address(this)) {} catch {}
        }
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

    // @notice updateDistributionShare() shouldn't revert if a new account is not able to receive CHZ
    //         the new account should be added to distributionShares & _excludedFromAutoClaim
    //         when auto claim happens, the contract should distribute CHZ to all accounts, meaning
    //          - for accounts that can receive CHZ it should do a transfer
    //          - for accounts that can't - it should keep the amounts in a mapping. the account should be
    //            able to claim these funds manually later.
    function test_systemFeeDistributionShouldWork() public {
        uint256 distributionSharesLen = 2;
        address[] memory accounts = new address[](distributionSharesLen);
        accounts[0] = vm.addr(3);
        accounts[1] = address(new PayableWithHighGasCost(false, address(0)));
        uint16[] memory shares = new uint16[](distributionSharesLen);
        shares[0] = 5000;
        shares[1] = 5000;

        vm.prank(vm.addr(20)); // governance
        systemReward.updateDistributionShare(accounts, shares);

        // check that both accounts are in distributionShares
        bytes32 distributionSharesSlot = bytes32(uint256(104));
        bytes32 acc1Slot = keccak256(abi.encode(104));
        bytes32 acc2Slot = bytes32(uint256(acc1Slot)+1);
        assertEq(uint256(vm.load(address(systemReward), distributionSharesSlot)), distributionSharesLen);
        assertEq(address(uint160(uint256(vm.load(address(systemReward), acc1Slot)))), accounts[0]);
        assertEq(address(uint160(uint256(vm.load(address(systemReward), acc2Slot)))), accounts[1]);

        // check that accounts[1] is in excludedFromAutoClaim
        bytes32 excludedFromAutoClaimSlot = keccak256(abi.encode(accounts[1], 105));
        assertEq(vm.load(address(systemReward), excludedFromAutoClaimSlot), bytes32(uint256(1)));

        // send 60 CHZ to systemReward, this should trigger auto claim
        (bool callSuccess,) = address(systemReward).call{value: 60 ether}("");
        assertEq(callSuccess, true);

        // check that accounts[0] received the chz
        assertEq(accounts[0].balance, 30 ether);
        assertEq(address(systemReward).balance, 30 ether); // 30 ether meant for 2nd account should still be in the contract

        // try to claim fees for excluded account
        systemReward.claimSystemFeeExcluded(accounts[1]);

        // the excluded account should get 30 ethers (50% of what we sent to SystemReward)
        assertEq(accounts[1].balance, 30 ether);
        assertEq(address(systemReward).balance, 0);
        assertEq(uint256(vm.load(address(systemReward), keccak256(abi.encode(accounts[1], 106)) )), 0); //check _amountsForExcludedAccounts
        assertEq(uint256(vm.load(address(systemReward), bytes32(uint256(107)))), 0); //check _totalExcludedAccountsFee
    }

    function test_claimSystemFeeExcluded_RevertWhen_RecipientReenters() public {
        uint256 distributionSharesLen = 2;
        address[] memory accounts = new address[](distributionSharesLen);
        accounts[0] = address(new PayableWithHighGasCost(false, address(0)));
        accounts[1] = address(new PayableWithHighGasCost(true, address(systemReward)));
        uint16[] memory shares = new uint16[](distributionSharesLen);
        shares[0] = 5000;
        shares[1] = 5000;

        vm.prank(vm.addr(20)); // governance
        systemReward.updateDistributionShare(accounts, shares);

        // send 60 CHZ to systemReward, this should trigger auto claim
        (bool callSuccess,) = address(systemReward).call{value: 60 ether}("");
        assertEq(callSuccess, true);

        // try to claim fees for excluded account that tries to reenter the function
        systemReward.claimSystemFeeExcluded(accounts[1]);

        // the account should have received only their share (50% of 60 ether)
        // rest should still be in the contract
        assertEq(accounts[1].balance, 30 ether);
        assertEq(address(systemReward).balance, 30 ether);
    }
}
