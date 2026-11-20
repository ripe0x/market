#!/usr/bin/env bash
# Rehearses the unified-actions deployment and a full lifecycle on a throwaway anvil. It
# broadcasts script/Deploy.s.sol and its examples() from anvil's unlocked default account, then
# simulates script/ActionsLifecycle.s.sol (self-contained: it deploys its own system and example
# assets and prints every receipt). By default anvil runs with NO fork, so nothing reaches any
# public chain; the lifecycle is a simulation and broadcasts nothing. Finally the fork is stopped.
# Usage: script/rehearse.sh [fork-rpc-url] [port]
#   default: plain local anvil, no fork
#   fork:    script/rehearse.sh https://mainnet.gateway.tenderly.co
set -euo pipefail
cd "$(dirname "$0")/.."
FORK="${1:-}"
PORT="${2:-8549}"
RPC="http://127.0.0.1:$PORT"
# anvil's first unlocked dev account (disposable test key); used only on the local node.
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

if [ -n "$FORK" ]; then
  anvil --fork-url "$FORK" --port "$PORT" --silent &
else
  anvil --port "$PORT" --silent &
fi
ANVIL=$!
trap 'kill "$ANVIL" 2>/dev/null || true' EXIT
for _ in $(seq 100); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
echo "anvil chain $(cast chain-id --rpc-url "$RPC") at block $(cast block-number --rpc-url "$RPC")"

ARGS=(--rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" --slow)
forge script script/Deploy.s.sol "${ARGS[@]}"
forge script script/Deploy.s.sol --sig "examples()" "${ARGS[@]}"
# Self-contained lifecycle: simulate against the local node (no broadcast), printing receipts.
forge script script/ActionsLifecycle.s.sol --rpc-url "$RPC"
