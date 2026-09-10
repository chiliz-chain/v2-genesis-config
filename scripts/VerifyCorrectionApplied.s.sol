// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Post-execution verification for the COR-111 StakingPool correction.
///         Read-only. Nothing is broadcast.
///
///         NOTE (COR-192): `applyCorrections` was removed from contracts/StakingPool.sol after the
///         proposal executed, so check #1's default expectation — the codehash of the bytecode THIS
///         branch builds — no longer matches Spicy's live code. Run it with the executed bytecode
///         pinned explicitly:
///
///           EXPECTED_CODEHASH=0x8576fbd781a739ce4399d1bdeeae1ea0d3cdec75875bf03eb225a7a54aff59c2 \
///             forge script scripts/VerifyCorrectionApplied.s.sol -vv
///
/// Confirms, against the live chain, that the governance proposal did exactly what it promised and nothing
/// else. Every delta is checked as `after - before` across the execution block, so this catches a partial
/// apply, a double apply, and a correction that landed differently from the one proposed.
///
/// Run after the proposal executes:
///     EXEC_BLOCK=<block the proposal executed in> \
///     SPICY_RPC=<archive rpc> forge script scripts/VerifyCorrectionApplied.s.sol -vv
///
/// Env: EXEC_BLOCK (required), SPICY_RPC, STAKING_POOL, STAKING,
///      EXPECTED_CODEHASH (default = the hash of the bytecode this branch builds),
///      CHECK_CLAIMS (default true — simulates claim() for every still-open pending)
struct VP {
    address validatorAddress;
    uint256 sharesSupply;
    uint256 totalStakedAmount;
    uint256 dustRewards;
    uint256 pendingUnstake;
}

interface IPool {
    function correctionsApplied() external view returns (bool);
    function getShares(address v, address s) external view returns (uint256);
    function getStakedAmount(address v, address s) external view returns (uint256);
    function getValidatorPoolWithoutRewards(address v) external view returns (VP memory);
}

interface IStk {
    function getValidatorDelegation(address v, address d) external view returns (uint256, uint64);
}

contract VerifyCorrectionApplied is Script {
    bytes32 constant SHARES_CORRECTED = keccak256("SharesCorrected(address,address,uint256,uint256)");
    bytes32 constant UNSTAKE_TOPIC0 = 0x390b1276974b9463e5d66ab10df69b6f3d7b930eb066a0e66df327edd2cc811c;
    bytes32 constant CLAIM_TOPIC0 = 0x70eb43c4a8ae8c40502dcf22436c509c28d6ff421cf07c491be56984bd987068;
    uint256 constant SLOT_STAKER_SHARES = 104;
    uint256 constant SLOT_PENDING_UNSTAKES = 103; // PendingUnstake{amount@0, shares@1, epoch@2}
    uint256 constant SLOT_VALIDATOR_POOLS = 102; // ValidatorPool{addr@0, sharesSupply@1, totalStaked@2, dust@3, pending@4}

    string internal _rpc;
    address internal _pool;
    address internal _staking;
    uint256 internal _execBlock;
    uint256 internal _failures;
    uint256 internal _warnings;

    // event index (storage, not memory: the matching loops overflow the stack otherwise)
    address[] internal uV;
    address[] internal uS;
    uint64[] internal uB;
    address[] internal cV;
    address[] internal cS;
    uint64[] internal cB;

    function run() external {
        _rpc = vm.envOr("SPICY_RPC", string("https://spicy-rpc.chiliz.com"));
        _pool = vm.envOr("STAKING_POOL", 0x0000000000000000000000000000000000007001);
        _staking = vm.envOr("STAKING", 0x0000000000000000000000000000000000001000);
        _execBlock = vm.envUint("EXEC_BLOCK");

        vm.createSelectFork(_rpc);
        console.log("verifying execution block:", _execBlock);
        console.log("chain head:", block.number);
        console.log("");

        _checkCodeAndFlag();
        _checkShareDeltas();
        _checkPoolDeltas();
        _checkEvents();
        _checkLedgerInvariant();
        if (vm.envOr("CHECK_CLAIMS", true)) _checkOpenPendingsStillClaimable();

        console.log("");
        console.log("=======================================");
        if (_failures == 0) {
            console.log("ALL CHECKS PASSED");
            if (_warnings > 0) console.log("warnings (review, not fatal):", _warnings);
        } else {
            console.log("FAILURES:", _failures);
        }
        require(_failures == 0, "verification failed");
    }

    // 1. the upgrade landed and the correction ran exactly once ------------------

    function _checkCodeAndFlag() internal {
        console.log("--- 1. upgrade + guard ---");
        // Default to the bytecode THIS branch builds, so the check is self-contained: if you are on the
        // commit the proposal was built from, the hashes must match. Override only to pin a literal.
        bytes32 want = bytes32(vm.envOr("EXPECTED_CODEHASH", uint256(0)));
        if (want == bytes32(0)) want = keccak256(vm.getDeployedCode("StakingPool.sol:StakingPool"));
        bytes32 got = keccak256(_pool.code);
        console.log("  on-chain code keccak:", vm.toString(got));
        console.log("  expected  (this branch):", vm.toString(want));
        _assert(got == want, "deployed bytecode matches the proposal");

        bool applied;
        try IPool(_pool).correctionsApplied() returns (bool a) { applied = a; }
        catch { _fail("correctionsApplied() is callable -- new bytecode is NOT live"); return; }
        _assert(applied, "correctionsApplied() == true");
    }

    // 2/3. every delta applied exactly, measured across the execution block -------

    function _checkShareDeltas() internal {
        console.log("--- 2. staker share deltas ---");
        (address[] memory v, address[] memory s, int256[] memory d) = _shareDeltas();
        for (uint256 i = 0; i < v.length; i++) {
            bytes32 slot = keccak256(abi.encode(s[i], keccak256(abi.encode(v[i], SLOT_STAKER_SHARES))));
            int256 moved = int256(_storageAt(slot, _execBlock)) - int256(_storageAt(slot, _execBlock - 1));
            if (moved == d[i]) {
                console.log("  OK  ", v[i], s[i]);
            } else {
                _fail("share delta mismatch");
                console.log("      validator", v[i]);
                console.log("      staker   ", s[i]);
                console.log("      expected ", vm.toString(d[i]));
                console.log("      actual   ", vm.toString(moved));
            }
        }
    }

    function _checkPoolDeltas() internal {
        console.log("--- 3. validator totalStakedAmount deltas ---");
        (address[] memory v, int256[] memory d) = _poolDeltas();
        for (uint256 i = 0; i < v.length; i++) {
            // ValidatorPool is a struct in a mapping: base+2 is totalStakedAmount
            bytes32 base = keccak256(abi.encode(v[i], SLOT_VALIDATOR_POOLS));
            bytes32 slot = bytes32(uint256(base) + 2);
            int256 moved = int256(_storageAt(slot, _execBlock)) - int256(_storageAt(slot, _execBlock - 1));
            if (moved == d[i]) {
                console.log("  OK  ", v[i]);
            } else {
                _fail("pool delta mismatch");
                console.log("      validator", v[i]);
                console.log("      expected ", vm.toString(d[i]));
                console.log("      actual   ", vm.toString(moved));
            }
        }
    }

    // 4. the events say what actually landed -------------------------------------

    function _checkEvents() internal {
        console.log("--- 4. SharesCorrected events ---");
        bytes32[] memory t = new bytes32[](1);
        t[0] = SHARES_CORRECTED;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(_execBlock, _execBlock, _pool, t);
        (address[] memory v, address[] memory s, int256[] memory d) = _shareDeltas();

        _assert(logs.length == v.length, "one SharesCorrected per proposed correction");
        console.log("  events emitted:", logs.length, "expected:", v.length);

        for (uint256 i = 0; i < logs.length; i++) {
            (uint256 oldSh, uint256 newSh) = abi.decode(logs[i].data, (uint256, uint256));
            address lv = address(uint160(uint256(logs[i].topics[1])));
            address ls = address(uint160(uint256(logs[i].topics[2])));
            int256 want = _lookup(v, s, d, lv, ls);
            int256 applied = int256(newSh) - int256(oldSh);
            if (applied != want) {
                // saturation: the staker's balance moved between proposal and execution
                _warn("CLAMPED -- correction only partially applied");
                console.log("      validator", lv);
                console.log("      staker   ", ls);
                console.log("      requested", vm.toString(want));
                console.log("      applied  ", vm.toString(applied));
                console.log("      newShares", newSh);
            }
        }
        if (_warnings == 0) console.log("  no clamping: every correction applied in full");
    }

    // 5. the pool still covers the delegation ledger ------------------------------

    function _checkLedgerInvariant() internal {
        console.log("--- 5. totalStakedAmount >= Staking ledger ---");
        address[] memory v = _validators();
        for (uint256 i = 0; i < v.length; i++) {
            VP memory p = IPool(_pool).getValidatorPoolWithoutRewards(v[i]);
            (uint256 ledger,) = IStk(_staking).getValidatorDelegation(v[i], _pool);
            if (p.totalStakedAmount >= ledger) {
                console.log("  OK  ", v[i], "excess:", p.totalStakedAmount - ledger);
            } else {
                _fail("pool is BELOW the ledger -- claims will underflow");
                console.log("      validator", v[i]);
                console.log("      pool  ", p.totalStakedAmount);
                console.log("      ledger", ledger);
            }
        }
    }

    // 6. the check that matters most: can every open pending still be claimed? ----
    //
    // This is the failure mode the ledger-resync approach would have caused -- reducing pool values so far
    // that a later claim() underflows and the staker's funds are stuck. Rather than simulating claim() on a
    // fork (~130 calls, each walking the reward queue over RPC -- minutes), the arithmetic preconditions are
    // read straight from head storage. claim() under the era-3 guard does:
    //
    //     if (!A && !B) { _stakerShares -= shares; sharesSupply -= shares; totalStakedAmount -= amount; }
    //     pendingUnstake -= amount;                       // unconditional
    //     require(address(this).balance >= amount);
    //
    // so every one of those subtractions must not underflow.

    function _checkOpenPendingsStillClaimable() internal {
        console.log("--- 6. open pendings still claimable ---");
        (address[] memory ov, address[] memory os) = _openPendings();
        console.log("  open pendings:", ov.length);

        uint256 poolBalance = _pool.balance;
        uint256 guarded;
        for (uint256 i = 0; i < ov.length; i++) {
            address v = ov[i];
            address s = os[i];
            bytes32 pbase = keccak256(abi.encode(s, keccak256(abi.encode(v, SLOT_PENDING_UNSTAKES))));
            uint256 amount = uint256(vm.load(_pool, pbase));
            uint256 shares = uint256(vm.load(_pool, bytes32(uint256(pbase) + 1)));
            if (amount == 0 && shares == 0) continue; // nothing pending

            VP memory p = IPool(_pool).getValidatorPoolWithoutRewards(v);
            bool A = uint256(vm.load(_pool, keccak256(abi.encode(s, keccak256(abi.encode(v, 106)))))) != 0;
            bool B = uint256(vm.load(_pool, keccak256(abi.encode(s, uint256(105))))) != 0;

            if (!A && !B) {
                guarded++;
                uint256 sh = IPool(_pool).getShares(v, s);
                if (sh < shares) _failPending("staker shares < pending shares", v, s, sh, shares);
                if (p.sharesSupply < shares) _failPending("sharesSupply < pending shares", v, s, p.sharesSupply, shares);
                if (p.totalStakedAmount < amount) {
                    _failPending("totalStakedAmount < pending amount", v, s, p.totalStakedAmount, amount);
                }
            }
            if (p.pendingUnstake < amount) _failPending("pendingUnstake < pending amount", v, s, p.pendingUnstake, amount);
            if (poolBalance < amount) _failPending("pool CHZ balance < pending amount", v, s, poolBalance, amount);
        }
        console.log("  of which claim() would decrement (!A && !B):", guarded);
        console.log("  (the rest hit the guard and touch no pool totals)");
    }

    function _failPending(string memory what, address v, address s, uint256 have, uint256 need) internal {
        _fail(what);
        console.log("      validator", v);
        console.log("      staker   ", s);
        console.log("      have", have, "need", need);
    }

    /// @dev Pairs whose latest Unstake has no Claim after it. All logs are fetched once and matched in
    ///      memory -- a per-pair eth_getLogs would be ~700 round trips.
    function _openPendings() internal returns (address[] memory ov, address[] memory os) {
        _indexEvents();
        console.log("  scanned unstakes / claims:", uB.length, cB.length);

        uint256 n = uB.length;
        address[] memory rv = new address[](n);
        address[] memory rs = new address[](n);
        uint256 m;
        for (uint256 i = 0; i < n; i++) {
            if (uB[i] != _latest(uV, uS, uB, uV[i], uS[i])) continue; // visit each pair once
            if (_latest(cV, cS, cB, uV[i], uS[i]) > uB[i]) continue; // settled
            rv[m] = uV[i];
            rs[m] = uS[i];
            m++;
        }
        ov = new address[](m);
        os = new address[](m);
        for (uint256 i = 0; i < m; i++) {
            ov[i] = rv[i];
            os[i] = rs[i];
        }
    }

    function _indexEvents() internal {
        uint256 chunk = vm.envOr("CHUNK", uint256(500000));
        uint256 head = block.number;
        bytes32[] memory t = new bytes32[](1);
        for (uint256 start = 0; start <= head; start += chunk) {
            uint256 end = start + chunk - 1;
            if (end > head) end = head;
            t[0] = UNSTAKE_TOPIC0;
            Vm.EthGetLogs[] memory ul = vm.eth_getLogs(start, end, _pool, t);
            for (uint256 j = 0; j < ul.length; j++) {
                uV.push(address(uint160(uint256(ul[j].topics[1]))));
                uS.push(address(uint160(uint256(ul[j].topics[2]))));
                uB.push(ul[j].blockNumber);
            }
            t[0] = CLAIM_TOPIC0;
            Vm.EthGetLogs[] memory cl = vm.eth_getLogs(start, end, _pool, t);
            for (uint256 j = 0; j < cl.length; j++) {
                cV.push(address(uint160(uint256(cl[j].topics[1]))));
                cS.push(address(uint160(uint256(cl[j].topics[2]))));
                cB.push(cl[j].blockNumber);
            }
        }
    }

    function _latest(address[] storage v, address[] storage s, uint64[] storage b, address wv, address ws)
        internal
        view
        returns (uint64 best)
    {
        for (uint256 j = 0; j < b.length; j++) {
            if (v[j] == wv && s[j] == ws && b[j] > best) best = b[j];
        }
    }

    function _lookup(address[] memory v, address[] memory s, int256[] memory d, address lv, address ls)
        internal
        pure
        returns (int256)
    {
        for (uint256 i = 0; i < v.length; i++) {
            if (v[i] == lv && s[i] == ls) return d[i];
        }
        return type(int256).min; // not proposed -> will mismatch loudly
    }

    function _storageAt(bytes32 slot, uint256 blk) internal returns (uint256 x) {
        string memory params =
            string.concat("[\"", vm.toString(_pool), "\",\"", vm.toString(slot), "\",\"", _hexQ(blk), "\"]");
        bytes memory raw = vm.rpc(_rpc, "eth_getStorageAt", params);
        require(raw.length == 32, "unexpected eth_getStorageAt length");
        assembly {
            x := mload(add(raw, 0x20))
        }
    }

    function _assert(bool ok, string memory what) internal {
        if (ok) console.log("  OK  ", what);
        else _fail(what);
    }

    function _fail(string memory what) internal {
        _failures++;
        console.log("  FAIL", what);
    }

    function _warn(string memory what) internal {
        _warnings++;
        console.log("  WARN", what);
    }

    function _hexQ(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        bytes memory buf;
        while (v > 0) {
            uint8 dg = uint8(v & 0xf);
            buf = abi.encodePacked(bytes1(dg < 10 ? 48 + dg : 87 + dg), buf);
            v >>= 4;
        }
        return string(abi.encodePacked("0x", buf));
    }

    // the proposed deltas, mirrored from scripts/corrections/*.txt -----------------

    function _shareDeltas() internal pure returns (address[] memory v, address[] memory s, int256[] memory d) {
        v = new address[](8);
        s = new address[](8);
        d = new int256[](8);
        v[0] = 0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc; s[0] = 0xC501459cF662D00AF2836DF8A5DA4d1b07E735e7; d[0] = -16508669501425032686;
        v[1] = 0xeC2e502f77c4811f2ef477397235976b1371FCd3; s[1] = 0xAc55Ad39532e7E609DDa1FFfA7F0B6D796dcB049; d[1] = -20731160460122372;
        v[2] = 0x20da691Ee91FAe686798294c819aaf0BaB6a101d; s[2] = 0xb02b23F1463C13ee538f2f2321568Ea02eADA2b0; d[2] = -87552651873;
        v[3] = 0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc; s[3] = 0xb95Dd61E509D1fCB247003d4c2d3B0D57487366c; d[3] = -1174308727;
        v[4] = 0x4dD74707f22b74EC872CA6AEB2a065E3d006B9d9; s[4] = 0xb02b23F1463C13ee538f2f2321568Ea02eADA2b0; d[4] = -95668269;
        v[5] = 0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5; s[5] = 0x5c197f8646fff1B190cEaf4e97eFB4b5F342D3E7; d[5] = 43160350740120;
        v[6] = 0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5; s[6] = 0x16b43036C732D834FAE0D485817aDE8a71cC8984; d[6] = 43115582885010;
        v[7] = 0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc; s[7] = 0x7ceF58aDcAb782b70ed57ECAF10AD8131d080A99; d[7] = 322988883717134;
    }

    function _poolDeltas() internal pure returns (address[] memory v, int256[] memory d) {
        v = new address[](5);
        d = new int256[](5);
        v[0] = 0xeC2e502f77c4811f2ef477397235976b1371FCd3; d[0] = -11000000000000000000;
        v[1] = 0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc; d[1] = -909718372900000000000000;
        v[2] = 0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5; d[2] = 120000000000000000000;
        v[3] = 0x4dD74707f22b74EC872CA6AEB2a065E3d006B9d9; d[3] = -100000000000000000;
        v[4] = 0x20da691Ee91FAe686798294c819aaf0BaB6a101d; d[4] = -10000000000000000000;
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
