#!/usr/bin/env bash
# Finds the block a governance proposal was executed at, by scanning for the
# OZ Governor `ProposalExecuted(uint256)` event whose data == the proposal id.
#
# Usage:
#   RPC=<spicy-rpc> bash scripts/find-execution-block.sh [PROPOSAL_ID] [CREATION_TX]
#
# Defaults are the Sherlock #125 (first-fix) proposal.
set -euo pipefail

RPC="${RPC:-https://spicy-rpc.chiliz.com}"
GOV="${GOV:-0x0000000000000000000000000000000000007002}"   # Governance system contract
CHUNK="${CHUNK:-10000}"

PROPOSAL_ID="${1:-29747069039487431646751287522154686300734430434586626956882319746351922642118}"
CREATION_TX="${2:-0xe1fb378550f1fd37cd5492a0c17f2a3c438642a18a9812855d5252e57631d5f8}"

TOPIC0=$(cast keccak "ProposalExecuted(uint256)")
PID_HEX=$(cast to-uint256 "$PROPOSAL_ID" | tr 'A-F' 'a-f')   # 0x + 64 hex, matches the log data

# start scanning at the creation block (execution is always after creation)
START=$(cast tx "$CREATION_TX" blockNumber --rpc-url "$RPC")
LATEST=$(cast block-number --rpc-url "$RPC")
echo "Proposal:   $PROPOSAL_ID"
echo "Governance: $GOV"
echo "Scanning ProposalExecuted from block $START to $LATEST (chunk $CHUNK)..."

b="$START"
while [ "$b" -le "$LATEST" ]; do
  end=$(( b + CHUNK - 1 )); [ "$end" -gt "$LATEST" ] && end="$LATEST"
  filter=$(jq -cn --arg a "$GOV" --arg t "$TOPIC0" \
                  --arg f "$(printf '0x%x' "$b")" --arg to "$(printf '0x%x' "$end")" \
                  '{address:$a, topics:[$t], fromBlock:$f, toBlock:$to}')
  res=$(cast rpc eth_getLogs "$filter" --rpc-url "$RPC")
  hit=$(echo "$res" | jq -r --arg pid "$PID_HEX" \
        'first(.[] | select((.data|ascii_downcase)==$pid))')
  if [ "$hit" != "null" ] && [ -n "$hit" ]; then
    blk_hex=$(echo "$hit" | jq -r '.blockNumber')
    tx_hash=$(echo "$hit" | jq -r '.transactionHash')
    blk_dec=$(cast to-dec "$blk_hex")
    echo
    echo "ProposalExecuted found:"
    echo "  execution block: $blk_dec"
    echo "  execution tx:    $tx_hash"
    echo
    echo "Suggested FROM_BLOCK for the quantifier (first-fix block - ~2 epochs):"
    echo "  $(( blk_dec - 14400 ))"
    exit 0
  fi
  b=$(( end + 1 ))
done

echo "ProposalExecuted for that id not found in [$START, $LATEST]. Was it executed? Try a different RPC."
exit 1
