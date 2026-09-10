// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// !!! SPENT — DO NOT RE-RUN AGAINST SPICY TO PRODUCE A NEW PROPOSAL !!!
///
/// The correction this script computes HAS ALREADY BEEN APPLIED on Spicy (chain 88882). This script
/// derives `delta = SUM(did_remove) - SUM(should_remove)` from Unstake/Claim logs starting at block 0
/// and knows nothing about the correction that has since landed on chain. Re-run today it therefore
/// re-derives the SAME pre-correction deltas and would propose applying them a SECOND time, which
/// would corrupt state again in the opposite direction. Deltas are not idempotent.
///
/// It is kept only as the auditable record of how the executed numbers were produced. The on-chain
/// replay guard is gone too: `applyCorrections` was removed from contracts/StakingPool.sol in COR-192.
///
/// @notice Computes the StakingPool share / totalStakedAmount corrections for Spicy as SIGNED DELTAS,
///         read-only, from chain data alone (logs + archive storage). No indexer or database involved.
///
/// METHOD — why this never reconstructs minted shares.
///
/// Shares leave a staker's balance only through a pending unstake, and every pending should be settled
/// exactly once. Writing `current` and `correct` in terms of the same mints:
///
///     current = Σ mints − Σ (removals the chain ACTUALLY applied)
///     correct = Σ mints − Σ (removals that SHOULD have applied)
///
/// the mints cancel:
///
///     delta = correct − current = Σ did_remove − Σ should_remove
///
/// So the correction is computable from the pendings alone. An earlier version of this script instead
/// reconstructed mints as the `_stakerShares` delta across each Stake block, which was wrong twice over:
/// a pair can emit many Stake events in ONE block (observed: 40 in block 29599271), and the per-event loop
/// re-added that block's delta once per event — 479 such over-counts across Spicy, inflating 8 of the 15
/// deltas. A block holding both a Stake and a Claim nets the two, so the removal was then subtracted twice.
/// Neither failure mode exists here: Stake events are not read at all.
///
/// PER PENDING, with S = pendingUnstake.shares and A = pendingUnstake.amount recorded at the unstake block U,
/// and C = the block of the claim that settled it (0 if still open):
///
///     did_remove    = [chain decremented at U] + [chain decremented at C]      (0, 1 or 2)
///     should_remove = 1 once the removal is due and that moment has passed, else 0
///     delta        += (did_remove − should_remove) × S        per (validator, staker)
///     poolDelta    += (did_remove − should_remove) × A        per validator
///
/// `did_remove` follows the contract's own guards across the four accounting eras (all four validated
/// against on-chain getShares deltas — see `_claimDecremented`). `should_remove` is 1 for any post-fix
/// unstake (removal due at U, already passed) and for any settled pre-fix pending (removal due at C).
/// A pre-fix pending still open is 0/0: its shares legitimately remain until it is claimed.
///
/// Shares and amount move together inside a single `if` in both unstake() and claim(), so one classification
/// drives both outputs. sharesSupply is not emitted: applyCorrections moves it by exactly the share delta.
///
/// CROSS-CHECKS (both on by default):
///   - VERIFY_OBSERVED: re-derives each decrement from the observed `_stakerShares` delta around the block
///     and reports any disagreement with the era model. Blocks holding other activity for the same pair can
///     mask a decrement, so a disagreement is reported, not fatal.
///   - the per-validator pool delta is additionally derived from the Staking delegation ledger
///     (`delegated + still-open pre-fix pendings`) and the two are compared.
///
/// Run: SPICY_RPC=<archive> forge script scripts/ReconstructStakingPoolState.s.sol -vv
/// Env: SPICY_RPC, STAKING_POOL (0x..7001), STAKING (0x..1000), FROM_BLOCK (0), TO_BLOCK (head),
///      CHUNK (500000), OUT_SHARES (./scripts/corrections/correct-shares.txt),
///      OUT_POOLS (./scripts/corrections/correct-pools.txt),
///      VERIFY_OBSERVED (true)
struct VP {
    address validatorAddress;
    uint256 sharesSupply;
    uint256 totalStakedAmount;
    uint256 dustRewards;
    uint256 pendingUnstake;
}

interface IPool {
    function getShares(address validator, address staker) external view returns (uint256);
    function getValidatorPoolWithoutRewards(address validator) external view returns (VP memory);
}

interface IStk {
    function getValidatorDelegation(address validator, address delegator) external view returns (uint256, uint64);
}

contract ReconstructStakingPoolState is Script {
    bytes32 constant UNSTAKE_TOPIC0 = 0x390b1276974b9463e5d66ab10df69b6f3d7b930eb066a0e66df327edd2cc811c;
    bytes32 constant CLAIM_TOPIC0 = 0x70eb43c4a8ae8c40502dcf22436c509c28d6ff421cf07c491be56984bd987068;

    /// @dev Era 1 — Sherlock #125. From here unstake() decrements; before it the decrement was at claim().
    uint256 constant FIRST_FIX_BLOCK = 30523502;
    /// @dev Era 2 — 5.0.x. claim() guard becomes `!A || B` (the double-decrement bug).
    uint256 constant SECOND_FIX_BLOCK = 35761754;
    /// @dev Era 3 — COR-110. claim() guard becomes `!A && !B`.
    uint256 constant THIRD_FIX_BLOCK = 36824812;

    uint256 constant SLOT_PENDING_UNSTAKES = 103; // PendingUnstake{amount@+0, shares@+1, epoch@+2}
    uint256 constant SLOT_STAKER_SHARES = 104;
    uint256 constant SLOT_UNSTAKED_POST_FIX = 105; // B: _unstakedPostSherlockSupplyFixUpdate[staker]
    uint256 constant SLOT_DECREMENTED = 106; // A: decrementedSharesAtUnstake[validator][staker]

    address[] internal uv;
    address[] internal us;
    mapping(bytes32 => bool) internal seenPair;
    mapping(bytes32 => uint64[]) internal unstakeBlocksByPair;
    mapping(bytes32 => uint64[]) internal claimBlocksByPair;

    address[] internal vals;
    mapping(address => bool) internal seenVal;
    mapping(address => int256) internal poolDeltaOf;
    mapping(address => uint256) internal openPreFixAmount;

    address[] internal outV;
    address[] internal outS;
    int256[] internal outDelta;

    uint256 internal unstakeCount;
    uint256 internal claimCount;
    uint256 internal openPreFixPendings;
    uint256 internal doubleRemoved;
    uint256 internal neverRemoved;
    uint256 internal clampedCount;
    uint256 internal clampedShortfall;
    uint256 internal observedMismatch;
    uint256 internal minBlock = type(uint256).max;

    bool internal _verifyObserved;
    string internal _rpc;
    address internal _pool;
    address internal _staking;

    function run() external {
        _rpc = vm.envOr("SPICY_RPC", string("https://spicy-rpc.chiliz.com"));
        _pool = vm.envOr("STAKING_POOL", 0x0000000000000000000000000000000000007001);
        _staking = vm.envOr("STAKING", 0x0000000000000000000000000000000000001000);
        _verifyObserved = vm.envOr("VERIFY_OBSERVED", true);
        uint256 fromBlock = vm.envOr("FROM_BLOCK", uint256(0));
        uint256 chunk = vm.envOr("CHUNK", uint256(500000));
        string memory outShares = vm.envOr("OUT_SHARES", string("./scripts/corrections/correct-shares.txt"));
        string memory outPools = vm.envOr("OUT_POOLS", string("./scripts/corrections/correct-pools.txt"));

        vm.createSelectFork(_rpc); // head, for direct contract calls
        uint256 toBlock = vm.envOr("TO_BLOCK", block.number);

        _fetchAndIndex(fromBlock, toBlock, chunk);
        console.log("unstake events:", unstakeCount);
        console.log("claim events:", claimCount);
        console.log("pairs with at least one unstake:", uv.length);
        console.log("(pairs that never unstaked cannot have lost shares and are not read at all)");

        require(
            minBlock == type(uint256).max || _storageAt(bytes32(uint256(2)), minBlock) != 0,
            "Reconstruct: slot2==0 at oldest event block -- need an archive RPC"
        );

        for (uint256 i = 0; i < uv.length; i++) {
            _reconstructPair(uv[i], us[i]);
        }

        _report(outShares, outPools);
    }

    // ------------------------------------------------------------------ reconstruction

    function _reconstructPair(address v, address s) internal {
        bytes32 key = keccak256(abi.encode(v, s));
        uint64[] storage ubs = unstakeBlocksByPair[key];

        int256 shareDelta = 0;
        int256 stakedDelta = 0;

        for (uint256 j = 0; j < ubs.length; j++) {
            (int256 dShares, int256 dStaked) = _classifyPending(v, s, key, uint256(ubs[j]));
            shareDelta += dShares;
            stakedDelta += dStaked;
        }

        if (!seenVal[v]) {
            seenVal[v] = true;
            vals.push(v);
        }

        // A delta that would drive the balance below zero means the staker withdrew more than they ever
        // minted — the excess CHZ is already gone, a realized pool loss. Zero is the only representable
        // correct balance, so clamp and report rather than emitting a delta applyCorrections would clamp
        // silently.
        //
        // The POOL delta is deliberately NOT clamped alongside it. totalStakedAmount is the pool's own
        // accounting of CHZ that really did leave, so it must reflect every wrong decrement in full even
        // where the staker's share balance cannot absorb the matching cut — clamping it would re-introduce
        // the overstatement this correction exists to remove. The ledger cross-check confirms this: it is
        // derived independently and does not clamp, and it agrees exactly on every validator holding a
        // clamped staker.
        if (shareDelta < 0) {
            uint256 current = IPool(_pool).getShares(v, s);
            if (uint256(-shareDelta) > current) {
                uint256 excess = uint256(-shareDelta) - current;
                clampedCount++;
                clampedShortfall += excess;
                console.log("OVER-WITHDRAWN (clamped to 0) validator", v);
                console.log("  staker", s);
                console.log("  shortfall shares:", excess);
                shareDelta = -int256(current);
            }
        }

        poolDeltaOf[v] += stakedDelta;

        if (shareDelta != 0) {
            outV.push(v);
            outS.push(s);
            outDelta.push(shareDelta);
        }
    }

    /// @dev Classifies one pending and returns its signed (share, amount) contribution to the pair's delta.
    ///      Split out of `_reconstructPair` purely to keep the stack shallow enough for solc 0.8.17.
    function _classifyPending(address v, address s, bytes32 key, uint256 U)
        internal
        returns (int256 dShares, int256 dStaked)
    {
        bytes32 amountSlot = keccak256(abi.encode(s, keccak256(abi.encode(v, SLOT_PENDING_UNSTAKES))));
        uint256 C = _matchingClaimBlock(key, uint64(U));

        bool didAtUnstake = U >= FIRST_FIX_BLOCK;
        bool didAtClaim = C != 0 && _claimDecremented(v, s, C);

        int256 did = (didAtUnstake ? int256(1) : int256(0)) + (didAtClaim ? int256(1) : int256(0));
        // The removal is due at the unstake once era 1 is live, otherwise at the claim that settles it.
        // A pre-fix pending with no claim yet is not due, so it is neither owed nor wrongly applied.
        int256 should = (didAtUnstake || C != 0) ? int256(1) : int256(0);

        if (should == 0) {
            openPreFixPendings++;
            openPreFixAmount[v] += _storageAt(amountSlot, U);
        }
        if (did == 2) doubleRemoved++;
        if (did == 0 && should == 1) neverRemoved++;

        if (_verifyObserved) {
            _checkObserved(v, s, U, C, didAtUnstake, didAtClaim);
        }

        int256 net = did - should;
        if (net == 0) return (0, 0);

        dShares = net * int256(_storageAt(bytes32(uint256(amountSlot) + 1), U));
        dStaked = net * int256(_storageAt(amountSlot, U));
    }

    /// @dev Replays the contract's claim() guard for the era containing block C. Flags A and B are read at
    ///      C-1 because claim() reads them before writing anything. Validated against the observed on-chain
    ///      getShares delta of every claim at or after the era-3 upgrade: the era-3 form `!A && !B` matches
    ///      all of them, while the era-2 form `!A || B` disagrees on 8.
    function _claimDecremented(address v, address s, uint256 C) internal returns (bool) {
        uint256 at = C - 1;
        bool B = _storageAt(keccak256(abi.encode(s, bytes32(uint256(SLOT_UNSTAKED_POST_FIX)))), at) != 0;

        if (C < SECOND_FIX_BLOCK) {
            // era 0/1: `if (!_unstakedPostSherlockSupplyFixUpdate[msg.sender])`
            // (in era 0 the flag cannot be set, so this is the unconditional decrement)
            return !B;
        }

        bool A = _storageAt(keccak256(abi.encode(s, keccak256(abi.encode(v, SLOT_DECREMENTED)))), at) != 0;

        if (C >= THIRD_FIX_BLOCK) {
            return !A && !B; // era 3 (COR-110)
        }
        return !A || B; // era 2 — the double-decrement bug
    }

    /// @dev Independent check: derive each decrement from the observed `_stakerShares` movement instead of
    ///      from the era model. Other activity for the same pair in the same block can mask a decrement
    ///      (one such block exists on Spicy), so a disagreement is reported rather than thrown.
    function _checkObserved(address v, address s, uint256 U, uint256 C, bool modelU, bool modelC) internal {
        bytes32 slot = keccak256(abi.encode(s, keccak256(abi.encode(v, SLOT_STAKER_SHARES))));

        bool obsU = _storageAt(slot, U) < _storageAt(slot, U - 1);
        if (obsU != modelU) {
            observedMismatch++;
            console.log("OBSERVED MISMATCH at unstake block", U);
            console.log("  validator", v);
            console.log("  staker   ", s);
        }
        if (C != 0) {
            bool obsC = _storageAt(slot, C) < _storageAt(slot, C - 1);
            if (obsC != modelC) {
                observedMismatch++;
                console.log("OBSERVED MISMATCH at claim block", C);
                console.log("  validator", v);
                console.log("  staker   ", s);
            }
        }
    }

    /// @dev Block of the claim that settled the pending opened at `unstakeBlock`, or 0 if still open.
    ///      unstake() requires `_pendingUnstakes[v][s].epoch == 0`, so pendings never overlap and the
    ///      settling claim is the one falling between this unstake and the next.
    function _matchingClaimBlock(bytes32 key, uint64 unstakeBlock) internal view returns (uint256) {
        uint64[] storage ubs = unstakeBlocksByPair[key];
        uint64 nextUnstake = type(uint64).max;
        for (uint256 k = 0; k < ubs.length; k++) {
            if (ubs[k] > unstakeBlock && ubs[k] < nextUnstake) nextUnstake = ubs[k];
        }
        uint64[] storage cbs = claimBlocksByPair[key];
        for (uint256 k = 0; k < cbs.length; k++) {
            if (cbs[k] > unstakeBlock && cbs[k] < nextUnstake) return uint256(cbs[k]);
        }
        return 0;
    }

    // ------------------------------------------------------------------ raw reads

    function _storageAt(bytes32 slot, uint256 blk) internal returns (uint256 x) {
        string memory params =
            string.concat("[\"", vm.toString(_pool), "\",\"", vm.toString(slot), "\",\"", _hexQ(blk), "\"]");
        bytes memory raw = vm.rpc(_rpc, "eth_getStorageAt", params);
        require(raw.length == 32, "Reconstruct: unexpected eth_getStorageAt result length");
        assembly {
            x := mload(add(raw, 0x20))
        }
    }

    // ------------------------------------------------------------------ logs / index

    function _fetchAndIndex(uint256 fromBlock, uint256 toBlock, uint256 chunk) internal {
        bytes32[] memory unstakeTopics = new bytes32[](1);
        unstakeTopics[0] = UNSTAKE_TOPIC0;
        bytes32[] memory claimTopics = new bytes32[](1);
        claimTopics[0] = CLAIM_TOPIC0;

        for (uint256 start = fromBlock; start <= toBlock; start += chunk) {
            uint256 end = start + chunk - 1;
            if (end > toBlock) end = toBlock;

            Vm.EthGetLogs[] memory ul = vm.eth_getLogs(start, end, _pool, unstakeTopics);
            for (uint256 j = 0; j < ul.length; j++) {
                _indexEvent(true, ul[j]);
            }
            Vm.EthGetLogs[] memory cl = vm.eth_getLogs(start, end, _pool, claimTopics);
            for (uint256 j = 0; j < cl.length; j++) {
                _indexEvent(false, cl[j]);
            }
        }
    }

    function _indexEvent(bool isUnstake, Vm.EthGetLogs memory lg) internal {
        address v = address(uint160(uint256(lg.topics[1])));
        address s = address(uint160(uint256(lg.topics[2])));
        bytes32 key = keccak256(abi.encode(v, s));

        // Pairs are enumerated from unstakes only: with no pending there is nothing to settle and the
        // delta is necessarily zero. A claim always follows an unstake of the same pair.
        if (isUnstake && !seenPair[key]) {
            seenPair[key] = true;
            uv.push(v);
            us.push(s);
        }
        if (isUnstake) {
            unstakeBlocksByPair[key].push(lg.blockNumber);
            unstakeCount++;
        } else {
            claimBlocksByPair[key].push(lg.blockNumber);
            claimCount++;
        }
        if (lg.blockNumber < minBlock) minBlock = lg.blockNumber;
    }

    // ------------------------------------------------------------------ report

    function _report(string memory outShares, string memory outPools) internal {
        string memory a = "[";
        for (uint256 i = 0; i < outV.length; i++) {
            a = string.concat(
                a,
                i == 0 ? "" : ",",
                "(",
                vm.toString(outV[i]),
                ",",
                vm.toString(outS[i]),
                ",",
                vm.toString(outDelta[i]),
                ")"
            );
        }
        vm.writeFile(outShares, string.concat(a, "]"));

        string memory b = "[";
        uint256 n;
        uint256 ledgerAgree;
        uint256 ledgerDisagree;
        for (uint256 i = 0; i < vals.length; i++) {
            address v = vals[i];
            int256 d = poolDeltaOf[v];

            // Independent derivation: the pool should hold the delegation ledger plus the pendings the
            // ledger already dropped at unstake but whose pool-side decrement is deferred to claim().
            VP memory p = IPool(_pool).getValidatorPoolWithoutRewards(v);
            (uint256 delegated,) = IStk(_staking).getValidatorDelegation(v, _pool);
            int256 fromLedger = int256(delegated + openPreFixAmount[v]) - int256(p.totalStakedAmount);

            console.log("validator", v);
            console.log("  totalStaked delta  (pendings):", vm.toString(d));
            console.log("  totalStaked delta  (ledger)  :", vm.toString(fromLedger));
            if (d == fromLedger) ledgerAgree++;
            else {
                ledgerDisagree++;
                console.log("  ^ CROSS-CHECK DISAGREEMENT");
            }

            if (d == 0) continue;
            b = string.concat(b, n == 0 ? "" : ",", "(", vm.toString(v), ",", vm.toString(d), ")");
            n++;
        }
        vm.writeFile(outPools, string.concat(b, "]"));

        console.log("");
        console.log("=== SUMMARY ===");
        console.log("pairs with an unstake:", uv.length);
        console.log("pendings double-removed (shares owed back):", doubleRemoved);
        console.log("pendings never removed (shares to reclaim):", neverRemoved);
        console.log("open pre-fix pendings left intact:", openPreFixPendings);
        console.log("stakers needing a share delta:", outV.length);
        console.log("validators needing a totalStaked delta:", n);
        console.log("over-withdrawn stakers (clamped to 0):", clampedCount);
        console.log("  total shortfall shares:", clampedShortfall);
        console.log("pool cross-check: agree / disagree:", ledgerAgree, ledgerDisagree);
        console.log("observed-vs-model mismatches:", observedMismatch);
        console.log("share deltas written to:", outShares);
        console.log("pool deltas written to:", outPools);
    }

    // ------------------------------------------------------------------ misc

    function _hexQ(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        bytes memory buf;
        while (v > 0) {
            uint8 d = uint8(v & 0xf);
            buf = abi.encodePacked(bytes1(d < 10 ? 48 + d : 87 + d), buf);
            v >>= 4;
        }
        return string(abi.encodePacked("0x", buf));
    }
}
