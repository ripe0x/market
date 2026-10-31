# Operations

Nothing is deployed. Every mainnet step below needs explicit owner authorization.

## Requirements

Foundry 1.8+, anvil, Node 22.13+ (for `node:sqlite`), jq. Public RPC: `https://mainnet.gateway.tenderly.co`.

```bash
git submodule update --init
```

```bash
cd app && npm ci
```

## Develop on a local fork

```bash
scripts/fork.sh
```

Starts anvil at block 26303107, deploys Market through `script/Deploy.s.sol`, gives anvil account 0 two real NFTs (Otherdeed #48816, GLHFers #2066), signs a local WETH offer for each from account 2, then runs the web app on :3000 and the keeper. The connect menu shows two dev wallets (seller, buyer). The local offers are test data, not OpenSea orders. Anvil's public dev accounts carry EIP-7702 delegations on mainnet; the seed clears them on the fork.

## Tests

Run per file; the agent guard refuses whole-suite runs outside a release candidate.

```bash
forge test --match-path test/OpenSea.t.sol
```

```bash
forge test --match-path test/Local.t.sol
```

```bash
forge test --match-path test/Invariant.t.sol
```

```bash
forge test --match-path test/Gas.t.sol -vv
```

```bash
cd app && node --test --import tsx lib/*.test.ts keeper/*.test.ts
```

```bash
cd app && npm run e2e:keeper
```

Full release candidate run:

```bash
CANDIDATE_RUN=1 forge test
```

## Deploy (dry run)

```bash
PROTOCOL_FEE_RECIPIENT=0xYourRecipient MARKET_OWNER=0xYourOwner forge script script/Deploy.s.sol --rpc-url mainnet
```

Simulates against mainnet and prints the address and gas (estimate 5.3M gas including Foundry's margin). No broadcast.

## Deploy (mainnet, owner authorized only)

1. Freeze the candidate commit; run the full suite with `CANDIDATE_RUN=1`; complete the independent audit.
2. Choose the protocol fee recipient (immutable) and the owner (currencies and zones only; a Safe is recommended for both).
3. Import the deployer key into a Foundry keystore (`cast wallet import deployer --interactive`). Never pass a key on the command line.
4. Broadcast:

```bash
PROTOCOL_FEE_RECIPIENT=0xRecipient MARKET_OWNER=0xOwner forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --broadcast --verify
```

5. Verify, then record in `STATUS.md`:
   - `cast code <market> --rpc-url https://mainnet.gateway.tenderly.co` is non-empty and matches `out/Market.sol/Market.json` deployed bytecode except immutables
   - `cast call <market> "PROTOCOL_FEE_RECIPIENT()(address)" --rpc-url https://mainnet.gateway.tenderly.co` equals the chosen recipient
   - `cast call <market> "owner()(address)" --rpc-url https://mainnet.gateway.tenderly.co` equals the chosen owner
   - `cast call <market> "zones(address)(bool)" 0x000056F7000000EcE9003ca63978907a00FFD100 --rpc-url https://mainnet.gateway.tenderly.co` is true
   - Source verified on Etherscan
6. Canary (separate owner authorization): deposit one low-value NFT that has a live OpenSea offer, wait 10 seconds, run `cd app && npm run live:fulfiller -- <nft> <tokenId>` against the deployed address, and confirm OpenSea signs for Market. If OpenSea answers `Account can not perform trading operations`, keep OpenSea matching off; direct buys and Market bids still work. Withdraw or sell the canary NFT afterwards.

## Run in production

One host with a persistent disk. Copy `app/.env.example` to the host's environment; inject `OPENSEA_API_KEY` and `KEEPER_PRIVATE_KEY` from its secret store. Set `SUBMIT_RPC_URL` to a private relay; without it the keeper only syncs sales.

```bash
cd app && npm run build && npm start
```

```bash
cd app && npm run keeper
```

The keeper logs one JSON line per event: `start`, `sale`, `skip` (with reason), `submitted`, `confirmed`, `reverted`, `replaced`, `cancel_sent`, `simulation_failed`, `round_failed`. Alert on repeated `round_failed` or `reverted`.

Stop the keeper with SIGINT or SIGTERM; it finishes the current round. Stopping it never blocks sellers (cancel and withdraw go straight to Market) or buyers.

## Keeper wallet

Holds only ETH for gas; it never holds NFTs or user funds (Market does). Fund it with a small float and top up. Executor fees arrive as WETH. If the key leaks, the loss is the gas float and future executor fees; rotate the key and restart.

## Backup

The database is an index of Market events plus keeper attempts. Everything can be rebuilt from chain by resetting `synced_block` to the deployment block.

```bash
sqlite3 "$DB_PATH" ".backup '/backups/market-$(date +%F).db'"
```

## Emergencies

There is no pause and no admin access to assets. Options:

- Stop the keeper.
- Owner disables an OpenSea zone (stops `fillOffer`) or a currency (stops fills in it). Withdrawals continue.
- Take the web app down. Sellers and buyers can still cancel and withdraw directly on the contract (`cancelListing`, `withdrawListing`, `cancelBid`, `withdrawBid`) with the terms from their `Listed` or `BidCreated` event.
- A fix ships as a new Market deployment. Tell users to withdraw from the old one; nothing migrates automatically.
