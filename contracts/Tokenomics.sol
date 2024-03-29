// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./Injector.sol";

import "@openzeppelin/contracts/utils/Address.sol";

contract Tokenomics is ITokenomics, InjectorContextHolder {
    uint256 internal constant INITIAL_TOTAL_SUPPLY = 8888888888000000000000000000;

    struct State {
        uint256 totalSupply;
        uint256 totalIntroducedSupply;
        uint256 introducedSupply;
        uint256 inflationPct;
        uint16 shareStaking;
        uint16 shareSystem;
    }

    event Deposit(uint256 introducedSupply, uint256 newTotalSupply, uint256 inflationPct, address validator);
    event SharesUpdated(uint16 shareStaking, uint16 shareSystem);

    State internal _state;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) {}

    function ctor(uint16 shareStaking, uint16 shareSystem) external onlyInitializing {
        _state = State({
            totalSupply: INITIAL_TOTAL_SUPPLY,
            totalIntroducedSupply: 0,
            introducedSupply: 0,
            inflationPct: 0,
            shareStaking: shareStaking,
            shareSystem: shareSystem
        });
    }

    function getTotalSupply() external view override returns (uint256) {
        if (_state.totalSupply == 0) {
            return INITIAL_TOTAL_SUPPLY;
        } else {
            return _state.totalSupply;
        }
    }

    function getState() external view returns (State memory) {
        return _state;
    }

    function deposit(address validatorAddress, uint256 newTotalSupply, uint256 inflationPct)
        external
        payable
        virtual
        onlyFromCoinbase
        onlyZeroGasPrice
    {
        _deposit(validatorAddress, newTotalSupply, inflationPct);
    }

    function updateShares(uint16 shareStaking, uint16 shareSystem) external virtual onlyFromGovernance {
        _updateShares(shareStaking, shareSystem);
    }

    function _deposit(address validatorAddress, uint256 newTotalSupply, uint256 inflationPct) internal {
        require(msg.value > 0, "dizt"); // deposit is zero

        // Distribute
        uint256 stakingAmount = msg.value * _state.shareStaking / 10000;
        uint256 systemAmount = msg.value * _state.shareSystem / 10000;

        _stakingContract.deposit{value: stakingAmount}(validatorAddress);
        (bool sent, bytes memory data) = address(_systemRewardContract).call{value: systemAmount}("");
        require(sent, "sr"); // transfer to systemRewardsContract failed

        // Update state
        _state.inflationPct = inflationPct;
        _state.introducedSupply = msg.value;
        _state.totalIntroducedSupply += msg.value;
        _state.totalSupply = newTotalSupply;

        emit Deposit(msg.value, newTotalSupply, inflationPct, validatorAddress);
    }

    function _updateShares(uint16 shareStaking, uint16 shareSystem) internal {
        require(shareStaking + shareSystem == 10000, "is"); // invalid shares
        _state.shareStaking = shareStaking;
        _state.shareSystem = shareSystem;
        emit SharesUpdated(shareStaking, shareSystem);
    }
}
