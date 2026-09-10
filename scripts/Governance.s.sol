// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Governance} from "../contracts/Governance.sol";
import {IGovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/IGovernorUpgradeable.sol";

/// @notice Propose + vote + execute in a single run
///
/// Expects a JSON file (path via env `PROPOSAL_FILE`) with:
/// {
///   "description": "My proposal",
///   "votingPeriod": 10,
///   "targets": ["0x...","0x..."],
///   "values": [0,0],
///   "calldatas": ["0x....","0x...."],
///   "etchOverrides": false,
///   "etchAddresses": ["0x0000000000000000000000000000000000007003"],
///   "etchArtifacts": ["ChainConfigOverride.sol:ChainConfigOverride"]
/// }
///
/// When `etchOverrides` is true: if `etchAddresses` / `etchArtifacts` are present, the script
/// pairs them by index and calls `vm.etch` for each, in BOTH Propose and Execute.
///
/// Set it for any proposal whose calldata calls a function that does not exist in the currently deployed
/// bytecode — a runtime upgrade that swaps a system contract and then calls a new migration function on it.
/// Without it, Execute's local dry run reverts with `RuntimeUpgrade: migration failed` and never broadcasts.
/// See `_applyEtchOverrides` for why.
///
/// Optional env flags:
/// - `AUTO_ADVANCE=true` then either:
///   - default: `vm.roll(...)` (local anvil / fork only), or
///   - `RPC_WAIT=true`: wall-clock `vm.sleep` + poll on-chain `state(proposalId)` (real RPC; no `vm.roll`).
/// - `GOVERNANCE_POLL_INTERVAL_MS` (default 3000): ms between RPC polls when `RPC_WAIT=true`.
/// - `GOVERNANCE_POLL_MAX_ATTEMPTS` (default 500): max polls before revert when `RPC_WAIT=true`.

contract GovernanceScript is Script {
    using stdJson for string;

    address constant governanceAddr = 0x0000000000000000000000000000000000007002;
    string public description;
    uint256 public votingPeriod;
    address[] public targets;
    uint256[] public values;
    string[] public calldataHex;
    bytes[] public calldatas;
    bool public etchOverrides;
    address[] public etchAddrs;
    string[] public etchArts;

    function setUp() public {
        string memory proposalPath = vm.envString("PROPOSAL_FILE");
        string memory json = vm.readFile(proposalPath);

        description = json.readString(".description");
        votingPeriod = json.readUint(".votingPeriod");

        targets = json.readAddressArray(".targets");
        values = json.readUintArray(".values");
        calldataHex = json.readStringArray(".calldatas");
        calldatas = new bytes[](calldataHex.length);
        for (uint256 i = 0; i < calldataHex.length; i++) {
            calldatas[i] = vm.parseBytes(calldataHex[i]);
        }

        etchOverrides = json.readBool(".etchOverrides");
        if (etchOverrides) {
            // Bypass Foundry's local simulation step for system contracts
            bool hasEtchAddresses = json.keyExists(".etchAddresses");
            bool hasEtchArtifacts = json.keyExists(".etchArtifacts");
            require(
                hasEtchAddresses == hasEtchArtifacts,
                "etchAddresses and etchArtifacts must both be set or both omitted"
            );

            etchAddrs = json.readAddressArray(".etchAddresses");
            etchArts = json.readStringArray(".etchArtifacts");
            require(etchAddrs.length == etchArts.length, "etchAddresses/etchArtifacts length mismatch");
            require(etchAddrs.length > 0, "empty etchAddresses");
        }
    }

    /// @dev Installs the post-upgrade bytecode locally so Foundry's dry run matches what the chain will do.
    ///
    ///      A runtime-upgrade proposal replaces a system contract and then immediately calls a function that
    ///      only exists in the NEW bytecode. On-chain that works, because the EVM hook at `0x…7f01` swaps the
    ///      code first. Foundry cannot run that hook: it is native client code with no bytecode, so a call to
    ///      it on a fork silently succeeds and swaps nothing. The follow-up call then hits the OLD contract,
    ///      finds no such selector and reverts — `RuntimeUpgrade: migration failed` — and the transaction is
    ///      never broadcast even though it would have succeeded on-chain.
    ///
    ///      Etching only affects the local fork used for the dry run. The broadcast transaction is unchanged
    ///      and the real hook performs the real swap.
    function _applyEtchOverrides() internal {
        if (!etchOverrides) return;
        for (uint256 i = 0; i < etchAddrs.length; i++) {
            vm.etch(etchAddrs[i], vm.getDeployedCode(etchArts[i]));
        }
    }
}

contract Propose is GovernanceScript {
    function run() public {
        _applyEtchOverrides();

        vm.startBroadcast();
        uint256 proposalId = Governance(payable(governanceAddr)).proposeWithCustomVotingPeriod(
            targets,
            values,
            calldatas,
            description,
            votingPeriod
        );
        vm.stopBroadcast();

        console.log("Proposal ID:", proposalId);
    }
}

contract Vote is Script {
    function run() public {
        vm.startBroadcast();
        Governance(payable(0x0000000000000000000000000000000000007002)).castVote(vm.envUint("PROPOSAL_ID") , 1);
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

contract Execute is GovernanceScript {
    function _waitForProposalState(address governanceAddr, uint256 proposalId, IGovernorUpgradeable.ProposalState want)
        internal
    {
        uint256 maxAttempts = vm.envOr("GOVERNANCE_POLL_MAX_ATTEMPTS", uint256(500));
        uint256 intervalMs = vm.envOr("GOVERNANCE_POLL_INTERVAL_MS", uint256(3000));

        for (uint256 i = 0; i < maxAttempts; i++) {
            IGovernorUpgradeable.ProposalState s = Governance(payable(governanceAddr)).state(proposalId);
            if (s == want) {
                return;
            }
            console.log("Waiting for proposal to succeed...");
            vm.sleep(intervalMs);
        }
        revert("timeout waiting for proposal state");
    }

    function run() public {
        uint256 proposalId = vm.envUint("PROPOSAL_ID");
        bool rpcWait = vm.envOr("RPC_WAIT", false);

        if (rpcWait) {
            _waitForProposalState(governanceAddr, proposalId, IGovernorUpgradeable.ProposalState.Succeeded);
        } else {
            vm.roll(block.number + votingPeriod + 1);
        }

        bytes32 descriptionHash = keccak256(abi.encodePacked(description));

        // Execute is where this actually matters: it is the only step that RUNS the proposal calldata, so it
        // is the step whose dry run hits the not-yet-deployed bytecode. (Propose merely records the calldata.)
        _applyEtchOverrides();

        vm.startBroadcast();
        Governance(payable(governanceAddr)).execute(targets, values, calldatas, descriptionHash);
        vm.stopBroadcast();

        console.log("Executed proposal:", proposalId);
    }
}