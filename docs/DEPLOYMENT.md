# Deployment and integration reference

## Where Market is deployed

| Chain | Chain ID | Status |
| --- | --- | --- |
| Ethereum Sepolia | 11155111 | **Deployed and verified** (2026-11-10): the supported release and the PaintAction example, at the addresses below, verified on Etherscan and Sourcify; lifecycle executed with real transactions. Contracts deployed on 2026-11-06 at other addresses are obsolete (see "Deployment record") |
| Ethereum mainnet | 1 | **Not deployed.** Simulated only. Needs the release checklist below and the owner's explicit approval |

## Addresses

Every contract deploys through the standard CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("market.v1")` and has no owner. The address depends only on the bytecode (and constructor argument), so it is the same on every chain and anyone can deploy it. **Any change to a contract's Solidity source, including a comment, changes its metadata and therefore its address.** `forge script script/Deploy.s.sol` prints the current addresses without sending anything. If it prints addresses other than the tables below for unchanged code, stop: the build differs. `foundry.toml` fixes the remappings (`auto_detect_remappings = false`) because they are part of the metadata; before that fix, a checkout with OpenZeppelin's nested submodules (`git submodule update --recursive`) compiled to different bytecode and addresses (found 2026-11-10).

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
| [`script/Arena.s.sol`](../script/Arena.s.sol) | Multi-party trading and onchain attacks against the live release, from one signer through CREATE2 party contracts: `setup(id)`, `attack(id, start)`, `settle(id, start)`, `cleanup(id, start)` | Only with `--broadcast`; returns all ETH except gas |
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
