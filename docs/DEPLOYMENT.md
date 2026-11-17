# Deployment and integration reference

## Where Market is deployed

| Chain | Chain ID | Status |
| --- | --- | --- |
| Local simulation | 31337 | Transferable rights redesign implemented here; **not deployed** to any public chain |
| Ethereum Sepolia | 11155111 | **Legacy order-only release**, deployed and verified 2026-11-16. Its `Market`, `FeeConfig`, `NFTSale`, `NFTBid` and `PaintAction` addresses below do not support native transferable rights. Historical records remain below. |
| Ethereum mainnet | 1 | **Not deployed.** Any future deployment needs a frozen candidate, rehearsal, review and the owner's explicit approval. |

## Transferable rights candidate addresses

The new `Market` creates an `Order` implementation, a `Right` implementation and canonical `Rights` ERC721. The supported deployment script also creates `CoveredNFTPurchase`, updated `NFTSale` and `NFTBid`, `FeeConfig` and `FillVerifier`; its `examples()` path adds `PaintAction` and `ReservedPaint`. **No redesigned address is deployed on Sepolia or mainnet.** Run `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` without `--broadcast` to calculate candidate addresses only after the final bytecode is frozen. The result may change with any source or compiler input change; do not use the old table as an address source.

`Market.rights()` and `Market.rightImplementation()` identify the canonical token and backing implementation. `Market.rightAddress(issuer, handler, configHash, deadline, residual, salt)` predicts an individual backing account; verify `Market.isRight(account)` before relying on it. `Rights.accountOf(tokenId)` authenticates a Market-created account. Each right publishes its config in `RightCreated`; its activation terms, deadline, state and residual beneficiary can be read from the account.

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

## Deployment gas

Historical order-only estimate by `forge script` against mainnet state (`--rpc-url https://mainnet.gateway.tenderly.co`, simulation only), 2026-11-10. It does **not** estimate the redesigned contracts:

| Script | Contracts | Gas |
| --- | --- | --- |
| Previous `Deploy.s.sol` (PR #4 before this revision) | Market, implementation, NFTSale, NFTBid, FillVerifier, PaintAction, DutchAuction, TokenExchange, AcquisitionBid, RisingStrategy, CapitalShareStrategy | 6,704,108 |
| `Deploy.s.sol` | Market, implementation, FeeConfig, NFTSale, NFTBid, FillVerifier | 3,682,037 (45% less) |
| `Deploy.s.sol --sig "examples()"` | PaintAction | 424,083 |

Re-estimate the right-enabled script at the frozen candidate. On Sepolia, the old order-only `Market`, its implementation, `FeeConfig` and trading handlers do not implement the new right architecture. `PaintAction` has a new creation-code address after its imported `Artwork` changed. Only `FillVerifier` currently retains the old CREATE2 address; verify again against frozen bytecode.

## Scripts

| Script | What it does | Sends transactions |
| --- | --- | --- |
| [`script/Deploy.s.sol`](../script/Deploy.s.sol) | `run()`: right-enabled Market, NFT trading and covered purchase handler. `examples()`: PaintAction and ReservedPaint. Skips addresses already holding code. | Only with `--broadcast` |
| [`script/Lifecycle.s.sol`](../script/Lifecycle.s.sol) | Historical order-only example: fixed and falling NFT sales, bid and revocable PaintAction. Its previous Sepolia results are in the record below. | Only with `--broadcast`; historical example spent about 0.012 ETH plus gas |
| [`script/RightsLifecycle.s.sol`](../script/RightsLifecycle.s.sol) | Local-only simulation of covered NFT primary and secondary premiums, exercise credits, listing cancellation, expiry and collateral recovery; then reserved artwork resale and exercise after artwork transfer. Requires local chain ID 31337 and cannot broadcast to a public chain. | No public broadcast path |
| [`script/Arena.s.sol`](../script/Arena.s.sol) | Multi-party trading and onchain attacks against the live release, from one signer through CREATE2 party contracts: `setup(id)`, `attack(id, start)`, `settle(id, start)`, `cleanup(id, start)` | Only with `--broadcast`; returns all ETH except gas |
| [`script/rehearse.sh`](../script/rehearse.sh) | Runs Deploy, examples, Lifecycle and recover on a throwaway anvil fork (Sepolia by default; pass a mainnet RPC for mainnet) from anvil's unlocked account | Only to the local fork |

The current task authorizes no public broadcast. A read-only mainnet simulation of the right-enabled `Deploy.run()` on 2026-11-17 succeeded and estimated 9,915,632 gas; no signer or transaction was used. This does not replace a signer-specific deployment rehearsal. Any later authorized deployment follows the repository's main-branch and signer rules: use the owner's Foundry keystore `ripe0x` (`--account ripe0x`), Tenderly's public gateway (`https://sepolia.gateway.tenderly.co` or `https://mainnet.gateway.tenderly.co`), a same-signer dry run, explicit owner confirmation immediately before each broadcast and postflight receipt and state reads. Never put a private key in a command, file or environment variable.

## Local right lifecycles

Run both reference lifecycles without RPC, secrets or real assets:

```bash
forge script script/RightsLifecycle.s.sol:RightsLifecycle --sig "run()"
```

The script requires local chain ID 31337. It deploys local versions of Market and the handlers, creates two fully collateralized NFT purchase rights and an artwork reservation right. For the first NFT, issuer sells the token for a 0.2 ETH premium, buyer resells for 0.3 ETH, and the final holder pays the separate 1 ETH exercise price. A 5% royalty fixed at activation creates 0.05 ETH royalty and 0.95 ETH proceeds credits; beneficiaries withdraw them. For the second NFT, an escrow listing is canceled, its token returned, the right expires, and the residual beneficiary recovers the NFT. The artwork owner transfers the artwork after reservation; the right is sold, resold and exercised for one allowed color change while artwork ownership stays put. Each order's trading deadline precedes its underlying right deadline.

Focused test commands for the same real contract paths and adversarial cases:

```bash
forge test --match-path test/RightExamples.t.sol
forge test --match-path test/RightsCore.t.sol
forge test --match-path test/RightsTrade.t.sol
```

`script/Lifecycle.s.sol` remains the immediate-order example. Its revocable `PaintAction` permission is not a durable transferable right.

## Simulate

```bash
forge script script/Deploy.s.sol --rpc-url https://sepolia.gateway.tenderly.co
```

```bash
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co
```

## Rehearse on a fork

The current `script/rehearse.sh` covers ordinary orders only. A right-enabled real-transaction rehearsal remains a release gate.

```bash
script/rehearse.sh
```

```bash
script/rehearse.sh https://mainnet.gateway.tenderly.co
```

## Sepolia historical procedure

The 2026-11-10 and 2026-11-16 order-only releases were deployed from `main` with the `ripe0x` keystore through `https://sepolia.gateway.tenderly.co`. Their exact transactions, addresses, gas and verification notes remain in the deployment record below. The then-used `--gas-estimate-multiplier 1500` followed one out-of-gas deployment attempt; it sets a transaction limit, not the charged gas. Those old addresses and verification arguments must not be used for the right-enabled code. The current task authorizes no public-chain deployment.

## Mainnet release checklist

The checklist below records the historical order-only release preparation and its then-current status. It does **not** approve the redesigned right-enabled contracts. A new frozen candidate needs the complete applicable suite, deep invariants, static-analysis triage, economic scorecard, independent review, rehearsal of the right-enabled deployment path, real-transaction rehearsal and capped canary plan, with explicit owner authorization for any external write. No redesigned contract has met those release gates or been broadcast.

1. Freeze a release candidate commit; no Solidity change after it without restarting this list. [Release candidate tagged on `main`; see STATUS.md]
2. `CANDIDATE_RUN=1 forge test` passes at the candidate, including fork tests. [See STATUS.md]
3. Invariant campaigns at higher depth than CI (`FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-path test/Invariant.t.sol`). [Passed on the release code; STATUS.md]
4. Static analysis reviewed. [Slither, none actionable; STATUS.md]
5. **Independent human security audit** of `src/`, `handlers/` and `periphery/`, with findings resolved. [**Not done**]
6. Owner review items in DECISIONS.md decided (1, 3, 4, 7, 8). [Open]
7. Contracts for mainnet: `Market`, `FeeConfig`, `NFTSale`, `NFTBid`, `FillVerifier` (D301, D309). `PaintAction` only if wanted as a public example. [Decided by D301; owner to confirm]
8. Sepolia deployment of this release and the lifecycle executed with real transactions, recorded below. [Done 2026-11-10 from `main` at `865829a`]
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
