// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Governance} from "../contracts/Governance.sol";

contract Propose is Script {
    function run() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);

        targets[0] = 0x0000000000000000000000000000000000007004; // RuntimeUpgrade
        targets[1] = 0x0000000000000000000000000000000000007004;
        calldatas[0] = abi.encodeWithSignature(
            "upgradeSystemSmartContract(address,bytes,bytes)",
            0x0000000000000000000000000000000000007003,
            vm.getDeployedCode("ChainConfig.sol:ChainConfig"),
            ""
        );
        calldatas[1] = abi.encodeWithSignature(
            "upgradeSystemSmartContract(address,bytes,bytes)",
            0x0000000000000000000000000000000000001000,
            vm.getDeployedCode("Staking.sol:Staking"),
            ""
        );

        vm.startBroadcast();
        uint256 proposalId = Governance(payable(0x0000000000000000000000000000000000007002)).proposeWithCustomVotingPeriod(
            targets,
            values,
            calldatas,
            vm.envString("PROPOSAL_DESCRIPTION"),
            vm.envUint("VOTING_PERIOD")
        );
        vm.stopBroadcast();
        console.log("Proposal ID:", proposalId);
    }
}

contract CastVote is Script {
    function run() public {
        vm.startBroadcast();
        Governance(payable(0x0000000000000000000000000000000000007002)).castVote(vm.envUint("PROPOSAL_ID"), 1);
        vm.stopBroadcast();
    }
}

contract ProposalState is Script {
    mapping(uint8 => string) internal stateNames;
    function run() public {
        stateNames[0] = "Pending";
        stateNames[1] = "Active";
        stateNames[2] = "Canceled";
        stateNames[3] = "Defeated";
        stateNames[4] = "Succeeded";
        stateNames[5] = "Queued";
        stateNames[6] = "Expired";
        stateNames[7] = "Executed";
        uint8 state = uint8(Governance(payable(0x0000000000000000000000000000000000007002)).state(vm.envUint("PROPOSAL_ID")));
        console.log("Proposal State:", stateNames[state]);
    }
}

contract Execute is Script {
    function run() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        string memory description = vm.envString("PROPOSAL_DESCRIPTION");
        bytes32 descriptionHash = keccak256(abi.encodePacked(description));

        targets[0] = 0x0000000000000000000000000000000000007004;
        targets[1] = 0x0000000000000000000000000000000000007004;
        calldatas[0] = abi.encodeWithSignature(
            "upgradeSystemSmartContract(address,bytes,bytes)",
            0x0000000000000000000000000000000000007003,
            vm.getDeployedCode("ChainConfig.sol:ChainConfig"),
            ""
        );
        calldatas[1] = abi.encodeWithSignature(
            "upgradeSystemSmartContract(address,bytes,bytes)",
            0x0000000000000000000000000000000000001000,
            vm.getDeployedCode("Staking.sol:Staking"),
            ""
        );

        vm.startBroadcast();
        Governance(payable(0x0000000000000000000000000000000000007002)).execute(targets, values, calldatas, descriptionHash);
        vm.stopBroadcast();
    }
}
