// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

contract TestChainNumber {

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}