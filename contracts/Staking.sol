// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./Injector.sol";


contract Staking is IStaking, InjectorContextHolder {
    /**
     * This constant indicates precision of storing compact balances in the storage or floating point. Since default
     * balance precision is 256 bits it might gain some overhead on the storage because we don't need to store such huge
     * amount range. That is why we compact balances in uint112 values instead of uint256. By managing this value
     * you can set the precision of your balances, aka min and max possible staking amount. This value depends
     * mostly on your asset price in USD, for example ETH costs 4000$ then if we use 1 ether precision it takes 4000$
     * as min amount that might be problematic for users to do the stake. We can set 1 gwei precision and in this case
     * we increase min staking amount in 1e9 times, but also decreases max staking amount or total amount of staked assets.
     *
     * Here is an universal formula, if your asset is cheap in USD equivalent, like ~1$, then use 1 ether precision,
     * otherwise it might be better to use 1 gwei precision or any other amount that your want.
     *
     * Also be careful with setting `minValidatorStakeAmount` and `minStakingAmount`, because these values has
     * the same precision as specified here. It means that if you set precision 1 ether, then min staking amount of 10
     * tokens should have 10 raw value. For 1 gwei precision 10 tokens min amount should be stored as 10000000000.
     *
     * For the 112 bits we have ~32 decimals lg(2**112)=33.71 (lets round to 32 for simplicity). We split this amount
     * into integer (24) and for fractional (8) parts. It means that we can have only 8 decimals after zero.
     *
     * Based in current params we have next min/max values:
     * - min staking amount: 0.00000001 or 1e-8
     * - max staking amount: 1000000000000000000000000 or 1e+24
     *
     * WARNING: precision must be a 1eN format (A=1, N>0)
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;
    /**
     * Here is min/max commission rates. Lets don't allow to set more than 30% of validator commission, because it's
     * too big commission for validator. Commission rate is a percents divided by 100 stored with 0 decimals as percents*100 (=pc/1e2*1e4)
     *
     * Here is some examples:
     * + 0.3% => 0.3*100=30
     * + 3% => 3*100=300
     * + 30% => 30*100=3000
     */
    uint16 internal constant COMMISSION_RATE_MIN_VALUE = 0; // 0%
    uint16 internal constant COMMISSION_RATE_MAX_VALUE = 3000; // 30%
    /**
     * This gas limit is used for internal transfers, BSC doesn't support berlin and it
     * might cause problems with smart contracts who used to stake transparent proxies or
     * beacon proxies that have a lot of expensive SLOAD instructions.
     */
    uint64 internal constant TRANSFER_GAS_LIMIT = 30000;

    // validator events
    event ValidatorAdded(address indexed validator, address owner, uint8 status, uint16 commissionRate);
    event ValidatorModified(address indexed validator, address owner, uint8 status, uint16 commissionRate);
    event ValidatorRemoved(address indexed validator);
    event ValidatorOwnerClaimed(address indexed validator, uint256 amount, uint64 epoch);
    event ValidatorSlashed(address indexed validator, uint32 slashes, uint64 epoch);
    event ValidatorJailed(address indexed validator, uint64 epoch);
    event ValidatorReleased(address indexed validator, uint64 epoch);

    // staker events
    event Delegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Undelegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Claimed(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Redelegated(address indexed validator, address indexed staker, uint256 amount, uint256 dust, uint64 epoch);

    event SystemFeeClaimed(address indexed validator, uint256 amount, uint64 epoch);

    event Paused(bool paused);

    enum ValidatorStatus {
        NotFound,
        Active,
        Pending,
        Jail
    }

    struct ValidatorSnapshot {
        uint96 totalRewards;
        uint112 totalDelegated;
        uint32 slashesCount;
        uint16 commissionRate;
    }

    struct Validator {
        address validatorAddress;
        address ownerAddress;
        ValidatorStatus status;
        uint64 changedAt;
        uint64 jailedBefore;
        uint64 claimedAt;
    }

    struct DelegationOpDelegate {
        uint112 amount;
        uint64 epoch;
    }

    struct DelegationOpUndelegate {
        uint112 amount;
        uint64 epoch;
    }

    struct ValidatorDelegation {
        DelegationOpDelegate[] delegateQueue;
        uint64 delegateGap;
        DelegationOpUndelegate[] undelegateQueue;
        uint64 undelegateGap;
    }

    struct EpochToActiveValidatorsList {
        // (epoch => list of active validators)
        mapping(uint64 => address[]) value;
        // list of available epochs, sorted in asc order.
        uint64[] epochs;
    }

    // mapping from validator address to validator
    mapping(address => Validator) internal _validatorsMap;
    // mapping from validator owner to validator address
    mapping(address => address) internal _validatorOwners;
    // list of all validators that are in validators mapping
    address[] internal _activeValidatorsList;
    // mapping with stakers to validators at epoch (validator -> delegator -> delegation)
    mapping(address => mapping(address => ValidatorDelegation)) internal _validatorDelegations;
    // mapping with validator snapshots per each epoch (validator -> epoch -> snapshot)
    mapping(address => mapping(uint64 => ValidatorSnapshot)) internal _validatorSnapshots;

    bool internal _paused;

    EpochToActiveValidatorsList internal _activeValidatorsListPerEpoch;

    // mapping with validator addresses and the block.timestamp upon addition (validator -> timestamp)
    // used for chronological sorting in _getValidators()
    mapping(address => uint256) internal _validatorAdditionTs;
    // mapping with validator addresses and epochs where the system fee was claimed (validator -> epoch)
    mapping(address => uint64) internal _systemFeeClaimedAt;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) {
    }

    function ctor(address[] calldata validators, uint256[] calldata initialStakes, uint16 commissionRate) external onlyInitializing {
        require(initialStakes.length == validators.length);
        uint256 totalStakes = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            _addValidator(validators[i], validators[i], ValidatorStatus.Active, commissionRate, initialStakes[i], 0);
            totalStakes += initialStakes[i];
        }
        require(address(this).balance == totalStakes, "bm"); // balance mismatch
    }

    function initActiveValidatorsListPerEpoch() public onlyFromGovernance {
        require(_activeValidatorsListPerEpoch.epochs.length == 0, "AI"); // already initialized

        // copy _activeValidatorsList to epoch 0 and to current epoch
        _activeValidatorsListPerEpoch.value[0] = _activeValidatorsList;
        _activeValidatorsListPerEpoch.epochs.push(0);
        uint64 e = _currentEpoch();
        if (e > 0) {
            _activeValidatorsListPerEpoch.value[e] = _activeValidatorsList;
            _activeValidatorsListPerEpoch.epochs.push(e);
        }
    }

    function initValidatorAdditionTs() public onlyFromGovernance {
        address[] memory avl = getActiveValidatorsList(_currentEpoch());
        uint64 i;
        for (; i < avl.length; ++i) {
            _validatorAdditionTs[_activeValidatorsList[i]] = block.timestamp;
        }
    }

    function getValidatorDelegation(address validatorAddress, address delegator) external view override returns (
        uint256 delegatedAmount,
        uint64 atEpoch
    ) {
        ValidatorDelegation memory delegation = _validatorDelegations[validatorAddress][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        return (_unpackCompact(snapshot.amount), snapshot.epoch);
    }

    function getValidatorStatus(address validatorAddress) external view override returns (
        address ownerAddress,
        uint8 status,
        uint256 totalDelegated,
        uint32 slashesCount,
        uint64 changedAt,
        uint64 jailedBefore,
        uint64 claimedAt,
        uint16 commissionRate,
        uint96 totalRewards
    ) {
        Validator memory validator = _validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return (
        ownerAddress = validator.ownerAddress,
        status = uint8(validator.status),
        totalDelegated = _unpackCompact(snapshot.totalDelegated),
        slashesCount = snapshot.slashesCount,
        changedAt = validator.changedAt,
        jailedBefore = validator.jailedBefore,
        claimedAt = validator.claimedAt,
        commissionRate = snapshot.commissionRate,
        totalRewards = snapshot.totalRewards
        );
    }

    function getValidatorStatusAtEpoch(address validatorAddress, uint64 epoch) external view returns (
        address ownerAddress,
        uint8 status,
        uint256 totalDelegated,
        uint32 slashesCount,
        uint64 changedAt,
        uint64 jailedBefore,
        uint64 claimedAt,
        uint16 commissionRate,
        uint96 totalRewards
    ) {
        Validator memory validator = _validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _fetchValidatorSnapshot(validator, epoch);
        return (
        ownerAddress = validator.ownerAddress,
        status = uint8(validator.status),
        totalDelegated = _unpackCompact(snapshot.totalDelegated),
        slashesCount = snapshot.slashesCount,
        changedAt = validator.changedAt,
        jailedBefore = validator.jailedBefore,
        claimedAt = validator.claimedAt,
        commissionRate = snapshot.commissionRate,
        totalRewards = snapshot.totalRewards
        );
    }

    function getValidatorByOwner(address owner) external view override returns (address) {
        return _validatorOwners[owner];
    }

    function releaseValidatorFromJail(address validatorAddress) external {
        // make sure validator is in jail
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Jail, "nj"); // not jailed
        // only validator owner
        require(msg.sender == validator.ownerAddress, "oo"); // only owner
        require(_currentEpoch() >= validator.jailedBefore, "sj"); // still jailed
        // update validator status
        validator.status = ValidatorStatus.Active;
        _validatorsMap[validatorAddress] = validator;
        _addValidatorToActiveValidatorsList(validatorAddress, _nextEpoch());
        // emit event
        emit ValidatorReleased(validatorAddress, _currentEpoch());
    }

    function _totalDelegatedToValidator(Validator memory validator, uint64 epoch) internal view returns (uint256) {
        ValidatorSnapshot memory s = _fetchValidatorSnapshot(validator, epoch);
        return _unpackCompact(s.totalDelegated);
    }

    function delegate(address validatorAddress) payable external override {
        _delegateTo(msg.sender, validatorAddress, msg.value);
    }

    function undelegate(address validatorAddress, uint256 amount) external override {
        _undelegateFrom(msg.sender, validatorAddress, amount);
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch();
    }

    function nextEpoch() external view returns (uint64) {
        return _nextEpoch();
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.number / _chainConfigContract.getEpochBlockInterval() + 0);
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function _touchValidatorSnapshot(Validator memory validator, uint64 epoch)
        internal
        returns (ValidatorSnapshot storage)
    {
        ValidatorSnapshot storage snapshot = _validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }

        uint64 EpochToCopyFrom = validator.changedAt;
        if (epoch < validator.changedAt) {
            EpochToCopyFrom = findLatestSnapshotBefore(validator.validatorAddress, epoch);
        }

        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot = _validatorSnapshots[validator.validatorAddress][EpochToCopyFrom];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // we must save last affected epoch for this validator to be able to restore total delegated
        // amount in the future (check condition upper)
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
        return snapshot;
    }

    function findLatestSnapshotBefore(address validatorAddress, uint64 epoch) internal view returns (uint64) {
        // Adding a security check to avoid consuming too much gas
        uint8 MAX_NB_EPOCH_TO_CHECK = 50;

        uint64 latestEpoch = 0;
        uint64 i;
        for (i = 0; i <= MAX_NB_EPOCH_TO_CHECK; i++) {
            uint64 e = epoch - i;
            if (_validatorSnapshots[validatorAddress][e].totalDelegated > 0) {
                latestEpoch = e;
                break;
            }
        }
        if (i > MAX_NB_EPOCH_TO_CHECK) {
            return epoch;
        }

        return latestEpoch;
    }

    function _fetchValidatorSnapshot(Validator memory validator, uint64 epoch) internal view returns (ValidatorSnapshot memory) {
        ValidatorSnapshot memory snapshot = _validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        uint64 EpochToFetchFrom = validator.changedAt;
        if (epoch < validator.changedAt) {
            EpochToFetchFrom = findLatestSnapshotBefore(validator.validatorAddress, epoch);
        }
        ValidatorSnapshot memory lastModifiedSnapshot = _validatorSnapshots[validator.validatorAddress][EpochToFetchFrom];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // return existing or new snapshot
        return snapshot;
    }

    function _delegateTo(address fromDelegator, address toValidator, uint256 amount) internal {
        require(!_paused);
        // check is minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount != 0, "tl"); // amount too low
        require(amount % BALANCE_COMPACT_PRECISION == 0, "hr"); // amount have a remainder
        // make sure amount is greater than min staking amount
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[toValidator];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        uint64 atEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, atEpoch);
        validatorSnapshot.totalDelegated += _packCompact(amount);
        _validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = _validatorDelegations[toValidator][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += _packCompact(amount);
            } else {
                _createOpDelegate(delegation.delegateQueue, atEpoch, recentDelegateOp.amount + _packCompact(amount));
            }
        } else {
            // there is no any delegations at al, lets create the first one
            _createOpDelegate(delegation.delegateQueue, atEpoch, _packCompact(amount));
        }
        // emit event with the next epoch
        emit Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(address toDelegator, address fromValidator, uint256 amount) internal {
        require(!_paused);
        // check minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount != 0, "tl"); // amount to low
        require(amount % BALANCE_COMPACT_PRECISION == 0, "hr"); // have a remainder
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[fromValidator];
        uint64 beforeEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, beforeEpoch);
        require(validatorSnapshot.totalDelegated >= _packCompact(amount), "is"); // insufficient balance
        validatorSnapshot.totalDelegated -= _packCompact(amount);
        _validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = _validatorDelegations[fromValidator][toDelegator];
        require(delegation.delegateQueue.length > 0, "qe");
        DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        require(recentDelegateOp.amount >= uint64(amount / BALANCE_COMPACT_PRECISION), "ib"); // insufficient balance
        uint112 nextDelegatedAmount = recentDelegateOp.amount - _packCompact(amount);
        if (recentDelegateOp.epoch >= beforeEpoch) {
            // decrease total delegated amount for the next epoch
            recentDelegateOp.amount = nextDelegatedAmount;
        } else {
            // there is no pending delegations, so lets create the new one with the new amount
            _createOpDelegate(delegation.delegateQueue, beforeEpoch, nextDelegatedAmount);
        }
        // create new undelegate queue operation with soft lock
        // Unless the undelegate period changes, the undelegateQueue is sorted by epoch in ascending order.
        // Considering the above, if undelegate period increases,
        // the `epoch` of the last operation in the queue will be less than or equal to the new operation's `epoch`.
        // In this case we can safely push the new operation to the end of the queue.
        // However, if the undelegate period decreases, we need to find the correct position to insert the new operation.
        uint64 undelegateEpoch = beforeEpoch + _chainConfigContract.getUndelegatePeriod();
        if (delegation.undelegateQueue.length == 0 || delegation.undelegateQueue[delegation.undelegateQueue.length-1].epoch < undelegateEpoch) {
            delegation.undelegateQueue.push(DelegationOpUndelegate({amount : _packCompact(amount), epoch : undelegateEpoch}));
        } else if (delegation.undelegateQueue[delegation.undelegateQueue.length-1].epoch == undelegateEpoch) {
            delegation.undelegateQueue[delegation.undelegateQueue.length-1].amount += _packCompact(amount);
        } else {
            // find insert position
            uint256 pos = delegation.undelegateGap;
            while (pos < delegation.undelegateQueue.length && delegation.undelegateQueue[pos].epoch < undelegateEpoch) {
                pos++;
            }

            // Expand array with a dummy value and shift elements in [pos,len-1] range to make space for the new insertion
            delegation.undelegateQueue.push(DelegationOpUndelegate(0,0));
            for (uint256 i = delegation.undelegateQueue.length - 1; i > pos; i--) {
                delegation.undelegateQueue[i] = delegation.undelegateQueue[i - 1];
            }
            delegation.undelegateQueue[pos] = DelegationOpUndelegate({amount : _packCompact(amount), epoch : undelegateEpoch});
        }

        // emit event with the next epoch number
        emit Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    function _transferDelegatorRewards(address validator, address delegator, uint64 beforeEpochExclude, bool withRewards, bool withUndelegates) internal {
        ValidatorDelegation storage delegation = _validatorDelegations[validator][delegator];
        // claim rewards and undelegates
        uint256 availableFunds = 0;
        if (withRewards) {
            availableFunds += _processDelegateQueue(validator, delegation, beforeEpochExclude);
        }
        if (withUndelegates) {
            availableFunds += _processUndelegateQueue(delegation, beforeEpochExclude);
        }
        // for transfer claim mode just all rewards to the user
        _safeTransferWithGasLimit(payable(delegator), availableFunds);
        // emit event
        emit Claimed(validator, delegator, availableFunds, beforeEpochExclude);
    }

    function _redelegateDelegatorRewards(address validator, address delegator, uint64 beforeEpochExclude) internal returns (uint256 amountToStake, uint256 rewardsDust) {
        ValidatorDelegation storage delegation = _validatorDelegations[validator][delegator];
        // claim rewards and undelegates
        uint256 availableFunds = _processDelegateQueue(validator, delegation, beforeEpochExclude);
        (amountToStake, rewardsDust) = _calcAvailableForRedelegateAmount(availableFunds);
        // if we have something to re-stake then delegate it to the validator
        if (amountToStake > 0) {
            _delegateTo(delegator, validator, amountToStake);
        }
        // if we have dust from staking then send it to user (we can't keep them in the contract)
        if (rewardsDust > 0) {
            _safeTransferWithGasLimit(payable(delegator), rewardsDust);
        }
        // emit event
        emit Redelegated(validator, delegator, amountToStake, rewardsDust, beforeEpochExclude);
    }

    function _processDelegateQueue(address validator, ValidatorDelegation storage delegation, uint64 beforeEpochExclude) internal returns (uint256 availableFunds) {
        uint64 delegateGap = delegation.delegateGap;
        for (uint256 queueLength = delegation.delegateQueue.length; delegateGap < queueLength;) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegateGap];
            if (delegateOp.epoch >= beforeEpochExclude) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegateGap < queueLength - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegateGap + 1].epoch;
            }
            for (; delegateOp.epoch < beforeEpochExclude && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch); delegateOp.epoch++) {
                ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (uint256 delegatorFee, /*uint256 ownerFee*/, /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot, delegateOp.epoch);
                availableFunds += delegatorFee * delegateOp.amount / validatorSnapshot.totalDelegated;
            }
            // if we have reached end of the delegation list then lets stay on the last item, but with updated latest processed epoch
            if (delegateGap >= queueLength - 1) {
                delegation.delegateQueue[delegateGap] = delegateOp;
                break;
            }

            if (beforeEpochExclude <= voteChangedAtEpoch) {
                // Partially processed. Stay on the last item, but with updated latest processed epoch
                delegation.delegateQueue[delegateGap] = delegateOp;
            } else {
                // Fully processed, the delegation can be deleted from queue.
                delete delegation.delegateQueue[delegateGap];
                ++delegateGap;
            }
        }
        delegation.delegateGap = delegateGap;
        return availableFunds;
    }

    function _processUndelegateQueue(ValidatorDelegation storage delegation, uint64 beforeEpochExclude) internal returns (uint256 availableFunds) {
        uint64 undelegateGap = delegation.undelegateGap;
        for (uint256 queueLength = delegation.undelegateQueue.length; undelegateGap < queueLength;) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[undelegateGap];
            if (undelegateOp.epoch > beforeEpochExclude) {
                break;
            }
            availableFunds += _unpackCompact(undelegateOp.amount);
            delete delegation.undelegateQueue[undelegateGap];
            ++undelegateGap;
        }
        delegation.undelegateGap = undelegateGap;
        return availableFunds;
    }

    function _calcDelegatorRewardsAndPendingUndelegates(address validator, address delegator, uint64 beforeEpoch, bool withUndelegate) internal view returns (uint256) {
        ValidatorDelegation memory delegation = _validatorDelegations[validator][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        while (delegation.delegateGap < delegation.delegateQueue.length) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegation.delegateGap];
            if (delegateOp.epoch >= beforeEpoch) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegation.delegateGap < delegation.delegateQueue.length - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegation.delegateGap + 1].epoch;
            }
            for (; delegateOp.epoch < beforeEpoch && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch); delegateOp.epoch++) {
                ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (uint256 delegatorFee, /*uint256 ownerFee*/, /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot, delegateOp.epoch);
                availableFunds += delegatorFee * delegateOp.amount / validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (withUndelegate && delegation.undelegateGap < delegation.undelegateQueue.length) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds += _unpackCompact(undelegateOp.amount);
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(Validator storage validator, uint64 beforeEpoch) internal {
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[validator.validatorAddress][claimAt];
            (/*uint256 delegatorFee*/, uint256 ownerFee, uint256 slashingFee) = _calcValidatorSnapshotEpochPayout(validatorSnapshot, claimAt);
            availableFunds += ownerFee;
            if (claimAt > _systemFeeClaimedAt[validator.validatorAddress]){
                systemFee += slashingFee;
                _systemFeeClaimedAt[validator.validatorAddress] = claimAt;
            }
        }
        validator.claimedAt = claimAt;
        _safeTransferWithGasLimit(payable(validator.ownerAddress), availableFunds);
        if (systemFee > 0) {
            _unsafeTransfer(payable(address(_systemRewardContract)), systemFee);
        }
        emit ValidatorOwnerClaimed(validator.validatorAddress, availableFunds, beforeEpoch);
    }

    function _calcValidatorOwnerRewards(Validator memory validator, uint64 beforeEpoch) internal view returns (uint256) {
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[validator.validatorAddress][validator.claimedAt];
            (/*uint256 delegatorFee*/, uint256 ownerFee, /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot, validator.claimedAt);
            availableFunds += ownerFee;
        }
        return availableFunds;
    }

    function _calcValidatorSnapshotEpochPayout(ValidatorSnapshot memory validatorSnapshot, uint64 epoch) internal view returns (uint256 delegatorFee, uint256 ownerFee, uint256 systemFee) {
        // detect validator slashing to transfer all rewards to treasury
        if (validatorSnapshot.slashesCount >= _chainConfigContract.getMisdemeanorThreshold(epoch)) {
            return (delegatorFee = 0, ownerFee = 0, systemFee = validatorSnapshot.totalRewards);
        } else if (validatorSnapshot.totalDelegated == 0) {
            return (delegatorFee = 0, ownerFee = validatorSnapshot.totalRewards, systemFee = 0);
        }
        // ownerFee_(18+4-4=18) = totalRewards_18 * commissionRate_4 / 1e4
        ownerFee = uint256(validatorSnapshot.totalRewards) * validatorSnapshot.commissionRate / 1e4;
        // delegatorRewards = totalRewards - ownerFee
        delegatorFee = validatorSnapshot.totalRewards - ownerFee;
        // default system fee is zero for epoch
        systemFee = 0;
    }

    function registerValidator(address validatorAddress, uint16 commissionRate) payable external override {
        uint256 initialStake = msg.value;
        // // initial stake amount should be greater than minimum validator staking amount
        require(initialStake >= _chainConfigContract.getMinValidatorStakeAmount(), "tl"); // initial stake too low
        require(initialStake % BALANCE_COMPACT_PRECISION == 0, "hr"); // amount have a remainder
        // add new validator as pending
        _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
    }

    function addValidator(address account) external onlyFromGovernance virtual override {
        _addValidator(account, account, ValidatorStatus.Active, 0, 0, _nextEpoch());
    }

    function _addValidator(address validatorAddress, address validatorOwner, ValidatorStatus status, uint16 commissionRate, uint256 initialStake, uint64 sinceEpoch) internal {
        // validator commission rate
        require(commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE, "bcr"); // bad commission rate
        // init validator default params
        Validator storage validator = _validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.NotFound, "ae"); // validator already exists
        validator.validatorAddress = validatorAddress;
        validator.ownerAddress = validatorOwner;
        validator.status = status;
        validator.changedAt = sinceEpoch;
        validator.claimedAt = sinceEpoch;
        // save validator owner
        require(_validatorOwners[validatorOwner] == address(0x00), "ou"); // owner already in use
        _validatorOwners[validatorOwner] = validatorAddress;
        // add new validator to array
        if (status == ValidatorStatus.Active) {
            _addValidatorToActiveValidatorsList(validatorAddress, sinceEpoch);
        }
        // push initial validator snapshot at zero epoch with default params
        _validatorSnapshots[validatorAddress][sinceEpoch] = ValidatorSnapshot(0, _packCompact(initialStake), 0, commissionRate);
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = _validatorDelegations[validatorAddress][validatorOwner];
        require(delegation.delegateQueue.length == 0, "eq"); // empty queue
        _createOpDelegate(delegation.delegateQueue,sinceEpoch, _packCompact(initialStake));
        // emit event
        emit ValidatorAdded(validatorAddress, validatorOwner, uint8(status), commissionRate);
    }

    function _addValidatorToActiveValidatorsList(address validatorAddress, uint64 epoch) internal {
        if (epoch == 0) {
            _activeValidatorsListPerEpoch.value[epoch].push(validatorAddress);
            _activeValidatorsListPerEpoch.epochs.push(epoch);
        } else if (_activeValidatorsListPerEpoch.value[epoch].length == 0 && _activeValidatorsListPerEpoch.epochs.length > 0) {
            // copy the last known list
            uint64 lastKnownEpoch = _activeValidatorsListPerEpoch.epochs[_activeValidatorsListPerEpoch.epochs.length-1];
            _activeValidatorsListPerEpoch.value[epoch] = _activeValidatorsListPerEpoch.value[lastKnownEpoch];

            _activeValidatorsListPerEpoch.value[epoch].push(validatorAddress);
            _activeValidatorsListPerEpoch.epochs.push(epoch);
        } else{
            _activeValidatorsListPerEpoch.value[epoch].push(validatorAddress);
        }
        _validatorAdditionTs[validatorAddress] = block.timestamp;
    }

    function getActiveValidatorsList(uint64 epoch) public view returns (address[] memory) {
        if (_activeValidatorsListPerEpoch.value[epoch].length > 0) {
            return _activeValidatorsListPerEpoch.value[epoch];
        } else {
            uint256 epochsLen = _activeValidatorsListPerEpoch.epochs.length;
            uint64 lastAvailableEpoch = _activeValidatorsListPerEpoch.epochs[epochsLen - 1];
            // If we don't have the value for the epoch, return the lastAvailable epoch value if possible.
            // (actually, epoch == lastAvailableEpoch case should be covered by the if statement above, but whatever..)
            if (epoch >= lastAvailableEpoch) {
                return _activeValidatorsListPerEpoch.value[lastAvailableEpoch];
            } else {
                // If we don't have the value for the epoch and epoch < lastAvailable
                // binary search to find the closest epoch
                uint256 left = 0;
                uint256 right = epochsLen;
                while (left < right) {
                     uint256 mid = left + (right - left) / 2;
                     if (_activeValidatorsListPerEpoch.epochs[mid] <= epoch) {
                         left = mid + 1;
                     } else {
                         right = mid;
                     }
                }
                return _activeValidatorsListPerEpoch.value[_activeValidatorsListPerEpoch.epochs[left-1]];
            }
        }
    }

    function removeValidator(address account) external onlyFromGovernance virtual override {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        // if the list doesn't exist for next epoch, copy over the last known list
        uint64 ne = _nextEpoch();
        if (_activeValidatorsListPerEpoch.value[ne].length == 0) {
            uint64 lastKnownEpoch = _activeValidatorsListPerEpoch.epochs[_activeValidatorsListPerEpoch.epochs.length - 1];
            _activeValidatorsListPerEpoch.value[ne] = _activeValidatorsListPerEpoch.value[lastKnownEpoch];
            _activeValidatorsListPerEpoch.epochs.push(ne);
        }

        // remove validator from array (since we remove only active it might not exist in the list)
        address[] storage avl = _activeValidatorsListPerEpoch.value[ne];
        for (uint256 i = 0; i < avl.length; i++) {
            if (avl[i] != validatorAddress) continue;
            delete _validatorAdditionTs[validatorAddress];
            avl[i] = avl[avl.length - 1];
            avl.pop();
            return;
        }
    }

    function _removeValidator(address account) internal {
        Validator memory validator = _validatorsMap[account];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        // revert if validator has delegators.
        // (next epoch because someone might've staked in current epoch and that's saved in next epoch's snapshot)
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        require(validatorSnapshot.totalDelegated == 0 && validatorSnapshot.totalRewards == 0, "hd"); // has delegator(s)
        // remove validator from active list if exists
        _removeValidatorFromActiveList(account);
        // remove from validators map
        delete _validatorOwners[validator.ownerAddress];
        delete _validatorsMap[account];
        // emit event about it
        emit ValidatorRemoved(account);
    }

    function activateValidator(address validator) external onlyFromGovernance virtual override {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(_validatorsMap[validatorAddress].status == ValidatorStatus.Pending, "np"); // not pending
        _addValidatorToActiveValidatorsList(validatorAddress, _nextEpoch());
        validator.status = ValidatorStatus.Active;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        _validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    function disableValidator(address validator) external onlyFromGovernance virtual override {
        _disableValidator(validator);
    }

    function _disableValidator(address validatorAddress) internal {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(_validatorsMap[validatorAddress].status == ValidatorStatus.Active, "na"); // not active
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        _validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    function changeValidatorCommissionRate(address validatorAddress, uint16 commissionRate) external {
        require(commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE, "bcr"); // bad commission rate
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        require(validator.ownerAddress == msg.sender, "oo"); // only owner
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        snapshot.commissionRate = commissionRate;
        _validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(validator.validatorAddress, validator.ownerAddress, uint8(validator.status), commissionRate);
    }

    function changeValidatorOwner(address validatorAddress, address newOwner) external override {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.ownerAddress == msg.sender, "oo"); // only owner
        require(_validatorOwners[newOwner] == address(0x00), "au"); // already used
        delete _validatorOwners[validator.ownerAddress];
        validator.ownerAddress = newOwner;
        _validatorOwners[newOwner] = validatorAddress;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        _validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(validator.validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    function isValidatorActive(address account) external override view returns (bool) {
        if (_validatorsMap[account].status != ValidatorStatus.Active) {
            return false;
        }
        address[] memory topValidators = getValidators();
        for (uint256 i = 0; i < topValidators.length; i++) {
            if (topValidators[i] == account) return true;
        }
        return false;
    }

    function isValidator(address account) external override view returns (bool) {
        return _validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function getValidators() public view override returns (address[] memory) {
        return _getValidators(_currentEpoch());
    }

    function getValidatorsAtEpoch(uint64 epoch) public view returns (address[] memory) {
        return _getValidators(epoch);
    }

    function _getValidators(uint64 epoch) internal view returns (address[] memory) {
        address[] memory avl = getActiveValidatorsList(epoch);
        uint256 n = avl.length;
        // we need to select k top validators out of n
        uint256 k = _chainConfigContract.getActiveValidatorsLength(epoch);
        if (k > n) {
            k = n;
        }
        uint256 i;
        uint256 j;
        uint256 nextValidator;
        uint256 currentMaxTotalDelegated;
        uint256 currentTotalDelegated;
        for (;i < k;) {
            nextValidator = i;

            Validator memory currentMax = _validatorsMap[avl[nextValidator]];
            currentMaxTotalDelegated = _totalDelegatedToValidator(currentMax, epoch);

            unchecked{j = i + 1;}
            for (;j < n;) {
                Validator memory current = _validatorsMap[avl[j]];
                currentTotalDelegated = _totalDelegatedToValidator(current, epoch);

                if (currentMaxTotalDelegated < currentTotalDelegated) {
                    nextValidator = j;
                    currentMax = current;
                    currentMaxTotalDelegated = currentTotalDelegated;
                } else if (currentMaxTotalDelegated == currentTotalDelegated) {
                    // if validators have the same total delegated amount, sort chronologically
                    if (_validatorAdditionTs[currentMax.validatorAddress] > _validatorAdditionTs[current.validatorAddress]) {
                        nextValidator = j;
                        currentMax = current;
                        currentMaxTotalDelegated = currentTotalDelegated;
                    }
                }

                unchecked { ++j; }
            }
            (avl[i], avl[nextValidator]) = (avl[nextValidator], avl[i]);

            unchecked { ++i; }
        }
        // this is to cut array to first k elements without copying
        assembly {
            mstore(avl, k)
        }
        return avl;
    }

    function deposit(address validatorAddress) external payable onlyFromCoinbaseOrTokenomicsOrStakingPool onlyZeroGasPrice virtual override {
        _depositFee(validatorAddress);
    }

    function _depositFee(address validatorAddress) internal {
        require(msg.value > 0, "diz"); // deposit is zero
        // make sure validator is active
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, _currentEpoch());
        currentSnapshot.totalRewards += uint96(msg.value);
        // save new validator status
        _validatorsMap[validatorAddress] = validator;
    }

    function getValidatorFee(address validatorAddress) external override view returns (uint256) {
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _currentEpoch());
    }

    function getValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override view returns (uint256) {
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, beforeEpoch);
    }

    function getPendingValidatorFee(address validatorAddress) external override view returns (uint256) {
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _nextEpoch());
    }

    function claimValidatorFee(address validatorAddress) external override {
        // make sure validator exists at least
        Validator storage validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        // claim all validator fees
        _claimValidatorOwnerRewards(validator, _currentEpoch());
    }

    function claimValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        // make sure validator exists at least
        Validator storage validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        // we disallow to claim rewards from future epochs
        require(beforeEpoch <= _currentEpoch());
        // claim all validator fees
        _claimValidatorOwnerRewards(validator, beforeEpoch);
    }

    function getDelegatorFee(address validatorAddress, address delegatorAddress) external override view returns (uint256) {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _currentEpoch(), true);
    }

    function getDelegatorFeeAtEpoch(address validatorAddress, address delegatorAddress, uint64 beforeEpoch) external override view returns (uint256) {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, beforeEpoch, true);
    }

    function getPendingDelegatorFee(address validatorAddress, address delegatorAddress) external override view returns (uint256) {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _nextEpoch(), true);
    }

    function claimDelegatorFee(address validatorAddress) external override {
        // claim all confirmed delegator fees including undelegates
        _transferDelegatorRewards(validatorAddress, msg.sender, _currentEpoch(), true, true);
    }

    function _calcAvailableForRedelegateAmount(uint256 claimableRewards) internal view returns (uint256 amountToStake, uint256 rewardsDust) {
        // for redelegate we must split amount into stake-able and dust
        amountToStake = _unpackCompact(_packCompact(claimableRewards));
        if (amountToStake < _chainConfigContract.getMinStakingAmount()) {
            return (0, claimableRewards);
        }
        // if we have dust remaining after re-stake then send it to user (we can't keep it in the contract)
        return (amountToStake, claimableRewards - amountToStake);
    }

    function calcAvailableForRedelegateAmount(address validator, address delegator) external override view returns (uint256 amountToStake, uint256 rewardsDust) {
        uint256 claimableRewards = _calcDelegatorRewardsAndPendingUndelegates(validator, delegator, _currentEpoch(), false);
        return _calcAvailableForRedelegateAmount(claimableRewards);
    }

    function claimPendingUndelegates(address validator) external override {
        // claim only pending undelegates
        _transferDelegatorRewards(validator, msg.sender, _currentEpoch(), false, true);
    }

    function redelegateDelegatorFee(address validator) external override returns (uint256 amountToStake, uint256 rewardsDust) {
        // claim rewards in the redelegate mode (check function code for more info)
        return _redelegateDelegatorRewards(validator, msg.sender, _currentEpoch());
    }

    function claimDelegatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        // make sure delegator can't claim future epochs
        require(beforeEpoch <= _currentEpoch());
        // claim all confirmed delegator fees including undelegates
        _transferDelegatorRewards(validatorAddress, msg.sender, beforeEpoch, true, true);
    }

    function _safeTransferWithGasLimit(address recipient, uint256 amount) internal {
        (bool success,) = recipient.call{value : amount, gas : 50_000}("");
        require(success, "tf"); // transfer failed
    }

    function _unsafeTransfer(address payable recipient, uint256 amount) internal {
        (bool success,) = payable(address(recipient)).call{value : amount}("");
        require(success, "tf"); // transfer failed
    }

    function slash(address validatorAddress) external onlyFromSlashingIndicator virtual override {
        _slashValidator(validatorAddress);
    }

    function _slashValidator(address validatorAddress) internal {
        // make sure validator exists
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "nf"); // not found
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        _validatorsMap[validatorAddress] = validator;
        // if validator has a lot of misses then put it in jail for 1 week (if epoch is 1 day)
        if (slashesCount >= _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore = _nextEpoch() + _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            _validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }
        // emit event
        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }

    function togglePause() external onlyFromGovernance virtual {
        _paused = !_paused;
        emit Paused(_paused);
    }

    function claimSystemFee(address validatorAddress, uint64 beforeEpoch) external {
        uint256 systemFee = 0;
        Validator storage validator = _validatorsMap[validatorAddress];
        uint64 claimAt = _systemFeeClaimedAt[validatorAddress];
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot storage validatorSnapshot = _validatorSnapshots[validator.validatorAddress][claimAt];
            (,,uint256 slashingFee) = _calcValidatorSnapshotEpochPayout(validatorSnapshot, claimAt);
            systemFee += slashingFee;
        }
        _systemFeeClaimedAt[validator.validatorAddress] = claimAt;
        // if we have system fee then pay it to treasury account
        _unsafeTransfer(payable(address(_systemRewardContract)), systemFee);
        emit SystemFeeClaimed(validator.validatorAddress, systemFee, beforeEpoch);
    }

    function _createOpDelegate(DelegationOpDelegate[] storage delegateQueue, uint64 epoch, uint112 amount) internal {
        delegateQueue.push(DelegationOpDelegate({epoch : epoch, amount : amount}));
    }

    function _packCompact(uint256 amount) internal pure returns (uint112) {
        return uint112(amount / BALANCE_COMPACT_PRECISION);
    }

    function _unpackCompact(uint112 amount) internal pure returns (uint256) {
        return uint256(amount * BALANCE_COMPACT_PRECISION);
    }
}
