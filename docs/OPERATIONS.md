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
forge test --match-path test/MatchOffer.t.sol
```

```bash
forge test --match-path test/Buy.t.sol
```

```bash
forge test --match-path test/Adversarial.t.sol
```

```bash
cd app && npm test
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
PROTOCOL_FEE_RECIPIENT=0xYourRecipient forge script script/Deploy.s.sol --rpc-url mainnet
```

Simulates against mainnet and prints the address and gas (about 2.34M gas). No broadcast.

## Deploy (mainnet, owner authorized only)

1. Freeze the candidate commit; run the full suite with `CANDIDATE_RUN=1`; complete the independent audit.
2. Choose the protocol fee recipient (a Safe is recommended). It cannot be changed later.
3. Import the deployer key into a Foundry keystore (`cast wallet import deployer --interactive`). Never pass a key on the command line.
4. Broadcast:

```bash
PROTOCOL_FEE_RECIPIENT=0xRecipient forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --broadcast --verify
```

5. Verify, then record in `STATUS.md`:
   - `cast code <market>` is non-empty and matches `out/Market.sol/Market.json` deployed bytecode except immutables
   - `cast call <market> "PROTOCOL_FEE_RECIPIENT()(address)"` equals the chosen recipient
   - `cast call <market> "SEAPORT()(address)"` is `0x0000000000000068F116a894984e2DB1123eB395`
   - `cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 "allowance(address,address)(uint256)" <market> 0x0000000000000068F116a894984e2DB1123eB395` is max
   - Source verified on Etherscan
6. Run the OpenSea fulfiller check from `PHASE0_EVIDENCE.md` with the real address before enabling the keeper.

## Run in production

One host with a persistent disk. Copy `app/.env.example` to the host's environment; inject `OPENSEA_API_KEY` and `KEEPER_PRIVATE_KEY` from its secret store.

```bash
cd app && npm run build && npm start
```

```bash
cd app && npm run keeper
```

The keeper logs one JSON line per event: `start`, `sale`, `skip` (with reason), `submitted`, `confirmed`, `reverted`, `replaced`, `cancel_sent`, `simulation_failed`, `round_failed`. Alert on repeated `round_failed` or `reverted`.

Stop the keeper with SIGINT or SIGTERM; it finishes the current round. Stopping it never blocks sellers (cancel goes straight to Seaport) or buyers (buy goes straight to Market).

## Keeper wallet

Holds only ETH for gas; it never holds NFTs or user funds. Fund it with a small float and top up. Executor fees arrive as WETH. If the key leaks, the loss is the gas float and future executor fees; rotate the key and restart.

## Backup

The database holds signed listings (needed to show and match them), synced sales and keeper attempts. Sales can be rebuilt from chain by resetting `synced_block`; signed listings cannot.

```bash
sqlite3 "$DB_PATH" ".backup '/backups/market-$(date +%F).db'"
```

## Emergencies

There is no pause and no admin. Options:

- Stop the keeper.
- Take the web app down or hide affected listings.
- Sellers cancel through the app or directly with `Seaport.cancel` / `Seaport.incrementCounter`; revoking the OpenSea conduit approval also stops fills.
- A fix ships as a new Market deployment. Old listings remain bound to the old zone until they end or are cancelled; tell sellers to cancel.
