#!/usr/bin/env bash
# Rehearses a deployment on a throwaway anvil fork: runs script/Deploy.s.sol (supported
# contracts, then the PaintAction example) and then
# script/Lifecycle.s.sol exactly as a real deployment would, from anvil's unlocked default
# account, then stops the fork. Nothing reaches the forked chain.
# Usage: script/rehearse.sh [fork-rpc-url] [port]
#   default fork: Sepolia, https://ethereum-sepolia-rpc.publicnode.com
#   mainnet:      script/rehearse.sh https://mainnet.gateway.tenderly.co
set -euo pipefail
cd "$(dirname "$0")/.."
FORK="${1:-https://ethereum-sepolia-rpc.publicnode.com}"
PORT="${2:-8548}"
RPC="http://127.0.0.1:$PORT"
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

anvil --fork-url "$FORK" --port "$PORT" --silent &
ANVIL=$!
trap 'kill "$ANVIL" 2>/dev/null || true' EXIT
for _ in $(seq 100); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
echo "Forked chain $(cast chain-id --rpc-url "$RPC") at block $(cast block-number --rpc-url "$RPC")"

ARGS=(--rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" --slow)
forge script script/Deploy.s.sol "${ARGS[@]}"
forge script script/Deploy.s.sol --sig "examples()" "${ARGS[@]}"
OUT=$(forge script script/Lifecycle.s.sol "${ARGS[@]}" | tee /dev/stderr)
BID=$(grep -o 'recover with 0x[0-9a-fA-F]*' <<<"$OUT" | awk '{print $3}')
forge script script/Lifecycle.s.sol --sig "recover(address)" "$BID" "${ARGS[@]}"
