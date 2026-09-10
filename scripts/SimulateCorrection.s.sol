// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

/// !!! NON-FUNCTIONAL SINCE COR-192 — kept as a historical record. !!!
///
/// This script etches `vm.getDeployedCode("StakingPool.sol:StakingPool")` and then sends the proposal's
/// `applyCorrections` calldata at it. That entry point was removed from the contract after the Spicy
/// proposal executed, so the etched bytecode no longer carries the selector and the call now fails the
/// `require(ok, ...)` below with an empty return. Restore the entry point on a scratch branch if this
/// dry-run ever needs to be reproduced.
///
/// @notice Dry-run of the Spicy state remediation: forks the live chain, installs the new StakingPool
///         bytecode (as the runtime upgrade would), executes the EXACT `applyFunction` calldata from the
///         proposal, and verifies the resulting state. Read-only — nothing is broadcast.
///
/// Run:  SPICY_RPC=<rpc> forge script scripts/SimulateCorrection.s.sol -vv
struct VP {
    address validatorAddress;
    uint256 sharesSupply;
    uint256 totalStakedAmount;
    uint256 dustRewards;
    uint256 pendingUnstake;
}

interface IPool {
    function getValidatorPoolWithoutRewards(address validator) external view returns (VP memory);
    function getShares(address validator, address staker) external view returns (uint256);
    function correctionsApplied() external view returns (bool);
}

interface IStk {
    function getValidatorDelegation(address validator, address delegator) external view returns (uint256, uint64);
}

contract SimulateCorrection is Script {
    address constant POOL = 0x0000000000000000000000000000000000007001;
    address constant STAKING = 0x0000000000000000000000000000000000001000;
    address constant RUNTIME_UPGRADE = 0x0000000000000000000000000000000000007004;

    function run() external {
        string memory rpc = vm.envOr("SPICY_RPC", string("https://spicy-rpc.chiliz.com"));
        vm.createSelectFork(rpc);

        bytes memory applyData = vm.parseBytes(vm.readFile("./scripts/corrections/apply-calldata.txt"));
        address[] memory vals = _validators();

        // snapshot pre-state
        uint256[] memory supplyBefore = new uint256[](vals.length);
        uint256[] memory stakedBefore = new uint256[](vals.length);
        for (uint256 i = 0; i < vals.length; i++) {
            VP memory p = IPool(POOL).getValidatorPoolWithoutRewards(vals[i]);
            supplyBefore[i] = p.sharesSupply;
            stakedBefore[i] = p.totalStakedAmount;
        }

        // install the new bytecode exactly as the runtime-upgrade EVM hook would, then execute the proposal's
        // applyFunction from the RuntimeUpgrade contract so `onlyFromRuntimeUpgrade` is satisfied.
        vm.etch(POOL, vm.getDeployedCode("StakingPool.sol:StakingPool"));
        vm.prank(RUNTIME_UPGRADE);
        (bool ok, bytes memory ret) = POOL.call(applyData);
        require(ok, string.concat("applyCorrections REVERTED: ", string(ret)));
        console.log("applyCorrections executed OK");
        require(IPool(POOL).correctionsApplied(), "corrections not marked applied");

        // verify post-state
        console.log("");
        console.log("validator                                    supply before -> after   | totalStaked == ledger");
        bool allGood = true;
        for (uint256 i = 0; i < vals.length; i++) {
            VP memory p = IPool(POOL).getValidatorPoolWithoutRewards(vals[i]);
            (uint256 ledger,) = IStk(STAKING).getValidatorDelegation(vals[i], POOL);
            // The pool is NOT expected to equal the ledger: it legitimately still counts open pre-fix
            // pendings that the ledger excluded at unstake (their pool-side decrement is deferred to
            // claim()). The invariant is therefore `totalStakedAmount >= ledger`, with the excess being
            // exactly those pendings. sharesSupply may move in either direction.
            bool stakedOk = p.totalStakedAmount >= ledger;
            allGood = allGood && stakedOk;
            console.log(vals[i]);
            console.log("   sharesSupply:", supplyBefore[i], "->", p.sharesSupply);
            console.log("   totalStaked :", stakedBefore[i], "->", p.totalStakedAmount);
            console.log("   >= ledger:", stakedOk);
            console.log("   excess over ledger (open pre-fix pendings):", p.totalStakedAmount - ledger);
        }

        // replay guard
        vm.prank(RUNTIME_UPGRADE);
        (bool ok2,) = POOL.call(applyData);
        require(!ok2, "replay should have reverted");
        console.log("");
        console.log("replay correctly rejected");
        console.log(allGood ? "SIMULATION PASSED" : "SIMULATION FAILED");
        require(allGood, "post-state check failed");
    }

    function _validators() internal pure returns (address[] memory a) {
        a = new address[](9);
        a[0] = 0xeC2e502f77c4811f2ef477397235976b1371FCd3;
        a[1] = 0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc;
        a[2] = 0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5;
        a[3] = 0x4dD74707f22b74EC872CA6AEB2a065E3d006B9d9;
        a[4] = 0xBD6D190548bbF5C6920a826dF063A970Bd18f307;
        a[5] = 0xF5109B3D711d360A84fD7351a634037572ef007D;
        a[6] = 0xbdBF08393b66130B4b243863150A265b2A5Df642;
        a[7] = 0x86f2BB174c450917A1b560c66525E64A1c9B6a04;
        a[8] = 0x20da691Ee91FAe686798294c819aaf0BaB6a101d;
    }
}
