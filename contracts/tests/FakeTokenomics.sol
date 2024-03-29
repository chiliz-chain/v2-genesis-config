// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../Tokenomics.sol";

contract FakeTokenomics is Tokenomics {
    constructor(bytes memory ctor) Tokenomics(ctor) {
    }

    function updateShares(uint16 shareStaking, uint16 shareSystem) external override {
        _updateShares(shareStaking, shareSystem);
    }

    function deposit(address validatorAddress, uint256 newTotalSupply, uint256 inflationPct) external payable virtual override {
        _deposit(validatorAddress, newTotalSupply, inflationPct);
    }
}