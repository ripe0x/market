# Deployment and integration reference

## Where Market is deployed

| Chain | Chain ID | Status |
| --- | --- | --- |
| Ethereum Sepolia | 11155111 | **Not deployed.** Rehearsed on a Sepolia fork; the broadcast needs a funded signer (see "Sepolia") |
| Ethereum mainnet | 1 | **Not deployed.** Simulated on a mainnet fork. Needs the release checklist below and the owner's explicit approval |

When a deployment happens, record it in the table under "Deployment record".

## Addresses

Every contract deploys through the standard CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("market.v1")` and has no owner. The addresses depend only on the bytecode, so they are the same on every chain and anyone can deploy them. **Any code change, including a comment, changes the bytecode metadata and therefore the address.** The addresses below are for the code at the commit that last updated this table; `forge script script/Deploy.s.sol` prints the current ones without sending anything.

| Contract | Address | Constructor |
| --- | --- | --- |
| `Market` | `0x8210144750E6237740bf71b819f87A834905445d` | none |
| `Order` implementation (created by Market) | `0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87` | none |
| `NFTSale` | `0x5fBD07DfdC29Daf4f06410Bf09f6E6aab2e41d99` | none |
| `NFTBid` | `0xdc069eEA8618fFBF21f0f0ccc8fB297505BDBe34` | `Market` address |
| `FillVerifier` | `0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0` | none |
| `PaintAction` (example) | `0x1774054Ecd316721E7b5B413cAC384CEfAF51380` | none |
| `DutchAuction` (example) | `0x555faA1724333e645659b55E4925Aebb709BF94E` | none |
| `TokenExchange` (example) | `0x4833FFEdF7592746c0F2b12192e70EA0d64FB702` | none |
| `AcquisitionBid` (example) | `0x7c4777DB44bf712fC3F9e32a002FddBcFE015e5C` | none |
| `RisingStrategy` (example) | `0x045057655f12C5885562C39c5A159Fb3c3aBCEea` | none |
| `CapitalShareStrategy` (example) | `0x750Ff0AE5272aacD6105584c81bDe083644dd189` | none |

Orders are 149-byte ERC-1167 clones of the implementation. Their terms are the last 104 bytes of their code; read them with `owner()`, `handler()`, `handlerCodehash()` and `configHash()`. Their full config is in `Market.Created`.

## Scripts

| Script | What it does | Sends transactions |
| --- | --- | --- |
| [`script/Deploy.s.sol`](../script/Deploy.s.sol) | Deploys everything above; skips contracts already deployed, so a partial run can be resumed | Only with `--broadcast` |
| [`script/Lifecycle.s.sol`](../script/Lifecycle.s.sol) | From one account: a test ERC2981 collection, a fixed-price sale with royalty, a falling sale cancelled and recovered, a persistent rising bid filled twice and topped up, and the PaintAction example. `recover(address)` then cancels the bid and withdraws what it holds | Only with `--broadcast`; about 0.012 ETH plus gas |
| [`script/rehearse.sh`](../script/rehearse.sh) | Runs Deploy, Lifecycle and recover on a throwaway anvil fork (Sepolia by default; pass a mainnet RPC for mainnet) from anvil's unlocked account | Only to the local fork |
| [`script/demo.sh`](../script/demo.sh) | Runs the four teaching examples on a fresh local anvil | Only to local anvil |

Signing: use a Foundry keystore (`--account <name>`), a hardware wallet (`--ledger`) or another signer flag. Never put a private key in a command, file or environment variable that is logged.

## Simulate

```bash
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

```bash
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co
```

## Rehearse on a fork

```bash
script/rehearse.sh
```

```bash
script/rehearse.sh https://mainnet.gateway.tenderly.co
```

## Sepolia

Prerequisites: a keystore whose account holds at least 0.05 Sepolia ETH, and `ETHERSCAN_API_KEY` for verification (Etherscan's v2 API key works for Sepolia).

1. Deploy and verify:

   ```bash
   forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account <keystore> --broadcast --verify --slow
   ```

2. Run the lifecycle with real transactions, then cancel the bid it prints:

   ```bash
   forge script script/Lifecycle.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account <keystore> --broadcast --slow
   ```

   ```bash
   forge script script/Lifecycle.s.sol --sig "recover(address)" <bid order> --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account <keystore> --broadcast
   ```

3. Record chain ID, addresses, transaction hashes (in `broadcast/*/11155111/run-latest.json`) and explorer links under "Deployment record".

If `--verify` misses a contract, verify it directly:

```bash
forge verify-contract 0x8210144750E6237740bf71b819f87A834905445d src/Market.sol:Market --chain sepolia --watch
```

```bash
forge verify-contract 0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87 src/Order.sol:Order --chain sepolia --watch
```

```bash
forge verify-contract 0xdc069eEA8618fFBF21f0f0ccc8fB297505BDBe34 handlers/NFTBid.sol:NFTBid --chain sepolia --constructor-args $(cast abi-encode "f(address)" 0x8210144750E6237740bf71b819f87A834905445d) --watch
```

The other contracts take no constructor arguments: `forge verify-contract <address> <path>:<Name> --chain sepolia --watch`. Order clones need no verification; explorers that recognize ERC-1167 show them as proxies of the verified implementation.

## Mainnet release checklist

Mainnet deployment needs the owner's explicit approval after every item is satisfied. Status on 2026-11-06 in brackets.

1. Freeze a release candidate commit; no code change after it without restarting this list. [Not frozen]
2. `CANDIDATE_RUN=1 forge test` passes at the candidate, including fork tests. [Passed at the commit recorded in STATUS.md]
3. Invariant campaigns at higher depth than CI (`FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-test invariant`). [See STATUS.md]
4. Static analysis reviewed (Slither or equivalent). [See STATUS.md]
5. Independent human security audit of `src/`, `handlers/` and `periphery/`, with findings resolved. [**Not done**]
6. All Owner review items in DECISIONS.md decided, in particular finding A1 for the teaching examples. [Open]
7. Decide which contracts mainnet gets. Recommended: `Market`, `NFTSale`, `NFTBid`, `FillVerifier`; teaching examples only if their warnings are acceptable. [Open]
8. Sepolia deployment and lifecycle executed with real transactions and recorded below. [Blocked on a funded signer]
9. `script/rehearse.sh https://mainnet.gateway.tenderly.co` passes at the candidate; compare printed addresses with the table above. [Passed on the feature branch; repeat at the candidate]
10. Signer: a keystore or hardware wallet holding only the deployment gas. Estimate from the simulation (about 7,000,000 gas for all contracts).
11. Deploy with `--broadcast --verify --slow`, confirm every address has the expected code hash, then record it below.
12. Do not create value-bearing orders from the deployer; nothing about the deployer is privileged afterwards.

## Deployment record

| Chain | Chain ID | Commit | Contract | Address | Deploy transaction | Explorer |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |

No deployment has been broadcast.
