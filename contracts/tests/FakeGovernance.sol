// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../Governance.sol";

contract FakeGovernance is Governance {
    constructor(bytes memory ctor) Governance(ctor) {
    }

    function activateProposerRegistry() external override {
        _activateProposerRegistry();
    }
    
    function addProposer(address proposer) external override {
        _addProposer(proposer);
    }
}