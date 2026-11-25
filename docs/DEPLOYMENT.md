# Deployment and integration reference

## Where Market is deployed

| Chain | Chain ID | Status |
| --- | --- | --- |
| Local simulation | 31337 | Unified action candidate implemented here; **not deployed** to any public chain |
| Ethereum Sepolia | 11155111 | **Current candidate (D512) deployed 2026-11-25**, blocks 12,211,840 to 12,211,844, at the addresses below; FeeConfig and FillVerifier reused from the earlier deployment (STATUS.md). The superseded pre-D512 contracts listed under the table remain live on Sepolia, as does the legacy order-only release of 2026-11-16. |
| Ethereum mainnet | 1 | **Not deployed.** Any future deployment needs a frozen candidate, rehearsal, review and the owner's explicit approval. |

## Unified action candidate addresses, 2026-11-25 (D512)

Frozen production source: `45492b9aa6f7bdfe232a5f174fe5f76d59d414c7`. Salt `keccak256("market.actions.v1")`, standard CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, FeeConfig admin `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, fee recipient `0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72`. Computed by `forge script script/Deploy.s.sol` (simulation). **Not deployed on any public chain.** These addresses run different code from every earlier table below; never attach the new ABI to an earlier address.

| Contract | Computed address | keccak of compiler runtime (immutables unfilled) |
| --- | --- | --- |
| Market | `0x54c0c040d5197FEdE18fDc5A0De5196956553113` | `0x5584fada1c628bae192c9e363ac2ef67fd82285340e2dc068241e7563cbad5da` |
| Order implementation (created by Market) | `0x17743de18585b9C52f2493751420e3a30a867034` | `0x58bbe8625a478a3c0f9290bff9d0731631de87a7d2e62272f788fdd34fe7c6c4` |
| Actions (created by Market) | `0xa51f16052f65684c2460e78D364C19fAEF090b55` | `0xb4197ee1d171eb2fefc005fcb276989aaec18ee8da3ef4a847f075c78f3b8634` |
| FeeConfig | `0xab7494a3Af234eEFC55C6de6D824A9c1ffc7B179` | `0xb22a316734ba058e071db380bef6d9da389f8ebbf771f14341eb65f7853fa3dd` |
| ExchangeAction | `0x9Af710E45D873d82920056044D4cb165A213A9E9` | `0xf7b68e1576d2f193dc3d489f32ad312fdd8a989fd06a9ef6e512ca299dd5001e` |
| CoveredNFTPurchase | `0x73416c9c0eD2F1e3c4dE1796fDdc10F46E10f027` | `0x5cc21b74855961c3b53daec9e25840c08e023265bd5f1fc3464750f4883a1afb` |
| ReservedAction | `0x7d7b12c86AcE74756F80134d71196a840a6bF88c` | `0x30418a3b1a8372ced164a0d4cce0af66efd4173b8bcb65b15241566af411d4d5` |
| AcquireAndExecute | `0xecdf2023D9EF0a4177d3a565360156103529439a` | `0xfe28e952cda3624f49b1511e632cd866034f8b7845718e340809f5f90062ee4d` |
| FillVerifier | `0x255445e486aFe67a7265470cfA802f0EcFb8c07B` | `0x5c467510a657e1ae31365a293d1afc917aaa5a7e5fc5d2315c3160015d37734b` |

Contracts with immutables have different onchain code hashes; the client generates those from a deployed local instance. `script/rehearse.sh` deploys the set and runs `script/ActionsLifecycle.s.sol` on a throwaway local Anvil. The earlier rights candidate and order-only tables below are historical.

Superseded by D512 (deployed on Sepolia 2026-11-25 at blocks 12,211,383 to 12,211,389, still live there): Market `0xE1a93Fae037fB7c609c17c88392d3BD24d4c9762`, Order implementation `0xC3052D0bc6130B6215EbC917cE2fF373ff23e96b`, Actions `0x63A21B9aB7A8eea6F40cE35a5F7173426A55f575`, ExchangeAction `0xE2dB9EcB01D48b3332302E189eA27DE8e6d05b46`, CoveredNFTPurchase `0x11A989E25B23D565D332469fa0Ceb06C171ca053`, ReservedAction `0x138294386660f95c5A61B5AF78A1c802322aB82b`, AcquireAndExecute `0xDFE0B731734BB27A80a229712b233c3B1431E00d`. FeeConfig and FillVerifier are unchanged and shared.

## Scripts

| Script | What it does | Sends transactions |
| --- | --- | --- |
| [`script/Deploy.s.sol`](../script/Deploy.s.sol) | `run()`: Market (which creates the Order implementation and Actions), FeeConfig, ExchangeAction, CoveredNFTPurchase, ReservedAction, AcquireAndExecute, FillVerifier through the standard CREATE2 deployer. `examples()`: the Artwork reservation target. Skips addresses already holding code. | Only with `--broadcast` |
| [`script/ActionsLifecycle.s.sol`](../script/ActionsLifecycle.s.sol) | Local simulated lifecycles: sale, bid, covered purchase with resale and atomic acquire, reserved Artwork change, recovery. | No public broadcast path |
| [`script/rehearse.sh`](../script/rehearse.sh) | Deploys `run()` and `examples()` on a throwaway Anvil (plain, or a fork of the RPC given) from Anvil's unlocked account, then runs the lifecycle simulation. | Only to the local node |

```bash
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co --sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9   # simulation only
```

```bash
script/rehearse.sh https://mainnet.gateway.tenderly.co
```

## Release path for the unified action candidate

Deploy only from an up-to-date `main`, with the Foundry keystore `ripe0x` (`--account ripe0x`) and Tenderly's public gateways. Never put a private key in a command, file or environment variable. Each public broadcast needs the owner's explicit approval immediately before it, with the decoded target, chain, signer, actions, value and gas shown.

| Gate | Status |
| --- | --- |
| Frozen candidate, whole suite, fork tests, invariants 1000 x 128, static analysis | Done at `45492b9` / `9f50355` (STATUS.md) |
| Merged to `main` | Done 2026-11-25, merge commit `c671b3c` |
| Owner-approved outcome numbers and one-screen economic scorecard | Draft in [RELEASE.md](RELEASE.md); needs owner approval |
| Independent external audit, findings resolved | Not done |
| Mainnet-fork rehearsal of `Deploy.run()` and lifecycle; read-only mainnet dry run | Done 2026-11-25, same addresses, 14,341,828 gas (STATUS.md) |
| Sepolia deployment with `ripe0x`, postflight readback of every address and relationship, real-transaction lifecycle, indexer and web against it, real wallet extension | Deployed and read back 2026-11-25 (start block 12,211,383; deploy with `-g 900`, see STATUS.md). Lifecycle, indexer, web and wallet not done |
| Mainnet deployment, readback, small-value canary lifecycle compared with the scorecard | Not done; needs owner approval |

Postflight for each deployment: code exists at every computed address; `Market.implementation()`, `Market.actions()`, `Actions.market()`, the Order implementation's `market()` and `actions()`, each action's `market()`, `ExchangeAction.fees()` and `actions()`, `AcquireAndExecute.market()`, `actions()`, `exchange()` and `covered()`; `FeeConfig.admin()`, `recipient()`, `feeBps()`; runtime code hashes match the client manifest. Record transaction hashes, blocks and gas here.

The core has no admin, caps or pause. A canary therefore limits only its own use (small orders by the owner); anyone can use the deployment at full size from its first block.

---

# Historical releases (superseded; not the current code)

Everything below describes earlier designs and their Sepolia releases. Their addresses, scripts and commands do not apply to the unified action contracts.

## Transferable rights candidate addresses (superseded)

Current compiled source: `cf7f48d8fae716740c59f882dcc2761497c2a63b`. All addresses below are computed candidates and remain undeployed publicly. The client rights manifests contain their runtime hashes and relationships; Sepolia startBlock is null.

| Contract | Current computed candidate |
| --- | --- |
| market | `0x5796242872BCAA3Fb0e16a4388c70f2e80aB966c` |
| orderImplementation | `0xaCbCDc61A784784a6290cFD03B4bE69276D25DE2` |
| rightImplementation | `0x6fBf0eB3B39e5841c5a42B78419585d079413C27` |
| rights | `0x342589F108327aF8809D02F52304852BF6C76382` |
| feeConfig | `0x89Af00fB84a9352408B8249e9cb8438533751783` |
| nftSale | `0x14EBFFd2Df1BF321dD782fE41D1c436805A6b7ad` |
| nftBid | `0xB2A1649B4DFD9f02cdc8bFEdeAa45a33F8b5C8e5` |
| coveredNFTPurchase | `0xE0eF13aD270d514580D01cEd6f5716A3D7B8B569` |
| fillVerifier | `0x84042d827d30DB1eF9cE21477ebb6c83CDB04430` |

### Superseded metadata-only candidate, 2026-11-17

The new `Market` creates an `Order` implementation, a `Right` implementation and canonical `Rights` ERC721. The supported deployment script also creates `CoveredNFTPurchase`, updated `NFTSale` and `NFTBid`, `FeeConfig` and `FillVerifier`; its `examples()` path adds `PaintAction` and `ReservedPaint`. **No redesigned address is deployed on Sepolia or mainnet.** Run `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` without `--broadcast` to calculate candidate addresses only after the final bytecode is frozen. The result may change with any source or compiler input change; do not use the old table as an address source.

`Market.rights()` and `Market.rightImplementation()` identify the canonical token and backing implementation. `Market.rightAddress(issuer, handler, configHash, deadline, residual, salt)` predicts an individual backing account; verify `Market.isRight(account)` before relying on it. `Rights.accountOf(tokenId)` authenticates a Market-created account. Each right publishes its config in `RightCreated`; its activation terms, deadline, state and residual beneficiary can be read from the account.

The previous metadata-only bytecode had these **superseded, computed, undeployed** candidate addresses. The client manifest records the exact source pin, runtime hashes and relationships. A documentation-only commit does not change these addresses.

| Contract | Computed candidate |
| --- | --- |
| market | `0x2EEd41b789fC4D812fB7d2b19a40FF21851Ada95` |
| orderImplementation | `0x5c6faF50236c460849314c302198Ed382E65f6Ee` |
| rightImplementation | `0x038E2C2b4448021525dd3EB0e3385b447e43e4e5` |
| rights | `0x7d3AB35412fF49921A60eAf921a1f6A3c5F83b5b` |
| feeConfig | `0xa4c8dC554170d3016aeC36441F5F465BbAb816B0` |
| nftSale | `0x60C4c83bB2EAdd73D2669dC180587FB4e4a9393C` |
| nftBid | `0xea19021Fd9d418874e146C1dA167C234D08f33f4` |
| coveredNFTPurchase | `0xe9f8bf0e002Ef25dCa9c5490186191aB93E2184c` |
| fillVerifier | `0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0` |

### Rights candidate: Sepolia preparation and release gate

The current production source is frozen at `cf7f48d8fae716740c59f882dcc2761497c2a63b`, superseding metadata-only source `91b22d3`. The client pins the final protocol revision in `contracts/market` and records its exact commit, resulting addresses and runtime hashes in `deployments/rights-sepolia.json`. That manifest is a **candidate** with `startBlock: null`; its addresses are calculations, not a claim that code exists on Sepolia. `deployments/legacy-sepolia.json` remains the verified order-only production release at block 12,150,229. The client defaults to legacy on public Sepolia; selecting `rights-v1` does not make the candidate live. Regenerate the rights manifests only from the frozen source and inspect the diff; generation starts a private Anvil, not a public transaction.

1. Freeze the source and client revision. Verify the submodule points to the intended protocol commit, compiler settings, planned CREATE2 addresses, fee admin and recipient. Run the client `pnpm --filter @market/protocol gen`, then compare its rights manifests with the simulated deployment output. Never rewrite the legacy manifest from the new build.
2. Rehearse the *same* `Deploy.run()` path on a disposable local Sepolia fork. Check chain endpoint, the `ripe0x` signer identity, existing code at each predicted address, decoded constructor arguments, gas funding, receipts and post-state. Run a separate signer-specific Sepolia dry run after the build is warm, with no broadcast:

   ```bash
   forge script script/Deploy.s.sol:Deploy --sig 'run()' \
     --rpc-url https://sepolia.gateway.tenderly.co --account ripe0x
   ```

3. Compare the dry run to the candidate manifest. Confirm every predicted runtime code hash and relationship: `Market.implementation`, `Market.rightImplementation`, `Market.rights`, `Rights.market`, the Right implementation's Market/Rights bindings, `CoveredNFTPurchase.market`, `FeeConfig.market`, and each trading handler's `fees` and canonical rights collection. Confirm fee rate, fee recipient and admin. A partial deployment requires receipt and nonce reconciliation before any continuation.
4. **Stop for explicit owner authorization immediately before each public broadcast.** Present the actual target, Sepolia chain, `ripe0x` signer, decoded deployment actions, native value, gas estimate and consequence. The authorized broadcast would use the same script and signer with `--broadcast --slow --verify`; no such command has run for rights. After each receipt, read code hashes and relationships from chain and record transaction hashes, block numbers and gas. A failed verification service is separate from transaction success.
5. Only after those readbacks, set `deployments/rights-sepolia.json` to `status: "deployed"` with the actual Market deployment block. Start the rights indexer with `PONDER_RELEASE_ID=rights-v1`, `PONDER_CHAIN_ID=11155111`, an isolated `DATABASE_SCHEMA=market_rights_v1`, and the Tenderly public Sepolia RPC. Wait for `/api/status` to report the exact `deploymentId`, `releaseId`, chain ID, ready state and indexed head; verify right events and token ownership against chain. Keep the legacy indexer and `market_v1` schema intact.
6. Select the rights release in a separate web deployment using `NEXT_PUBLIC_MARKET_RELEASE=rights-v1` and `NEXT_PUBLIC_CHAIN_ID=11155111`, pointing to the isolated rights indexer. Verify the UI's runtime hash guard and a signed user walkthrough: issue and activate a covered right, list, buy, resell, exercise, release credits; cancel a separate listing, expire and recover another right. Inspect token and backing ownership, deadlines, ETH splits and receipts at each step. Preserve a working legacy URL and indexer while this candidate is evaluated. Public walkthrough transactions also need their own explicit owner authorization.

The signed local rehearsal is reproducible with `pnpm --filter @market/protocol rehearse:rights` in the client. Its `packages/protocol/evidence/rights-local.json` records 47 actual Anvil transactions at chain 31337, 46 successes and one intended reverted AtomicWallet issuance that left no created right or NFT deposit. The 0.2/0.3 ETH premium sales sent 0.198/0.297 ETH to their respective sellers and 0.005 ETH total trading fees; 1 ETH exercise credited 0.95 ETH proceeds and 0.05 ETH royalty. These are local receipts with nonzero gas prices, not Sepolia transactions. The protocol's Foundry lifecycle script below is a separate simulation.

## Historical order-only addresses (superseded for new rights)

## Addresses

The top-level contracts in the 2026-11-16 release used the standard CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("market.v1")`; `Market` itself created the `Order` implementation. Their addresses depended on their bytecode and constructor arguments. **Any source change, including a comment, can change metadata and therefore an address.** The current `forge script script/Deploy.s.sol` prints new right-enabled addresses, not the historical table below. `foundry.toml` fixes remappings (`auto_detect_remappings = false`) because they affect metadata; before that fix, a checkout with OpenZeppelin's nested submodules compiled to different addresses (found 2026-11-10).

The 2026-11-16 order-only release used these addresses on Sepolia. They are **not** the current source's addresses. The creation-time core change (D306) had altered `Market`'s bytecode and the fee terms moved into `FeeConfig` (D309). The earlier addresses remain here solely for historical readback and reproduction of that deployment.

| Contract | Address | Constructor |
| --- | --- | --- |
| `Market` | `0x7c91e34703ae3E32812bad1f7251CD0976A31FD4`. Before D306: `0x8210144750E6237740bf71b819f87A834905445d` | none |
| `Order` implementation (created by Market) | `0x1c8Af1349Fa2b41903291675DCf5e9dfc2A8fB83`. Before: `0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87` | none |
| `FeeConfig` | `0x9A181B2129540Df9502a30e08a4E4e34Cd7406fF` | `Market` address, `FEE_ADMIN`, `FEE_TO` (in `script/Deploy.s.sol`) |
| `NFTSale` | `0xfEf3a72600a453F82650343525751811120da2c8`. Before: `0x72649226f648d8a33f8eee78B71e5D9d9e18D9C7` | `FeeConfig` address |
| `NFTBid` | `0x8dbB30441bB0ca607bC17A3ea763C8f66B30017E`. Before: `0x0FeE65df72d3194b07235D275b60269E15FC1445` | `FeeConfig` address |
| `FillVerifier` (optional) | Unchanged: `0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0` | none |

Example, deployed separately (`forge script script/Deploy.s.sol --sig "examples()"`), not part of the supported release:

| Contract | Address | Constructor |
| --- | --- | --- |
| `PaintAction` | `0x2e8341791F5c1c44313dd2c3e43dF6476756B237` | none |

The historical order-only deployment's orders are 149-byte ERC-1167 clones of their implementation. Their terms are the last 104 bytes of their code; read them with `owner()`, `handler()`, `handlerCodehash()` and `configHash()`. Their full config is in `Market.Created`.

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

### Fee release, Sepolia, 2026-11-16

Deployed from code identical to `main` at `d6b2073` (the merge of PR #13): the owner ran the broadcast from the `feat/settable-fee` worktree at `58d83a2`, whose `src`, `handlers`, `periphery`, `script` and `foundry.toml` have no diff from `main`, and every address matched the dry run from `main`. Signer `ripe0x` (`0xCB43…17F9`), `https://sepolia.gateway.tenderly.co`, one broadcast of 4 transactions, 21,064,711 gas at about 0.51 gwei, 0.000000010760487326 ETH. `FillVerifier` was already deployed and skipped.

| Contract | Address | Transaction | Block | Gas | Verified |
| --- | --- | --- | --- | --- | --- |
| `Market` | `0x7c91e34703ae3E32812bad1f7251CD0976A31FD4` | [`0x387a6ddc…`](https://evm.now/tx/0x387a6ddc8ccc24f117796329a534f90b6cd88ac23b35366efba256dba614ae47?chainId=11155111) | 12,150,229 | 5,810,324 | Etherscan, Sourcify |
| `Order` implementation | `0x1c8Af1349Fa2b41903291675DCf5e9dfc2A8fB83` | same | 12,150,229 | | Etherscan, Sourcify |
| `FeeConfig` | `0x9A181B2129540Df9502a30e08a4E4e34Cd7406fF` | [`0xbc6b2ed1…`](https://evm.now/tx/0xbc6b2ed1ff5e3b668de461c4ac2b3fe2e989a22cf750af2dc49fe421d376e931?chainId=11155111) | 12,150,230 | 3,606,867 | Etherscan, Sourcify |
| `NFTSale` | `0xfEf3a72600a453F82650343525751811120da2c8` | [`0x02a1f378…`](https://evm.now/tx/0x02a1f378eec3387e7dccff2f8e17804ff66d5f640f731243af8a8ebd53f3a4f2?chainId=11155111) | 12,150,232 | 5,670,451 | Etherscan, Sourcify |
| `NFTBid` | `0x8dbB30441bB0ca607bC17A3ea763C8f66B30017E` | [`0x414e1052…`](https://evm.now/tx/0x414e105255574c52be75a10200566391654649ee86223d7f257b0d5a146cb018?chainId=11155111) | 12,150,233 | 5,977,069 | Etherscan, Sourcify |

Read back after the broadcast: runtime sizes 1,359, 2,133, 1,902, 3,520 and 3,718 bytes; `Market.implementation()` is the `Order` above; `FeeConfig` admin `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, no pending admin, recipient `0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72`, `feeBps` 100, `MAX_FEE_BPS` 100, `market` the `Market` above; both handlers' `fees()` is this `FeeConfig`. Sourcify: exact match for all five. Etherscan: four verified in the broadcast; `NFTSale` failed because Etherscan had not indexed it yet and passed on a `forge verify-contract` rerun. `test/fork/SepoliaLive.t.sol` pins block 12,150,234 and runs against these contracts (STATUS.md).

### Arena on the fee release, Sepolia, 2026-11-16

`script/Arena.s.sol` (code identical to `main` at `d6b2073`), arena id 2, start `1794868140`, signer `ripe0x` (`0xCB43…17F9`), Tenderly gateway, each step dry-run first and read back after. Sale order `0xf1eD6996380e0875D8Fa6dC42922178B9081B41c`, bid order `0x5052eD8e7A5274573a73b68b27b42A36abf556a6`; `FeeConfig` locked both at 1%. All 31 transactions succeeded, 28,213,907 gas.

| Broadcast | Nonces | Blocks | Gas | Result |
| --- | --- | --- | --- | --- |
| `setup` | 5905 to 5923 | 12,150,281 to 12,150,299 | 26,168,376 | Parties, collection (5% royalty), matcher, adversary; falling sale and funded rising bid (0.012 ETH, 2 fills) |
| `attack` | 5924 | 12,150,315 | 691,002 | [`0x2600f8c6…`](https://evm.now/tx/0x2600f8c60f986b02f667113f513abc626067ccbb39e843d44297f65d4a616bb0?chainId=11155111): the same 15 attacks as the 2026-11-10 arena, all refused with the same errors (`NotAFill` ×4, `ERC721IncorrectOwner` ×2, `Unauthorized` ×6, `WrongConfig`, `Underpaid`, `OrderClosed`, `ERC721InsufficientApproval`) |
| `settle` | 5925, 5926 | 12,150,385, 12,150,386 | 1,044,305 | [`0xe0eb49e7…`](https://evm.now/tx/0xe0eb49e7a02adcd8277b4446a25955c5319bd36da83768a701ac514f8b2dfcbe?chainId=11155111): matcher buys token 1 from the sale and sells it into the bid; [`0xeb5354a4…`](https://evm.now/tx/0xeb5354a4d8c98eb4abab232f1092815a563eb87d2082b6223886c7094d0e5241?chainId=11155111): holder sells token 2 into the bid, its last fill, which closes it |
| `cleanup` | 5927 to 5935 | 12,150,430 to 12,150,438 | 310,224 | Closed bid's owner tries `transferFrom(holder, …)` (`ERC721InsufficientApproval`) and `NFTBid.onFill` (`NotAFill`), both refused; holder revokes; bid recovered; every party returns its ETH |

Payouts from the `Sold` and `Bought` events, in ETH:

| Trade | Price | Royalty 5% | Fee 1% | Seller |
| --- | --- | --- | --- | --- |
| Sale, token 1 to the matcher | 0.00358 | 0.000179 | 0.0000358 | 0.0033652 |
| Bid, token 1 from the matcher | 0.004853333333333333 | 0.000242666666666666 | 0.000048533333333333 | 0.004562133333333334 |
| Bid, token 2 from the holder | 0.00488 | 0.000244 | 0.0000488 | 0.0045872 |

Read back after cleanup: every arena contract and both orders hold 0 ETH. The fee recipient `0xD4ba…7e72` went from 0 to 0.000133133333333333 ETH, exactly the three fees. The signer's balance fell by 0.001184529648727723 ETH: that fee plus 0.00105139631539439 of gas (settle was sent at 1 gwei). The matcher kept 0.000982133333333334 of spread before sweeping it back.

### This release, Sepolia, 2026-11-10

Deployed from `main` at `865829a` (contract code identical to `v0.1.0-rc.1`) with the `ripe0x` keystore (`0xCB43…17F9`) through `https://sepolia.gateway.tenderly.co`, one confirmed broadcast at a time, each dry-run first and read back after. Gas price about 67 wei, so the whole sequence cost about 0.000000002 ETH in gas; the account's only real spend was 0.000300611 ETH of royalties to the lifecycle's fixed receiver.

| Contract | Address | Transaction | Block | Gas | Verified |
| --- | --- | --- | --- | --- | --- |
| `Market` (2026-11-06) | `0x8210144750E6237740bf71b819f87A834905445d` | [`0x728d014d…`](https://evm.now/tx/0x728d014dc1e88e3fc6b4454a57f8db805472d1bd06d93495b7c0c04cbe406c80?chainId=11155111) | 12,078,304 | 5,683,482 | Etherscan, Sourcify |
| `Order` implementation | `0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87` | same | 12,078,304 | | Etherscan, Sourcify |
| `FillVerifier` (2026-11-06) | `0x9e301ffeE4900D6e1436911c0eD5bDd6DF0499C0` | [`0x7a8ee03e…`](https://evm.now/tx/0x7a8ee03ed8b5dfcb49d048223c8cee9e42f14c2a861a17d4fd9228d97161c888?chainId=11155111) | 12,078,307 | 1,847,814 | Etherscan, Sourcify |
| `NFTSale` | `0x72649226f648d8a33f8eee78B71e5D9d9e18D9C7` | [`0xc424a795…`](https://evm.now/tx/0xc424a7950f8348ebdf29b44a333e1373e0ab04be5d0cfbf93523bd9574b0f6d2?chainId=11155111) | 12,106,757 | 5,143,988 | Etherscan, Sourcify |
| `NFTBid` | `0x0FeE65df72d3194b07235D275b60269E15FC1445` | [`0xe2fb732d…`](https://evm.now/tx/0xe2fb732d967b5d18fa34c8819083366e366428d8af9459cdf8ff53114ba4c6ef?chainId=11155111) | 12,106,759 | 5,517,086 | Etherscan, Sourcify |
| `PaintAction` (example) | `0x2e8341791F5c1c44313dd2c3e43dF6476756B237` | [`0xc6ff1739…`](https://evm.now/tx/0xc6ff1739a593b61ab1882488475316378556fc2d98913c1523e7679dcda4c6cf?chainId=11155111) | 12,106,877 | 2,018,291 | Etherscan, Sourcify |

Lifecycle (`script/Lifecycle.s.sol`), 24 transactions, nonces 5846 to 5869, blocks 12,106,905 to 12,106,936, all successful, 17,031,189 gas; then `recover`, nonces 5870 and 5871. Read back after each:

| Step | Order | Result | Key transaction |
| --- | --- | --- | --- |
| Test collection, ERC2981 5% | `0xdf84FCfdF99E7330596dF611E24D1091283E0680` | Tokens 1 to 4 minted | [`0x84833eb3…`](https://evm.now/tx/0x84833eb36a387140b62d3461905f4e35ac13d91efcea04ff7159dda8f06a27dc?chainId=11155111) |
| Fixed-price sale, 0.002 ETH | `0xeb454891c38a45dd08379c41fe1e16aa3d82ba04` | Filled and closed; royalty paid; order holds nothing | [`0xc12aca74…`](https://evm.now/tx/0xc12aca7460b660b5f0430ebdebcda87e949bac0820108db3d6d393e8c6f18a42?chainId=11155111) |
| Falling sale, cancelled | `0xc605656e66d536b91aded9de72f37f6b93ae5a8a` | Closed; token 2 recovered by the owner through `execute` | [`0xd0420264…`](https://evm.now/tx/0xd0420264ad42392020d38d957517a8e2bf422b8caa4f02aa323cc232937e5e27?chainId=11155111) |
| Persistent rising bid, funded 0.004, topped up 0.003 | `0x4afaab884c903a220d8bd7abb2af20a5f33fd118` | Two fills, tokens 3 and 4 to the vault, approval revoked; then closed and 0.002987777777777779 ETH recovered, balance 0 | [`0x6feac3c2…`](https://evm.now/tx/0x6feac3c2cd55d102c18c765d646fadcdc73c3a8594a98edd7842423df107ddb0?chainId=11155111), recover [`0x13fc2e53…`](https://evm.now/tx/0x13fc2e5310cdefdc1a99df064d27c5a3a42b175dde199ebcbd26ae0c06878be5?chainId=11155111) |
| PaintAction, 0.001 ETH | `0x79b774a5deebc99ece38d30d204a1d473e38da8a` | Artwork `0x3aEE…5d0E` token 1 painted color 2; painter role resigned; order closed | [`0x18b5113a…`](https://evm.now/tx/0x18b5113ad345c966f0287b1cdf6597ee73db2176e7d7091cc6a5041caf62bc62?chainId=11155111) |

Verification note: `--verify` in the broadcast failed each time because Etherscan had not yet indexed the new code; rerunning `forge verify-contract` a minute later passed.

### Arena, Sepolia, 2026-11-10 to 2026-11-11

`script/Arena.s.sol` from `main` (PR #8, `9d0ebe9`), arena id 1, start `1794347604`, signer `ripe0x` (`0xCB43…17F9`), Tenderly gateway, each broadcast dry-run first and read back after. Separate contracts play seller, bidder, holder and royalty receiver (`artist`), so no role shares an address. All 29 transactions succeeded, 27,620,660 gas. The signer's balance fell by 0.000006411880960076 ETH, all gas; every arena contract and both orders end at 0 ETH.

| Broadcast | Nonces | Blocks | Gas | Result |
| --- | --- | --- | --- | --- |
| `setup` | 5872 to 5890 | 12,107,429 to 12,107,457 | 25,948,102 | Parties, `ArenaNFT` `0x9ab3…Fa40` (5% royalty to the artist), matcher, adversary and attack helpers; tokens 1 (seller), 2 and 3 (holder); falling sale `0x26c3dba049D6d6120405f532a31000F996494b4E` (0.01 to 0.001 ETH over 30 minutes) and funded rising bid `0x4968893dcBe9A7123Be8813A9FE3793f0CE0E0a1` (0.002 to 0.006 ETH, any token, 2 fills, 0.012 ETH); the holder approves `NFTBid` |
| `attack` | 5891 | 12,107,543 | 641,008 | [`0xf4d81a25…`](https://evm.now/tx/0xf4d81a251dbc5a53418572ddcc74e02e07e42554414e595d94227c82e51bb405?chainId=11155111): 15 attacks in one transaction, all refused (below) |
| `settle` | 5892, 5893 | 12,107,578, 12,107,579 | 783,604 | [`0x82b91f51…`](https://evm.now/tx/0x82b91f51e13b946ccb887a0316ccbc87885682e8758534b4020812a19cbfa90b?chainId=11155111): the independent matcher buys token 1 from the sale and sells it into the bid in one transaction; [`0xb7871b65…`](https://evm.now/tx/0xb7871b65fbe74f9c6f28a90017a462cb02cd270f9e5c4809a2ea04dadac4fb64?chainId=11155111): the holder sells token 2 into the bid, its last fill, which closes it |
| `cleanup` | 5894 to 5900 | 12,113,030 to 12,113,037 | 247,946 | The closed bid's owner tries to take the holder's token 3 (refused, below); the holder revokes its approval; every party and the adversary return their ETH |

Attacks, each recorded by an `Attempt` event with its revert data:

| # | Attack | Refused with |
| --- | --- | --- |
| 1 | `NFTSale.onFill` called directly | `NotAFill` |
| 2 | `NFTBid.onFill` called directly, naming the holder | `NotAFill` |
| 3 | Counterfeit order makes `NFTSale` announce a `Sold` (S1) | `NotAFill` |
| 4 | Closed rogue clone of the bid uses the holder's approval to `NFTBid` | `NotAFill` |
| 5 | Funded rogue clone filled for the holder's token | `ERC721IncorrectOwner` |
| 6 | Live bid filled naming the holder's token | `ERC721IncorrectOwner` |
| 7 | `execute` on someone else's active sale | `Unauthorized` |
| 8 | `close` someone else's sale | `Unauthorized` |
| 9 | Fill a sale with tampered config | `WrongConfig` |
| 10 | Underpay a live sale | `Underpaid` |
| 11 | Hostile handler reaches the live bid | `Unauthorized` |
| 12 | `execute` on the `Order` implementation | `Unauthorized` |
| 13 | Fill a closed order | `OrderClosed` |
| 14 | `execute` a closed order as non-owner | `Unauthorized` |
| 15 | Pull the holder's token directly | `ERC721InsufficientApproval` |
| 16 | Closed bid's owner `execute`s `transferFrom(holder, …, 3)` (cleanup, [`0xcf8b8e29…`](https://evm.now/tx/0xcf8b8e29349cacb2d0983d96a0e83305ebfa0963919030043080b29a02c3bfdf?chainId=11155111)) | `ERC721InsufficientApproval` |
| 17 | Closed bid's owner `execute`s `NFTBid.onFill` for token 3 (cleanup, [`0xb3e5d77c…`](https://evm.now/tx/0xb3e5d77ce37fca041a2a0755b213f911eb89aa7a03ba94cb9df828f0bb21ac02?chainId=11155111)) | `NotAFill` |

Settlement ran after both schedules ended: ask 0.001 ETH, bid 0.006 ETH per token. Read back at block 12,107,579:

| Account | ETH change | From |
| --- | --- | --- |
| Seller | +0.00095 | Ask less 5% royalty |
| Holder | +0.0057 | Bid less 5% royalty |
| Artist | +0.00065 | Royalties on all three payments |
| Matcher, to the signer | +0.0047 | Spread; overpayment of 0.00114 refunded |
| Bid order | −0.012 | Two fills; empty and closed |

The four gains sum to 0.012 ETH. Tokens 1 and 2 belong to the bidder, token 3 to the holder; both orders are closed. After cleanup: holder's approval to `NFTBid` false, all balances 0. The same flows and attacks pass against forked Sepolia state in `test/fork/SepoliaLive.t.sol` (block 12,107,304, 6 tests).

## Focused improvement candidate, 2026-11-18

The compiled production source is `cf7f48d8fae716740c59f882dcc2761497c2a63b`. The client pins complete protocol revision `c211808cf3dd6ed36f41e92d885e6f866a4b9436`, which includes the final historical fork-test repair and these unchanged production files. Later documentation commits do not alter its bytecode. Comments changed Solidity metadata and deterministic addresses. The prior rights candidate is superseded and remains undeployed. New Market candidate: `0x5796242872BCAA3Fb0e16a4388c70f2e80aB966c`. The full computed address/hash table is in [the verification record](verification/2026-11-18-improvements.md); the client machine-readable rights manifests carry this source pin and separate local/candidate status. Sepolia candidate startBlock remains null.

Use the existing same-signer Deploy.s.sol simulation, verification and postflight relationship runbook above with this final pin. Preserve the legacy deployment and its indexer schema. The updated local signed rehearsal uses the same deployment path and records 56 transactions, both listing/right expiry cases, actual payment release and manual-config recovery after burn. Public deployment, hosted indexer setup, cutover and real-asset transactions require separate authorization.
