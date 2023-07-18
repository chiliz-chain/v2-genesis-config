// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

contract TestDeployerFlipper {

    bool public value;

    function flip() external {
        value = !value;
    }
}

contract TestDeployerFactory {

    function newFlipper() external returns (address) {
        TestDeployerFlipper impl = new TestDeployerFlipper();
        return address(impl);
    }
}