# Governance scripts (`scripts/Governance.s.sol`)

Foundry scripts for the system Governance contract at `0x0000000000000000000000000000000000007002`. Run commands from the **`genesis/`** directory (where `foundry.toml` lives).

---

## Proposal JSON (`PROPOSAL_FILE`)

**Propose** and **Execute** both read the same file path from the environment variable `PROPOSAL_FILE`. Keep one JSON file per proposal and use it for both steps so `description`, `targets`, `values`, `calldatas`, and `votingPeriod` stay aligned (Execute rebuilds the description hash and calls `execute` with those arrays).

Minimal shape:

```json
{
  "description": "Human-readable proposal text",
  "votingPeriod": 100,
  "targets": ["0x..."],
  "values": [0],
  "calldatas": ["0x..."],
  "etchOverrides": false,
  "etchAddresses": [],
  "etchArtifacts": []
}
```

- **`calldatas`**: hex strings (each element is parsed with `vm.parseBytes`).
- **`etchOverrides`**: if `true`, you must set **`etchAddresses`** and **`etchArtifacts`** to the same length (and non-empty), paired by index; the script `vm.etch`es bytecode from the given artifacts at those addresses (used to satisfy local simulation for system contracts). If `false`, you can omit the etch arrays or use empty arrays.

---

## Calldata for system contract upgrades

Governance proposals that upgrade a system contract often call `upgradeSystemSmartContract(address,bytes,bytes)` on the deployer / upgrade entrypoint (see your proposal’s **`targets`** for the correct contract and address).

Arguments:

1. **`CONTRACT_ADDRESS`** — on-chain address of the system contract being upgraded (for example Staking’s fixed address).
2. **`DEPLOYED_BYTECODE`** — runtime bytecode from a Foundry build artifact: field **`deployedBytecode.object`** (hex string including the `0x` prefix).
3. **`INIT_FN`** — ABI-encoded calldata for the initializer invoked after the new implementation is set. Use **`0x`** when no initializer call is required, or generate it with `cast calldata` for your function and arguments (for example `cast calldata "initialize(uint256)" 1`).

Build contracts first so `out/` is up to date (`forge build` from **`genesis/`**).

**Extract deployed bytecode from an artifact** (Staking example):

```bash
jq -r '.deployedBytecode.object' out/Staking.sol/Staking.json
```

**Full example: one calldata hex string for `proposal.json`**

Run from **`genesis/`**. Replace `<CONTRACT_ADDRESS>` and the initializer as needed.

```bash
DEPLOYED_BYTECODE=$(jq -r '.deployedBytecode.object' out/Staking.sol/Staking.json)

cast calldata "upgradeSystemSmartContract(address,bytes,bytes)" \
  <CONTRACT_ADDRESS> \
  "$DEPLOYED_BYTECODE" \
  0x
```

Paste the `cast` output (single `0x…` line) into the **`calldatas`** array in your proposal JSON.

**Note:** Very large contracts produce a long shell argument; if the shell complains about length, write bytecode to a file and use a short script, or pass the hex via a here-doc / file that `cast` can read—your environment’s limits may require that for production-sized artifacts.

---

## 1. `Propose`

Submits `proposeWithCustomVotingPeriod` on-chain and prints the **proposal ID**.

**Required**

- `PROPOSAL_FILE` — path to the JSON file (absolute or relative to how you invoke `forge`).

**Typical invocation** (replace RPC URL, keys, and gas as appropriate):

```bash
export PROPOSAL_FILE=scripts/proposal.json

forge script scripts/Governance.s.sol:Propose -vvv \
  --fork-url <RPC_URL> \
  --ledger \
  --broadcast
```

Copy the logged **Proposal ID** for the next steps.

---

## 2. `Vote`

Casts a **yes** vote (`support = 1`) for the given proposal.

**Required**

- `PROPOSAL_ID` — uint from the Propose output (or explorer).

**Typical invocation**

```bash
export PROPOSAL_ID=123

forge script scripts/Governance.s.sol:Vote -vvv \
  --fork-url <RPC_URL> \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

---

## 3. `ProposalState`

Read-only: prints the proposal’s OpenZeppelin Governor state name (`Pending`, `Active`, `Succeeded`, `Executed`, etc.).

**Required**

- `PROPOSAL_ID`

**Typical invocation** (no `--broadcast`; only reads via fork/RPC):

```bash
export PROPOSAL_ID=123

forge script scripts/Governance.s.sol:ProposalState -vvv --fork-url <RPC_URL>
```

---

## 4. `Execute`

Executes a **Succeeded** proposal after advancing past voting (see below). Uses the same **`PROPOSAL_FILE`** as Propose.

**Required**

- `PROPOSAL_FILE`
- `PROPOSAL_ID`

**Waiting for voting to end**

- **Local anvil / fork (default):** the script uses `vm.roll(block.number + votingPeriod + 1)` using `votingPeriod` from the JSON. This only makes sense when the execution environment lets you manipulate the block number.
- **Real network (`RPC_WAIT=true`):** the script polls on-chain until the proposal state is **Succeeded**, sleeping between attempts (no `vm.roll`).

Optional when `RPC_WAIT=true`:

- `GOVERNANCE_POLL_INTERVAL_MS` (default `3000`)
- `GOVERNANCE_POLL_MAX_ATTEMPTS` (default `500`)

**Typical invocation (fork / local)**

```bash
export PROPOSAL_FILE=scripts/proposal.json
export PROPOSAL_ID=123

forge script scripts/Governance.s.sol:Execute -vvv \
  --fork-url <RPC_URL> \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

**Typical invocation (real RPC, wait until succeeded)**

```bash
export PROPOSAL_FILE=scripts/proposal.json
export PROPOSAL_ID=123
export RPC_WAIT=true

forge script scripts/Governance.s.sol:Execute -vvv \
  --fork-url <RPC_URL> \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

---

## Flow summary

1. Set `PROPOSAL_FILE` → run **Propose** → note **Proposal ID**.
2. Run **Vote** (and any other votes your process requires) with `PROPOSAL_ID`.
3. Use **ProposalState** to confirm **Succeeded** (and that timelock/queue rules are satisfied if your governor uses them).
4. Run **Execute** with the same `PROPOSAL_FILE` and `PROPOSAL_ID`, choosing default roll vs `RPC_WAIT` as appropriate.

---

## Reference

The Solidity file header in `Governance.s.sol` documents the JSON schema and optional polling env vars; this guide matches the four contracts **Propose**, **Vote**, **ProposalState**, and **Execute** as implemented there.
