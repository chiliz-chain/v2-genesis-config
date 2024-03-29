// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface ITokenomics {
    function getTotalSupply() external view returns (uint256);
    function deposit(address validatorAddress, uint256 newTotalSupply, uint256 inflationPct) external payable;
}