# Deployment and integration reference

## Where Market is deployed

| Chain | Chain ID | Status |
| --- | --- | --- |
| Ethereum Sepolia | 11155111 | **Partial, from an earlier candidate.** `Market`, its `Order` implementation and `FillVerifier` are deployed at the supported addresses below and verified on Sourcify. `NFTSale` and `NFTBid` of this release are **not** deployed. The contracts deployed on 2026-11-06 at other addresses are obsolete (see "Deployment record") |
| Ethereum mainnet | 1 | **Not deployed.** Simulated only. Needs the release checklist below and the owner's explicit approval |

## Addresses

Every contract deploys through the standard CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("market.v1")` and has no owner. The address depends only on the bytecode (and constructor argument), so it is the same on every chain and anyone can deploy it. **Any change to a contract's Solidity source, including a comment, changes its metadata and therefore its address.** `forge script script/Deploy.s.sol` prints the current addresses without sending anything.

Supported release (`forge script script/Deploy.s.sol`):

| Contract | Address | Constructor |
| --- | --- | --- |
| `Market` | `0x8210144750E6237740bf71b819f87A834905445d` | none |
| `Order` implementation (created by Market) | `0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87` | none |
| `NFTSale` | `0x72649226f648d8a33f8eee78B71e5D9d9e18D9C7` | `Market` address |
| `NFTBid` | `0x0FeE65df72d3194b07235D275b60269E15FC1445` | `Market` address |
| `FillVerifier` (optional) | `0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0` | none |

Example, deployed separately (`forge script script/Deploy.s.sol --sig "examples()"`), not part of the supported release:

| Contract | Address | Constructor |
| --- | --- | --- |
| `PaintAction` | `0x2e8341791F5c1c44313dd2c3e43dF6476756B237` | none |

Orders are 149-byte ERC-1167 clones of the implementation. Their terms are the last 104 bytes of their code; read them with `owner()`, `handler()`, `handlerCodehash()` and `configHash()`. Their full config is in `Market.Created`.

## Deployment gas

Estimated by `forge script` against mainnet state (`--rpc-url https://mainnet.gateway.tenderly.co`, simulation only), 2026-11-10:

| Script | Contracts | Gas |
| --- | --- | --- |
| Previous `Deploy.s.sol` (PR #4 before this revision) | Market, implementation, NFTSale, NFTBid, FillVerifier, PaintAction, DutchAuction, TokenExchange, AcquisitionBid, RisingStrategy, CapitalShareStrategy | 6,704,108 |
| `Deploy.s.sol` | Market, implementation, NFTSale, NFTBid, FillVerifier | 3,682,037 (45% less) |
| `Deploy.s.sol --sig "examples()"` | PaintAction | 424,083 |

On a chain where `Market` and `FillVerifier` already exist (Sepolia today), the script skips them; the Sepolia fork rehearsal estimated 2,149,943 gas for `NFTSale` and `NFTBid`.

## Scripts

| Script | What it does | Sends transactions |
| --- | --- | --- |
| [`script/Deploy.s.sol`](../script/Deploy.s.sol) | `run()`: the supported release. `examples()`: PaintAction. Skips contracts already deployed, so a partial run resumes and a repeat sends nothing | Only with `--broadcast` |
| [`script/Lifecycle.s.sol`](../script/Lifecycle.s.sol) | From one account: a test ERC2981 collection, a fixed-price sale with royalty, a falling sale cancelled and recovered, a persistent rising bid filled twice and topped up, and the PaintAction example. `recover(address)` then cancels the bid and withdraws what it holds | Only with `--broadcast`; about 0.012 ETH plus gas |
| [`script/rehearse.sh`](../script/rehearse.sh) | Runs Deploy, examples, Lifecycle and recover on a throwaway anvil fork (Sepolia by default; pass a mainnet RPC for mainnet) from anvil's unlocked account | Only to the local fork |

Deploy only from an up-to-date `main` checkout, with the owner's Foundry keystore `ripe0x` (`--account ripe0x`; `cast wallet address --account ripe0x` prints its address for `--sender`). Use Tenderly's public gateways: `https://sepolia.gateway.tenderly.co` and `https://mainnet.gateway.tenderly.co`. Every broadcast needs the owner's confirmation immediately before it, after a dry run from the same signer; read back the receipt and state before the next one. Never put a private key in a command, file or environment variable.

## Simulate

```bash
forge script script/Deploy.s.sol --rpc-url https://sepolia.gateway.tenderly.co
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

Prerequisites: a `main` checkout (`git checkout main && git pull --ff-only`), the `ripe0x` keystore holding at least 0.05 Sepolia ETH, and `ETHERSCAN_API_KEY` for Etherscan verification (Etherscan's v2 key works for Sepolia).

1. Deploy and verify the supported release (Market and FillVerifier are skipped where they exist), then the example:

   ```bash
   forge script script/Deploy.s.sol --rpc-url https://sepolia.gateway.tenderly.co --account ripe0x --sender <ripe0x address> --broadcast --verify --slow --gas-estimate-multiplier 1500
   ```

   ```bash
   forge script script/Deploy.s.sol --sig "examples()" --rpc-url https://sepolia.gateway.tenderly.co --account ripe0x --sender <ripe0x address> --broadcast --verify --slow --gas-estimate-multiplier 1500
   ```

2. Run the lifecycle with real transactions, then cancel the bid it prints:

   ```bash
   forge script script/Lifecycle.s.sol --rpc-url https://sepolia.gateway.tenderly.co --account ripe0x --sender <ripe0x address> --broadcast --slow --gas-estimate-multiplier 1500
   ```

   ```bash
   forge script script/Lifecycle.s.sol --sig "recover(address)" <bid order> --rpc-url https://sepolia.gateway.tenderly.co --account ripe0x --sender <ripe0x address> --broadcast --gas-estimate-multiplier 1500
   ```

3. Record chain ID, addresses, transaction hashes (in `broadcast/*/11155111/run-latest.json`) and explorer links under "Deployment record".

**Why `--gas-estimate-multiplier 1500`.** On 2026-11-06 the first Sepolia deployment attempt used Foundry's default gas limits and ran out of gas (see the record below); the node estimated far more gas for contract creation than Foundry's EVM (5,775,008 against 826,340 for Market). The multiplier sets each limit at 15 times Foundry's estimate; unused gas is not charged. Mainnet needs no multiplier.

If `--verify` misses a contract, verify it directly:

```bash
forge verify-contract 0x72649226f648d8a33f8eee78B71e5D9d9e18D9C7 handlers/NFTSale.sol:NFTSale --chain sepolia --constructor-args $(cast abi-encode "f(address)" 0x8210144750E6237740bf71b819f87A834905445d) --watch
```

```bash
forge verify-contract 0x0FeE65df72d3194b07235D275b60269E15FC1445 handlers/NFTBid.sol:NFTBid --chain sepolia --constructor-args $(cast abi-encode "f(address)" 0x8210144750E6237740bf71b819f87A834905445d) --watch
```

`PaintAction` takes no constructor arguments: `forge verify-contract <address> examples/PaintAction.sol:PaintAction --chain sepolia --watch`. Order clones need no verification; explorers that recognize ERC-1167 show them as proxies of the verified implementation.

## Mainnet release checklist

Mainnet deployment needs the owner's explicit approval after every item is satisfied. Status on 2026-11-10 in brackets.

1. Freeze a release candidate commit; no Solidity change after it without restarting this list. [Release candidate tagged on `main`; see STATUS.md]
2. `CANDIDATE_RUN=1 forge test` passes at the candidate, including fork tests. [See STATUS.md]
3. Invariant campaigns at higher depth than CI (`FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-path test/Invariant.t.sol`). [Passed on the release code; STATUS.md]
4. Static analysis reviewed. [Slither, none actionable; STATUS.md]
5. **Independent human security audit** of `src/`, `handlers/` and `periphery/`, with findings resolved. [**Not done**]
6. Owner review items in DECISIONS.md decided (1, 3, 4, 7, 8). [Open]
7. Contracts for mainnet: `Market`, `NFTSale`, `NFTBid`, `FillVerifier` (D301). `PaintAction` only if wanted as a public example. [Decided by D301; owner to confirm]
8. Sepolia deployment of this release and the lifecycle executed with real transactions, recorded below. [**Blocked on a funded signer for this project**]
9. `script/rehearse.sh https://mainnet.gateway.tenderly.co` passes at the candidate; compare printed addresses with the table above. [See STATUS.md]
10. Signer: a keystore or hardware wallet holding only the deployment gas (about 3,700,000 gas for the supported release at current prices).
11. Deploy with `--broadcast --verify --slow`, confirm every address has the expected code hash, then record it below.
12. Do not create value-bearing orders from the deployer; nothing about the deployer is privileged afterwards.

## Deployment record

### Sepolia, 2026-11-06 (earlier candidate, PR #4 before the simplification review)

Signer `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, the owner's account (confirmed by the owner on 2026-11-10). It is not recorded in any local keystore's address field. These transactions were missing from the documentation until 2026-11-10, which then said nothing had been broadcast. Transaction data read from Sepolia on 2026-11-10.

| Block | Nonce | Transaction | Result | Gas used | Contract deployed |
| --- | --- | --- | --- | --- | --- |
| 12,078,283 | 5832 | `0xc216fbee9d3b87b6aeac0f91deec301a9aa65002193f8f40917166f55f44a52e` | **Reverted** (out of gas, nothing deployed) | 750,254 | none |
| 12,078,304 | 5833 | `0x728d014dc1e88e3fc6b4454a57f8db805472d1bd06d93495b7c0c04cbe406c80` | Success | 5,683,482 | `Market` `0x8210…445d` and implementation `0xB11F…0f87` (current, Sourcify exact match) |
| 12,078,305 | 5834 | `0x1e617be2f4cd5f05fd66e3e16e1eb2440be4051c8f9b266e628cb5fc5ab98137` | Success | 4,631,969 | old `NFTSale` `0x5fBD07DfdC29Daf4f06410Bf09f6E6aab2e41d99` (obsolete: no S1 fix) |
| 12,078,306 | 5835 | `0x1e7227fbee745c29a4bd158a08ce9466795423d8be33d8cba531fb2533d82917` | Success | 5,517,086 | old `NFTBid` `0xdc069eEA8618fFBF21f0f0ccc8fB297505BDBe34` (obsolete) |
| 12,078,307 | 5836 | `0x7a8ee03ed8b5dfcb49d048223c8cee9e42f14c2a861a17d4fd9228d97161c888` | Success | 1,847,814 | `FillVerifier` `0x9e30…99C0` (current, Sourcify exact match) |
| 12,078,308 to 12,078,313 | 5837 to 5842 | `0x63c8e131…89d6`, `0xcb9dd00e…b678`, `0xd4f1f978…c9bd`, `0x765389ab…9ea0`, `0x2c3e5ef6…e787`, `0x2c82fcd3…1573` | Success | 2,729,820 to 567,402 | old `PaintAction`, `DutchAuction`, `TokenExchange`, `AcquisitionBid`, `RisingStrategy`, `CapitalShareStrategy` (all obsolete; the last four removed in D301) |

No lifecycle transactions followed from this account. The obsolete contracts cannot be removed; they have no owner and hold nothing, but `TokenExchange` and `AcquisitionBid` keep the approval-to-order pattern (A1). Do not use any address in this section except `Market`, the implementation and `FillVerifier`.

### This release

| Chain | Chain ID | Commit | Contract | Address | Deploy transaction | Explorer |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |

`NFTSale` and `NFTBid` of this release have not been broadcast on any chain.
