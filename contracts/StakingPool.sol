// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/IStaking.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/IInjector.sol";

import "./Injector.sol";
import "./Staking.sol";

import "@openzeppelin/contracts/utils/Address.sol";

contract StakingPool is InjectorContextHolder, IStakingPool {

    event Stake(address indexed validator, address indexed staker, uint256 amount);
    event Unstake(address indexed validator, address indexed staker, uint256 amount);
    event Claim(address indexed validator, address indexed staker, uint256 amount);



    struct PendingUnstake {
        uint256 amount;
        uint256 shares;
        uint64 epoch;
    }

    // validator pools (validator => pool)
    mapping(address => ValidatorPool) internal _validatorPools;
    // pending undelegates (validator => staker => pending unstake)
    mapping(address => mapping(address => PendingUnstake)) internal _pendingUnstakes;
    // allocated shares (validator => staker => shares)
    mapping(address => mapping(address => uint256)) internal _stakerShares;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) {
    }

    function ctor() external onlyInitializing {
    }

    function getStakedAmount(address validator, address staker) external view returns (uint256) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _stakerShares[validator][staker] * 1e18 / _calcRatio(validatorPool);
    }

    function getShares(address validator, address staker) external view returns (uint256) {
        return _stakerShares[validator][staker];
    }

    function getValidatorPool(address validator) external view returns (ValidatorPool memory) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        (uint256 amountToStake, uint256 dustRewards) = _calcUnclaimedDelegatorFee(validatorPool);
        validatorPool.totalStakedAmount += amountToStake;
        validatorPool.dustRewards += dustRewards;
        return validatorPool;
    }

    /// @notice Returns validator pool data without rewards being calculated.
    /// @param validator Validator address.
    function getValidatorPoolWithoutRewards(address validator) external view returns (ValidatorPool memory) {
        return _getValidatorPool(validator);
    }

    function getRatio(address validator) external view returns (uint256) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _calcRatio(validatorPool);
    }

    modifier advanceStakingRewards(address validator) {
        {
            ValidatorPool memory validatorPool = _getValidatorPool(validator);
            // claim rewards from staking contract
            (uint256 amountToStake, uint256 dustRewards) = _stakingContract.redelegateDelegatorFee(validatorPool.validatorAddress);
            // increase total accumulated rewards
            validatorPool.totalStakedAmount += amountToStake;
            validatorPool.dustRewards += dustRewards;
            // save validator pool changes
            _validatorPools[validator] = validatorPool;
        }
        _;
    }

    function _getValidatorPool(address validator) internal view returns (ValidatorPool memory) {
        ValidatorPool memory validatorPool = _validatorPools[validator];
        validatorPool.validatorAddress = validator;
        return validatorPool;
    }

    function _calcUnclaimedDelegatorFee(ValidatorPool memory validatorPool) internal view returns (uint256 amountToStake, uint256 dustRewards) {
        return _stakingContract.calcAvailableForRedelegateAmount(validatorPool.validatorAddress, address(this));
    }

    function _calcRatio(ValidatorPool memory validatorPool) internal view returns (uint256) {
        (uint256 stakedAmount, /*uint256 dustRewards*/) = _calcUnclaimedDelegatorFee(validatorPool);
        uint256 stakeWithRewards = validatorPool.totalStakedAmount + stakedAmount;
        if (stakeWithRewards == 0) {
            return 1e18;
        }
        // we're doing upper rounding here
        return (validatorPool.sharesSupply * 1e18 + stakeWithRewards - 1) / stakeWithRewards;
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.number / _chainConfigContract.getEpochBlockInterval());
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function stake(address validator) external payable advanceStakingRewards(validator) override {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        uint256 shares = msg.value * _calcRatio(validatorPool) / 1e18;
        // increase total accumulated shares for the staker
        _stakerShares[validator][msg.sender] += shares;
        // increase staking params for ratio calculation
        validatorPool.totalStakedAmount += msg.value;
        validatorPool.sharesSupply += shares;
        // save validator pool
        _validatorPools[validator] = validatorPool;
        // delegate these tokens to the staking contract
        _stakingContract.delegate{value : msg.value}(validator);
        // emit event
        emit Stake(validator, msg.sender, msg.value);
    }

    function unstake(address validator, uint256 amount) external advanceStakingRewards(validator) override {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        require(validatorPool.totalStakedAmount > 0, "StakingPool: nothing to unstake");
        // make sure user doesn't have pending undelegates (we don't support it here)
        require(_pendingUnstakes[validator][msg.sender].epoch == 0, "StakingPool: undelegate pending");
        // calculate shares and make sure user have enough balance
        uint256 shares = amount * _calcRatio(validatorPool) / 1e18;
        require(shares <= _stakerShares[validator][msg.sender], "StakingPool: not enough shares");
        // save new undelegate
        _pendingUnstakes[validator][msg.sender] = PendingUnstake({
        amount : amount,
        shares : shares,
        epoch : _nextEpoch() + _chainConfigContract.getUndelegatePeriod()
        });
        validatorPool.pendingUnstake += amount;
        _validatorPools[validator] = validatorPool;
        // undelegate
        _stakingContract.undelegate(validator, amount);
        // emit event
        emit Unstake(validator, msg.sender, amount);
    }

    function claimableRewards(address validator, address staker) external view override returns (uint256) {
        return _pendingUnstakes[validator][staker].amount;
    }

    function claim(address validator) external advanceStakingRewards(validator) override {
        PendingUnstake memory pendingUnstake = _pendingUnstakes[validator][msg.sender];
        uint256 amount = pendingUnstake.amount;
        uint256 shares = pendingUnstake.shares;
        // claim undelegate rewards
        _stakingContract.claimPendingUndelegates(validator);
        // make sure user have pending unstake
        require(pendingUnstake.epoch > 0, "StakingPool: nothing to claim");
        require(pendingUnstake.epoch <= _currentEpoch(), "StakingPool: not ready");
        // updates shares and validator pool params
        _stakerShares[validator][msg.sender] -= shares;
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        validatorPool.sharesSupply -= shares;
        validatorPool.totalStakedAmount -= amount;
        validatorPool.pendingUnstake -= amount;
        _validatorPools[validator] = validatorPool;
        // remove pending claim
        delete _pendingUnstakes[validator][msg.sender];
        // its safe to use call here (state is clear)
        require(address(this).balance >= amount, "StakingPool: not enough balance");
        Address.sendValue(payable(msg.sender), amount);
        // emit event
        emit Claim(validator, msg.sender, amount);
    }

    function manuallyClaimPendingUndelegates(address[] calldata validators) external {
        for (uint256 i = 0; i < validators.length; i++) {
            _stakingContract.claimPendingUndelegates(validators[i]);
        }
    }

    receive() external payable {
        require(address(msg.sender) == address(_stakingContract), "StakingPool: not a staking contract");
    }
}