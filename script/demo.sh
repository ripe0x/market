#!/usr/bin/env bash
# Starts a throwaway anvil node, runs script/Demo.s.sol against it from anvil's unlocked
# default accounts, then stops that node. Usage: script/demo.sh [port]
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8547}"
RPC="http://127.0.0.1:$PORT"

anvil --port "$PORT" --silent &
ANVIL=$!
trap 'kill "$ANVIL" 2>/dev/null || true' EXIT
for _ in $(seq 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.1; done

forge script script/Demo.s.sol --rpc-url "$RPC" --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
