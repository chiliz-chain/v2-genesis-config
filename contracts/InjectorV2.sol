// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/IChainConfig.sol";
import "./interfaces/IGovernance.sol";
import "./interfaces/ISlashingIndicator.sol";
import "./interfaces/ISystemReward.sol";
import "./interfaces/IRuntimeUpgradeEvmHook.sol";
import "./interfaces/IValidatorSet.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IRuntimeUpgrade.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/IInjector.sol";
import "./interfaces/IDeployerProxy.sol";
import "./interfaces/ITokenomics.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";

/** 
    Warning: Do not use this to upgrade existing contracts. 
    Since storage Layout is different than V1, it would break the state of the contract.

    Only use when deploying new contracts.
*/
abstract contract InjectorContextHolderV2 is Initializable, IInjector {

    // BSC compatible contracts
    IStaking internal _stakingContract;
    ISlashingIndicator internal _slashingIndicatorContract;
    ISystemReward internal _systemRewardContract;
    // CHZ defined contracts
    IStakingPool internal _stakingPoolContract;
    IGovernance internal _governanceContract;
    IChainConfig internal _chainConfigContract;
    IRuntimeUpgrade internal _runtimeUpgradeContract;
    IDeployerProxy internal _deployerProxyContract;
    ITokenomics internal _tokenomicsContract;

    // already init (1) + ctor(1) + injector (9) = 10
    uint256[100 - 9] private __reserved;

    constructor() {}

    function init() external initializer {
        // BSC compatible addresses
        _stakingContract = IStaking(0x0000000000000000000000000000000000001000);
        _slashingIndicatorContract = ISlashingIndicator(0x0000000000000000000000000000000000001001);
        _systemRewardContract = ISystemReward(0x0000000000000000000000000000000000001002);
        // CHZ defined addresses
        _stakingPoolContract = IStakingPool(0x0000000000000000000000000000000000007001);
        _governanceContract = IGovernance(0x0000000000000000000000000000000000007002);
        _chainConfigContract = IChainConfig(0x0000000000000000000000000000000000007003);
        _runtimeUpgradeContract = IRuntimeUpgrade(0x0000000000000000000000000000000000007004);
        _deployerProxyContract = IDeployerProxy(0x0000000000000000000000000000000000007005);
        _tokenomicsContract = ITokenomics(0x0000000000000000000000000000000000007006);
    }

    function initManually(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract,
        IRuntimeUpgrade runtimeUpgradeContract,
        IDeployerProxy deployerProxyContract,
        ITokenomics tokenomicsContract
    ) public initializer {
        // BSC-compatible
        _stakingContract = stakingContract;
        _slashingIndicatorContract = slashingIndicatorContract;
        _systemRewardContract = systemRewardContract;
        // CHZ-defined
        _stakingPoolContract = stakingPoolContract;
        _governanceContract = governanceContract;
        _chainConfigContract = chainConfigContract;
        _runtimeUpgradeContract = runtimeUpgradeContract;
        _deployerProxyContract = deployerProxyContract;
        _tokenomicsContract = tokenomicsContract;
    }

    function isInitialized() external view returns (bool) {
        // openzeppelin's class "Initializable" doesnt expose any methods for fetching initialisation status
        StorageSlot.Uint256Slot storage initializedSlot = StorageSlot.getUint256Slot(bytes32(0x0000000000000000000000000000000000000000000000000000000000000000));
        return initializedSlot.value > 0;
    }

    modifier onlyFromCoinbase() {
        require(msg.sender == block.coinbase, "InjectorContextHolder: only coinbase");
        _;
    }

    modifier onlyFromCoinbaseOrTokenomics() {
        require(
            msg.sender == block.coinbase || ITokenomics(msg.sender) == _tokenomicsContract,
            "InjectorContextHolder: only coinbase or tokenomics"
        );
        _;
    }

    modifier onlyFromSlashingIndicator() {
        require(msg.sender == address(_slashingIndicatorContract), "InjectorContextHolder: only slashing indicator");
        _;
    }

    modifier onlyFromGovernance() {
        require(IGovernance(msg.sender) == _governanceContract, "InjectorContextHolder: only governance");
        _;
    }

    modifier onlyFromRuntimeUpgrade() {
        require(IRuntimeUpgrade(msg.sender) == _runtimeUpgradeContract, "InjectorContextHolder: only runtime upgrade");
        _;
    }

    modifier onlyZeroGasPrice() {
        require(tx.gasprice == 0, "InjectorContextHolder: only zero gas price");
        _;
    }

    function setTokenomics(address addr) public onlyFromGovernance {
        _tokenomicsContract = ITokenomics(addr);
    }
}
