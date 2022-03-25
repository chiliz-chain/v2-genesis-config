// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface IRuntimeUpgrade {

    function upgradeSystemSmartContract(address systemContractAddress, bytes calldata newByteCode, bytes calldata applyFunction) external;
}