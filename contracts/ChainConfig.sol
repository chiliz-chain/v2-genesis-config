// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./Injector.sol";

contract ChainConfig is InjectorContextHolder, IChainConfig {

    event ActiveValidatorsLengthChanged(uint32 prevValue, uint32 newValue, uint64 epoch);
    event EpochBlockIntervalChanged(uint32 prevValue, uint32 newValue);
    event MisdemeanorThresholdChanged(uint32 prevValue, uint32 newValue, uint64 epoch);
    event FelonyThresholdChanged(uint32 prevValue, uint32 newValue);
    event ValidatorJailEpochLengthChanged(uint32 prevValue, uint32 newValue);
    event UndelegatePeriodChanged(uint32 prevValue, uint32 newValue);
    event MinValidatorStakeAmountChanged(uint256 prevValue, uint256 newValue);
    event MinStakingAmountChanged(uint256 prevValue, uint256 newValue);

    struct ConsensusParams {
        uint32 activeValidatorsLength; // depricated. use epochConsensusParams.activeValidatorLength
        uint32 epochBlockInterval;
        uint32 misdemeanorThreshold; // depricated. use epochConsensusParams.misdemeanorThreshold
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
    }

    struct EpochToValue {
        // (epoch => value)
        mapping(uint64 => uint32) value;
        // list of available epochs, sorted in asc order.
        uint64[] epochs;
    }

    struct EpochConsensusParams {
        EpochToValue activeValidatorLength;
        EpochToValue misdemeanorThreshold;
    }

    ConsensusParams private _consensusParams;
    EpochConsensusParams private _epochConsensusParams;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) {
    }

    function ctor(
        uint32 activeValidatorsLength,
        uint32 epochBlockInterval,
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount
    ) external onlyInitializing {
        _epochConsensusParams.activeValidatorLength.value[0] = activeValidatorsLength;
        _epochConsensusParams.activeValidatorLength.epochs.push(0);
        emit ActiveValidatorsLengthChanged(0, activeValidatorsLength, 0);
        _consensusParams.epochBlockInterval = epochBlockInterval;
        emit EpochBlockIntervalChanged(0, epochBlockInterval);
        _epochConsensusParams.misdemeanorThreshold.value[0] = misdemeanorThreshold;
        _epochConsensusParams.misdemeanorThreshold.epochs.push(0);
        emit MisdemeanorThresholdChanged(0, misdemeanorThreshold, 0);
        _consensusParams.felonyThreshold = felonyThreshold;
        emit FelonyThresholdChanged(0, felonyThreshold);
        _consensusParams.validatorJailEpochLength = validatorJailEpochLength;
        emit ValidatorJailEpochLengthChanged(0, validatorJailEpochLength);
        _consensusParams.undelegatePeriod = undelegatePeriod;
        emit UndelegatePeriodChanged(0, undelegatePeriod);
        _consensusParams.minValidatorStakeAmount = minValidatorStakeAmount;
        emit MinValidatorStakeAmountChanged(0, minValidatorStakeAmount);
        _consensusParams.minStakingAmount = minStakingAmount;
        emit MinStakingAmountChanged(0, minStakingAmount);
    }

    function getConsensusParams() external view returns (ConsensusParams memory) {
        return _consensusParams;
    }

    function getActiveValidatorsLength() external view override returns (uint32) {
        return getActiveValidatorsLength(_stakingContract.currentEpoch());
    }

    function getActiveValidatorsLength(uint64 epoch) public view returns (uint32) {
        EpochToValue storage avl = _epochConsensusParams.activeValidatorLength;
        return _getValue(avl, epoch);
    }

    function initActiveValidatorLengthEpochParam(uint64[] memory epochs, uint32[] memory lengths) public onlyFromGovernance {
        require(epochs.length == lengths.length, "IA"); // invalid arguments

        EpochToValue storage avl = _epochConsensusParams.activeValidatorLength;
        require(avl.epochs.length == 0, "AI"); // already initialized

        uint256 len = epochs.length;
        for (uint256 i = 0; i < len; i++) {
            uint64 epoch = epochs[i];
            avl.value[epoch] = lengths[i];
            avl.epochs.push(epoch);
        }
    }

    function initMisdemeanorThresholdParam(uint64[] memory epochs, uint32[] memory thresholds) public onlyFromGovernance {
        require(epochs.length == thresholds.length, "IA"); // invalid arguments

        EpochToValue storage mt = _epochConsensusParams.misdemeanorThreshold;
        require(mt.epochs.length == 0, "AI"); // already initialized

        uint256 len = epochs.length;
        for (uint256 i = 0; i < len; i++) {
            uint64 epoch = epochs[i];
            mt.value[epoch] = thresholds[i];
            mt.epochs.push(epoch);
        }
    }

    function setActiveValidatorsLength(uint32 newValue) external override onlyFromGovernance {
        EpochToValue storage avl = _epochConsensusParams.activeValidatorLength;

        // set new value for next epoch
        uint32 prevValue = _getValue(avl, _stakingContract.currentEpoch());
        uint64 nextEpoch = _stakingContract.nextEpoch();
        _setValue(avl, newValue);
        emit ActiveValidatorsLengthChanged(prevValue, newValue, nextEpoch);
    }

    function getEpochBlockInterval() external view override returns (uint32) {
        return _consensusParams.epochBlockInterval;
    }

    function getMisdemeanorThreshold() external view override returns (uint32) {
        return _consensusParams.misdemeanorThreshold;
    }

    function getMisdemeanorThreshold(uint64 epoch) external view returns (uint32) {
        EpochToValue storage mt = _epochConsensusParams.misdemeanorThreshold;
        return _getValue(mt, epoch);
    }

    function setMisdemeanorThreshold(uint32 newValue) external override onlyFromGovernance {
        EpochToValue storage mt = _epochConsensusParams.misdemeanorThreshold;

        // set new value for next epoch
        uint32 prevValue = _getValue(mt, _stakingContract.currentEpoch());
        uint64 nextEpoch = _stakingContract.nextEpoch();
        _setValue(mt, newValue);
        emit MisdemeanorThresholdChanged(prevValue, newValue, nextEpoch);
    }

    function getFelonyThreshold() external view override returns (uint32) {
        return _consensusParams.felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        uint32 prevValue = _consensusParams.felonyThreshold;
        _consensusParams.felonyThreshold = newValue;
        emit FelonyThresholdChanged(prevValue, newValue);
    }

    function getValidatorJailEpochLength() external view override returns (uint32) {
        return _consensusParams.validatorJailEpochLength;
    }

    function setValidatorJailEpochLength(uint32 newValue) external override onlyFromGovernance {
        uint32 prevValue = _consensusParams.validatorJailEpochLength;
        _consensusParams.validatorJailEpochLength = newValue;
        emit ValidatorJailEpochLengthChanged(prevValue, newValue);
    }

    function getUndelegatePeriod() external view override returns (uint32) {
        return _consensusParams.undelegatePeriod;
    }

    function setUndelegatePeriod(uint32 newValue) external override onlyFromGovernance {
        uint32 prevValue = _consensusParams.undelegatePeriod;
        _consensusParams.undelegatePeriod = newValue;
        emit UndelegatePeriodChanged(prevValue, newValue);
    }

    function getMinValidatorStakeAmount() external view returns (uint256) {
        return _consensusParams.minValidatorStakeAmount;
    }

    function setMinValidatorStakeAmount(uint256 newValue) external override onlyFromGovernance {
        uint256 prevValue = _consensusParams.minValidatorStakeAmount;
        _consensusParams.minValidatorStakeAmount = newValue;
        emit MinValidatorStakeAmountChanged(prevValue, newValue);
    }

    function getMinStakingAmount() external view returns (uint256) {
        return _consensusParams.minStakingAmount;
    }

    function setMinStakingAmount(uint256 newValue) external override onlyFromGovernance {
        uint256 prevValue = _consensusParams.minStakingAmount;
        _consensusParams.minStakingAmount = newValue;
        emit MinStakingAmountChanged(prevValue, newValue);
    }

    function _getValue(EpochToValue storage param, uint64 epoch) internal view returns (uint32) {
        if (param.value[epoch] > 0) {
            return param.value[epoch];
        } else {
            uint256 epochsLen = param.epochs.length;
            uint64 lastAvailableEpoch = param.epochs[epochsLen - 1];
            // If we don't have the value for the epoch, return the lastAvailable epoch value if possible.
            // (actually, epoch == lastAvailableEpoch case should be covered by the if statement above, but whatever..)
            if (epoch >= lastAvailableEpoch) {
                return param.value[lastAvailableEpoch];
            } else {
                // If we don't have the value for the epoch and epoch < lastAvailable
                // binary search to find the closest epoch
                uint256 left = 0;
                uint256 right = epochsLen;
                while (left < right) {
                     uint256 mid = left + (right - left) / 2;
                     if (param.epochs[mid] <= epoch) {
                         left = mid + 1;
                     } else {
                         right = mid;
                     }
                }
                return param.value[param.epochs[left-1]];
            }
        }
    }

    function _setValue(EpochToValue storage param, uint32 value) internal {
        uint64 nextEpoch = _stakingContract.nextEpoch();
        param.value[nextEpoch] = value;
        param.epochs.push(nextEpoch);
    }
}
