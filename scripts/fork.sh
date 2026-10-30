#!/usr/bin/env bash
# Local mainnet fork with Market deployed through script/Deploy.s.sol, one escrowed
# listing and one funded collection bid, the web app on :3000 and the keeper. The
# keeper matches any same-collection listing and bid. OpenSea fills need real signed
# offers (see keeper/e2e.ts); they do not run on a plain fork. Ctrl-C stops all.
set -euo pipefail
cd "$(dirname "$0")/.."
BLOCK=${FORK_BLOCK:-26303107}
PORT=${FORK_PORT:-8545}
RPC=http://127.0.0.1:$PORT

anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number "$BLOCK" --port "$PORT" --silent &
PIDS=($!)
trap 'kill "${PIDS[@]}" 2>/dev/null' EXIT
until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.3; done

ACCOUNTS=$(cast rpc eth_accounts --rpc-url "$RPC")
SELLER=$(jq -r '.[0]' <<<"$ACCOUNTS")
BUYER=$(jq -r '.[1]' <<<"$ACCOUNTS")
KEEPER=$(jq -r '.[3]' <<<"$ACCOUNTS")
OWNER=$(jq -r '.[8]' <<<"$ACCOUNTS")
PROTOCOL=$(jq -r '.[9]' <<<"$ACCOUNTS")

PROTOCOL_FEE_RECIPIENT=$PROTOCOL MARKET_OWNER=$OWNER forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$SELLER" --silent
MARKET=$(jq -r '.transactions[0].contractAddress' broadcast/Deploy.s.sol/1/run-latest.json)
echo "Market $MARKET"

cd app
export RPC_URL=$RPC DB_PATH=$PWD/fork.db NEXT_PUBLIC_MARKET_ADDRESS=$MARKET
rm -f fork.db fork.db-*
NODE_NO_WARNINGS=1 npx tsx scripts/seed.ts
cat > .env.local <<ENV
NEXT_PUBLIC_MARKET_ADDRESS=$MARKET
NEXT_PUBLIC_RPC_URL=$RPC
NEXT_PUBLIC_DEV_ACCOUNTS=$SELLER,$BUYER
NEXT_PUBLIC_EXPLORER=
RPC_URL=$RPC
DB_PATH=$PWD/fork.db
ENV

npx next dev -p "${WEB_PORT:-3000}" &
PIDS+=($!)
START_BLOCK=$BLOCK CONFIRMATIONS=0 PROFIT_MARGIN=0 KEEPER_INTERVAL_MS=5000 KEEPER_UNLOCKED_ADDRESS=$KEEPER NODE_NO_WARNINGS=1 npx tsx keeper/run.ts &
PIDS+=($!)
wait
