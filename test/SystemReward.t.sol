// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

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
import {JsTruffleFixture} from "./JsTruffleFixture.sol";

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

contract PayableWithHighGasCostReturnBomb {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return new bytes(2 ** 20); // ~1MB of data
    }
}

/// @notice `SystemRewardTest`: real `SystemReward` + storage-heavy cases. `SystemRewardJsTest`: Fake + Truffle JS parity (`system.js`).
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

    function test_claimSystemFee_returnbomb() public {
        uint256 distributionSharesLen = 1;
        address[] memory accounts = new address[](distributionSharesLen);
        accounts[0] = address(new PayableWithHighGasCostReturnBomb());
        uint16[] memory shares = new uint16[](distributionSharesLen);
        shares[0] = 10000;

        vm.prank(vm.addr(20)); // governance
        systemReward.updateDistributionShare(accounts, shares);

        // send 60 CHZ to systemReward, this should trigger auto claim
        (bool callSuccess,) = address(systemReward).call{value: 60 ether}("");
        assertEq(callSuccess, true);

        // try to claim fees for excluded account that tries to returnbomb, shouldn't revert
        systemReward.claimSystemFeeExcluded(accounts[0]);
    }
}

/// @notice Port of `genesis/test/system.js` — fee accounting, auto-claim threshold, splits, dust (`FakeSystemReward`).
contract SystemRewardJsTest is JsTruffleFixture {
    event DistributionShareChanged(address account, uint16 share);
    event FeeClaimed(address account, uint256 amount);

    MockChain internal chain;
    address internal treasury = vm.addr(30);
    address internal governanceTestAccount = vm.addr(31);
    address internal fundingAccount = vm.addr(32);

    function setUp() public {
        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardAccounts = new address[](1);
        rewardAccounts[0] = treasury;
        uint16[] memory rewardShares = new uint16[](1);
        rewardShares[0] = 10000;
        address[] memory noDeployers = new address[](0);
        chain = deployMockChain(
            noValidators, noStakes, rewardAccounts, rewardShares, noDeployers, vm.addr(1), 10, 2
        );
        vm.deal(fundingAccount, 200 ether);
        vm.deal(address(this), 10 ether);
    }

    function test_systemFeeAccumulates_claimResets() public {
        vm.startPrank(fundingAccount);
        (bool sent,) = address(chain.systemReward).call{value: 1 ether}("");
        assertTrue(sent);
        vm.stopPrank();

        assertEq(address(chain.systemReward).balance, 1 ether);
        assertEq(chain.systemReward.getSystemFee(), 1 ether);

        vm.prank(fundingAccount);
        (sent,) = address(chain.systemReward).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(address(chain.systemReward).balance, 2 ether);
        assertEq(chain.systemReward.getSystemFee(), 2 ether);

        vm.prank(treasury);
        chain.systemReward.claimSystemFee();
        assertEq(address(chain.systemReward).balance, 0);
        assertEq(chain.systemReward.getSystemFee(), 0);
    }

    function test_autoClaimAt50Ether() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(fundingAccount);
        (bool sent,) = address(chain.systemReward).call{value: 49 ether}("");
        assertTrue(sent);
        assertEq(treasury.balance, treasuryBalanceBefore);
        assertEq(chain.systemReward.getSystemFee(), 49 ether);

        vm.prank(fundingAccount);
        (sent,) = address(chain.systemReward).call{value: 2 ether}("");
        assertTrue(sent);
        assertEq(treasury.balance, treasuryBalanceBefore + 51 ether);
        assertEq(chain.systemReward.getSystemFee(), 0);
    }

    function test_distributionSharesSplit() public {
        SystemReward.DistributionShare[] memory initial = chain.systemReward.getDistributionShares();
        assertEq(initial.length, 1);
        assertEq(initial[0].account, treasury);
        assertEq(initial[0].share, 10000);

        vm.prank(fundingAccount);
        (bool sent,) = address(chain.systemReward).call{value: 49 ether}("");
        assertTrue(sent);
        chain.systemReward.claimSystemFee();

        address[] memory newAccounts = new address[](3);
        newAccounts[0] = treasury;
        newAccounts[1] = fundingAccount;
        newAccounts[2] = governanceTestAccount;
        uint16[] memory newShares = new uint16[](3);
        newShares[0] = 5000;
        newShares[1] = 2500;
        newShares[2] = 2500;

        vm.expectEmit(true, true, true, true);
        emit DistributionShareChanged(treasury, 5000);
        vm.expectEmit(true, true, true, true);
        emit DistributionShareChanged(fundingAccount, 2500);
        vm.expectEmit(true, true, true, true);
        emit DistributionShareChanged(governanceTestAccount, 2500);
        chain.systemReward.updateDistributionShare(newAccounts, newShares);

        vm.prank(fundingAccount);
        (sent,) = address(chain.systemReward).call{value: 49 ether}("");
        assertTrue(sent);

        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(treasury, 24.5 ether);
        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(fundingAccount, 12.25 ether);
        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(governanceTestAccount, 12.25 ether);
        chain.systemReward.claimSystemFee();
    }

    function test_dustSplit9010() public {
        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardAccounts = new address[](2);
        rewardAccounts[0] = treasury;
        rewardAccounts[1] = fundingAccount;
        uint16[] memory rewardShares = new uint16[](2);
        rewardShares[0] = 1000;
        rewardShares[1] = 9000;
        address[] memory noDeployers = new address[](0);
        chain = deployMockChain(
            noValidators, noStakes, rewardAccounts, rewardShares, noDeployers, vm.addr(1), 10, 2
        );

        (bool sent,) = address(chain.systemReward).call{value: 12345}("");
        assertTrue(sent);

        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(treasury, 1234);
        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(fundingAccount, 11110);
        chain.systemReward.claimSystemFee();
        assertEq(chain.systemReward.getSystemFee(), 1);
    }

    function test_shrinkDistributionArray() public {
        address[] memory noValidators = new address[](0);
        uint256[] memory noStakes = new uint256[](0);
        address[] memory rewardAccounts = new address[](2);
        rewardAccounts[0] = treasury;
        rewardAccounts[1] = fundingAccount;
        uint16[] memory rewardShares = new uint16[](2);
        rewardShares[0] = 1000;
        rewardShares[1] = 9000;
        address[] memory noDeployers = new address[](0);
        chain = deployMockChain(
            noValidators, noStakes, rewardAccounts, rewardShares, noDeployers, vm.addr(1), 10, 2
        );

        SystemReward.DistributionShare[] memory sharesBefore = chain.systemReward.getDistributionShares();
        assertEq(sharesBefore.length, 2);

        address[] memory singleTreasury = new address[](1);
        singleTreasury[0] = treasury;
        uint16[] memory fullTreasury = new uint16[](1);
        fullTreasury[0] = 10000;
        chain.systemReward.updateDistributionShare(singleTreasury, fullTreasury);

        SystemReward.DistributionShare[] memory sharesAfter = chain.systemReward.getDistributionShares();
        assertEq(sharesAfter.length, 1);
        assertEq(sharesAfter[0].account, treasury);
        assertEq(sharesAfter[0].share, 10000);
    }

    function test_revertOnBadShareDistribution() public {
        address[] memory emptyAccounts = new address[](0);
        uint16[] memory emptyShares = new uint16[](0);
        vm.expectRevert(bytes("SystemReward: bad share distribution"));
        chain.systemReward.updateDistributionShare(emptyAccounts, emptyShares);

        address[] memory oneTreasury = new address[](1);
        oneTreasury[0] = treasury;

        uint16[] memory shareZero = new uint16[](1);
        shareZero[0] = 0;
        vm.expectRevert(bytes("SystemReward: bad share distribution"));
        chain.systemReward.updateDistributionShare(oneTreasury, shareZero);

        uint16[] memory shareOverflow = new uint16[](1);
        shareOverflow[0] = 10001;
        vm.expectRevert(bytes("SystemReward: bad share distribution"));
        chain.systemReward.updateDistributionShare(oneTreasury, shareOverflow);

        uint16[] memory shareTooSmallTotal = new uint16[](1);
        shareTooSmallTotal[0] = 1;
        vm.expectRevert(bytes("SystemReward: bad share distribution"));
        chain.systemReward.updateDistributionShare(oneTreasury, shareTooSmallTotal);

        uint16[] memory shareAlmostFull = new uint16[](1);
        shareAlmostFull[0] = 9999;
        vm.expectRevert(bytes("SystemReward: bad share distribution"));
        chain.systemReward.updateDistributionShare(oneTreasury, shareAlmostFull);
    }
}
