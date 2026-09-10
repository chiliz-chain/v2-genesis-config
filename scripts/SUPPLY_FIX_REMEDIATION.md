> **STATUS: EXECUTED — historical record.** Both stages ran on Spicy (chain 88882) and are
> complete. Mainnet (88888) never ran the buggy code and was never corrected. The
> `applyCorrections` entry point this runbook drives was removed from `contracts/StakingPool.sol`
> in COR-192; Spicy slot 107 still holds 1 and `correctionsApplied()` still reads true there.
> The command blocks below are a record of what was run, not instructions to re-run.

# StakingPool state remediation — Spicy runbook

Two-stage remediation for the `claim()` share-accounting bug.

**Stage 1 (the `||`→`&&` fix) is DONE and LIVE on Spicy** — executed at block **`Tfix = 36824812`** (tx `0xf4363c19c335d16aa153bbaddf6780f1b47b759c8487afa10f271ae85d4aafc2`), so no new corruption occurs. This runbook is **Stage 2**: reconstruct the correct state and repair it via a governance runtime upgrade.

**Mainnet is not affected** (never ran the buggy code) — Spicy only.

System contracts: StakingPool `0x…7001`, Governance `0x…7002`, RuntimeUpgrade `0x…7004`.

---

## What is being corrected

Two opposite corruptions from the same accounting defect:

| direction | cause | stakers (last run) |
|---|---|---|
| shares/pool too **LOW** | double-subtraction (`\|\|` bug): removed at unstake *and* at claim | 3 |
| shares/pool too **HIGH** | under-subtraction: removed at *neither*, because `_unstakedPostSherlockSupplyFixUpdate` is per-**staker**, not per-validator | 5 |

Plus 5 validators whose `totalStakedAmount` moved by the same wrong decrements.

Corrections are computed as **signed deltas directly** — no absolute value is reconstructed. Because `current` and `correct` share the same minted shares, the mints cancel:

```
current = Σ mints − Σ did_remove
correct = Σ mints − Σ should_remove
  delta = correct − current = Σ did_remove − Σ should_remove
```

So the whole correction follows from the pendings: for each one, how many times the chain actually removed its shares, against how many times it should have. Shares and amount move together inside a single `if` in both `unstake()` and `claim()`, so one classification drives both outputs.

> **Over-withdrawals:** 4 stakers withdrew more than they ever held (the inflated balance let them unstake a position they no longer owned; one staked 10 CHZ and withdrew 20). Their correction would drive the balance below zero, which is unrepresentable — the share delta is clamped so the balance lands on **0**. The shortfall (~125,584,011,042,851,090 shares ≈ 21 CHZ) is an already-realized pool loss, not recoverable by this fix.
>
> `totalStakedAmount` is deliberately **not** clamped the same way: a pool delta larger than the whole pool can only mean the off-chain numbers are wrong, so it reverts and fails the governance execution atomically.

## 1. Build & test

```bash
cd genesis
forge build
forge test --match-path "test/StakingPool*.t.sol" -vvv
```

## 2. Reconstruct the correct state (Spicy archive node)

```bash
export SPICY_RPC=<spicy-archive-rpc>
forge script scripts/ReconstructStakingPoolState.s.sol -vv
```

Writes `scripts/corrections/correct-shares.txt` — signed share deltas `[(v,s,delta),…]` — and `scripts/corrections/correct-pools.txt` — signed `totalStakedAmount` deltas `[(v,delta),…]`. Both are `cast`-ready. All generated correction data lives in `scripts/corrections/`.

The script never reads Stake events. It works from the identity `delta = Σ did_remove − Σ should_remove`, since `current` and `correct` share the same mints and those cancel. Only Unstake/Claim logs and the pendings they open are read. (An earlier version reconstructed mints from the `_stakerShares` delta across each Stake block, which double-counted whenever a pair emitted several Stake events in one block — 40 in one observed case — and inflated 8 of 15 deltas. That failure mode is structurally impossible here.)

Checks before proceeding — all four printed in the summary:

| line | expected | meaning if it differs |
|---|---|---|
| `over-withdrawn stakers (clamped to 0)` | 4 | a staker withdrew more than they ever minted; each logged with its shortfall |
| `open pre-fix pendings left intact` | 121 | pendings whose removal is still legitimately owed to a future `claim()` |
| `pool cross-check: agree / disagree` | 12 / 2 | the two independent pool derivations diverge — investigate before proposing |
| `observed-vs-model mismatches` | 1 | the era model disagrees with the observed share movement |

The two known pool disagreements (`0xBD6D…` 11.89 CHZ, `0xb1b5…` 1.199 CHZ) are pre-existing drift, not this bug: `0xBD6D…` has **zero** corrupted pendings, so nothing here could have caused its residual, and neither residual matches any Unstake or Claim amount on those validators. The shipped deltas are the pendings-based ones, which correct exactly what the bug broke. The single observed mismatch is claim block 14335828, the one block on Spicy holding both a Stake and a Claim for the same pair — the observational check cannot isolate the decrement there, so it reports rather than fails.

Knobs: `FROM_BLOCK`/`TO_BLOCK` (default `0`→head), `CHUNK` (getLogs window), `VERIFY_OBSERVED` (default true), `OUT_SHARES`/`OUT_POOLS` (defaults are under `scripts/corrections/`, which `foundry.toml` grants write access to as a directory — a new output there needs no config change).

The `VERIFY_OBSERVED` pass is the corroboration: it re-derives every decrement from the observed `_stakerShares` movement, independently of the era model, across all 701 unstakes and 569 claims. A separate `QuantifyDoubleSubtraction.s.sol` used to serve this role and has been deleted — it targeted a `correctDoubleSubtractedSupply` entry point that no longer exists, scanned a narrower block range, and shared the mixed-block blind spot described above.

## 3. Build the proposal calldata

The runtime upgrade delivers a **single** `applyFunction` blob, so everything goes through `applyCorrections`. It can run only once — `correctionsApplied` is the replay guard:

```bash
SIG="applyCorrections((address,address,int256)[],(address,int256)[])"
BYTECODE=$(forge inspect StakingPool deployedBytecode)
APPLY=$(cast calldata "$SIG" "$(cat scripts/corrections/correct-shares.txt)" "$(cat scripts/corrections/correct-pools.txt)")
CALLDATA=$(cast calldata "upgradeSystemSmartContract(address,bytes,bytes)" \
  0x0000000000000000000000000000000000007001 "$BYTECODE" "$APPLY")

# needed by the dry run in step 5 — printf, NOT echo: a trailing newline breaks vm.parseBytes
printf '%s' "$APPLY" > scripts/corrections/apply-calldata.txt
```

Sanity-check the encoding before going further — the decode must show the same delta counts the reconstruction reported:

```bash
cast decode-calldata "upgradeSystemSmartContract(address,bytes,bytes)" "$CALLDATA" | head -1   # -> 0x…7001
cast decode-calldata "$SIG" "$APPLY"                                                          # -> 8 share, 5 pool
```

`applyCorrections` is the only remediation entry point (`onlyFromRuntimeUpgrade`).

**Why deltas rather than absolute targets.** A proposal executes a full voting period (~2400 blocks) after the numbers are computed. An absolute write would erase any stake/unstake made in that window, and `totalStakedAmount` grows continuously from redelegated rewards, so a stale absolute value would discard accrued rewards pool-wide. Everything is therefore relative to live state:

| quantity | how it is applied | staleness risk |
|---|---|---|
| `_stakerShares[v][s]` | signed delta, saturating at 0 | none — composes with intervening activity |
| `sharesSupply` | moved by exactly the share change applied on-chain | none — never passed in |
| `totalStakedAmount` | signed delta per validator | none — composes with intervening activity |

`totalStakedAmount` is **not** resynced from the `Staking` delegation ledger. An earlier revision did that, and it was wrong: the pool legitimately still counts the 121 open pre-fix pendings that the ledger already dropped at `unstake()`, because their pool-side decrement is deferred to `claim()`. Resyncing removes them a second time and those stakers' `claim()` then underflows and reverts, locking their funds. The invariant is `totalStakedAmount >= ledger`, with the excess being exactly those pendings.

Deltas are **not** idempotent, so `applyCorrections` can run only once (`correctionsApplied`). Governance does not close this gap by itself: it blocks re-executing a proposal and blocks re-proposing an identical one, but the SAME calldata under a DIFFERENT description is a new proposal that would apply the deltas twice. Both damage directions therefore ship in one call.

**Storage:** adds `correctionsApplied` at slot **107**. Purely additive — live slots 0–106 are untouched, so the deployed contract's layout is preserved.

## 4. Assemble the proposal file

```bash
jq -n --arg cd "$CALLDATA" '{
  description: "fix(COR-111): Repair StakingPool staker shares and validator pool totals on Spicy …",
  votingPeriod: 2400,
  targets: ["0x0000000000000000000000000000000000007004"],
  values: [0],
  calldatas: [$cd],
  etchOverrides: false, etchAddresses: [], etchArtifacts: []
}' > scripts/proposal-spicy-statefix.json
```

The `description` is part of the proposal's identity — it must be **byte-identical** between Propose and Execute, so don't edit it in between.

## 5. Dry-run against forked Spicy state

`scripts/SimulateCorrection.s.sol` forks live Spicy, installs the new bytecode exactly as the EVM hook would, executes the **real** `scripts/corrections/apply-calldata.txt` as `0x…7004`, then asserts the resulting state and that a replay reverts. Nothing is broadcast.

```bash
SPICY_RPC=$SPICY_RPC forge script scripts/SimulateCorrection.s.sol -vv
```

Expect `applyCorrections executed OK`, `>= ledger: true` for every validator, `replay correctly rejected`, and `SIMULATION PASSED`.

Last verified run: 9/9 validators `>= ledger`, **458,990 gas** — comfortably within a block. Two further checks are worth doing by hand against that output, since the simulation itself does not assert them:

- each validator's `sharesSupply` and `totalStaked` movement equals the sum of that validator's deltas in `scripts/corrections/correct-shares.txt` / `correct-pools.txt`;
- no staker's reported total can go negative. Restore deltas only raise a total, so only the reduce deltas need checking, against the re-indexed `StakingPoolRewards`. Smallest margin at last run: `0xb1b5…/0xc501…`, 4,916,425.97 CHZ reduced by 1,553,146.68 → 3,363,279.29.

Bystanders are safe by construction on the current numbers: on both materially affected validators `sharesSupply` falls by a larger fraction than `totalStakedAmount`, so the pool ratio decreases and uncorrected stakers' totals move slightly **up**. Re-check this if the deltas ever change sign mix.

## 6. Propose → Vote → Execute

```bash
export PROPOSAL_FILE=scripts/proposal-spicy-statefix.json
forge script scripts/Governance.s.sol:Propose --fork-url $SPICY_RPC --ledger --broadcast   # note the id
export PROPOSAL_ID=<id>
forge script scripts/Governance.s.sol:Vote    --fork-url $SPICY_RPC --private-key $KEY --broadcast
RPC_WAIT=true forge script scripts/Governance.s.sol:Execute --fork-url $SPICY_RPC --private-key $KEY \
  --broadcast --skip-simulation
```

`--skip-simulation` is required on Execute. `forge script --broadcast` runs the transaction twice — once in the script, then again in a fresh EVM against real chain state — and cheatcodes apply only to the first. So `etchOverrides` gets the script phase through (you will see `Executed proposal: <id>` logged) and the second pass still hits the un-upgraded contract, failing with `RuntimeUpgrade: migration failed` and a tell-tale 277 gas on `applyCorrections` — a selector miss, not a real revert. Nothing is broadcast when that happens.

Do **not** add `--gas-limit`. In `forge script` it caps the script's own EVM, not just the transaction, overriding the `gas_limit` in `foundry.toml` that these scripts need; the script then dies with a bare `OutOfGas`. Executed for real at ~810k gas (621,142 measured for the call path plus calldata and base); the bytecode swap is free, since `evmHookRuntimeUpgrade.RequiredGas` returns 0.

On execute: Governance `0x…7002` → RuntimeUpgrade `0x…7004` → EVM hook `0x…7f01` `SetCode`s the new bytecode, then `0x…7004` calls `applyCorrections(...)`, satisfying `onlyFromRuntimeUpgrade` at zero gas price.

Because corrections are deltas and `totalStakedAmount` is read live, the calldata does **not** go stale if staking activity occurs between proposing and executing — no rebuild required.

## 7. Validate

Note the execution block from the Execute step, then run the verification script. It is read-only and
asserts every claim the proposal made, measuring each delta as `after - before` across that block — which
catches a partial apply, a double apply, and a correction that landed differently from the one proposed.

```bash
EXEC_BLOCK=<block the proposal executed in> \
SPICY_RPC=$SPICY_RPC forge script scripts/VerifyCorrectionApplied.s.sol -vv
```

It reverts unless everything passes. The six checks:

| # | check | why it matters |
|---|---|---|
| 1 | on-chain code keccak == the bytecode this branch builds, and `correctionsApplied()` is true | the upgrade landed and the migration ran |
| 2 | each of the 8 staker share deltas moved by exactly the proposed amount | catches partial or double application |
| 3 | each of the 5 validator `totalStakedAmount` deltas likewise | same, for the pool side |
| 4 | one `SharesCorrected` per correction, and `newShares - oldShares` equals what was proposed | the only way to see a **clamped** correction (reported as WARN, not FAIL) |
| 5 | `totalStakedAmount >= ledger` for all 9 validators | the pool still covers the delegation ledger |
| 6 | every open pending still satisfies `claim()`'s arithmetic preconditions | the funds-locking failure mode the ledger-resync approach would have caused |

Takes ~100 s, most of it archive reads. `CHECK_CLAIMS=false` skips check 6 (the slow one) for a quick pass.

**A WARN in check 4 is not a failure but must be understood.** It means a staker's balance moved between
computing the numbers and executing, so `_applyDeltaSaturating` clamped their correction and only part of it
applied. The event reports what actually landed.

Pre-execution baseline, for comparison: checks 1–4 fail (nothing applied yet), check 5 passes on all 9
validators, and check 6 finds **135 open pendings, 121 of which would decrement** under `!A && !B` — which
independently reproduces the reconstruction's count of 121 open pre-fix pendings by a different route.

Then confirm the indexer. No re-index is needed: the correction emits no Stake/Unstake/Claim, so `totalNet`
is unchanged and only `stakedAmount` moves.

```sql
WITH latest AS (
  SELECT DISTINCT ON (validator, staker) validator, staker, epoch,
         "cumulativeRewards"::numeric AS cum
  FROM "StakingPoolRewards" ORDER BY validator, staker, epoch DESC)
SELECT * FROM latest WHERE cum < 0 ORDER BY cum;
```

Expect **0 rows**. Expect one epoch carrying a large negative `epochRewards` (about −1.55M CHZ for
`0xC501459cF6…`): the correction moves stake with no event to offset it, so the per-epoch figure absorbs the
whole shift. Cumulative totals stay positive, and the cumulative total is the number that matters.

---
