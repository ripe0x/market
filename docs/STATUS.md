# Status

Updated 2026-11-16. Owner decisions 1, 3, 4, 7 and 8 recorded in DECISIONS.md. `main` after PR #3 (NFT trading, merged as `33659c5`) and PR #4 (deployment and developer docs).

## State

Experimental. The core was merged to `main` on 2026-11-06 (PR #2). PR #3 added the NFT trading handlers and, after a simplification review on 2026-11-10, cut the repository down to the supported release (DECISIONS D301 to D304). PR #4 adds the deployment scripts and developer documentation. **Not audited. Not deployed to mainnet.** No mainnet transaction or paid service has been used.

**Sepolia:** the current release is deployed and verified (2026-11-16): `Market` `0x7c91…1FD4`, `FeeConfig` `0x9A18…06fF` (admin `0xCB43…17F9`, recipient `0xD4ba…7e72`, 1%), `NFTSale` `0xfEf3…a2c8`, `NFTBid` `0x8dbB…017E`, read back after deployment and exercised on a fork pinned after it (`test/fork/SepoliaLive.t.sol`, 7 tests). The admin is the deployer EOA, not a Safe (residual risk 23, recommend `setAdmin` to a Safe). The arena and lifecycle below ran against the 2026-11-10 contracts, which this deployment supersedes; neither has been rerun onchain against the new ones. Otherwise the supported release and the PaintAction example are deployed and verified on Sepolia (2026-11-10, from `main` at `865829a`, signer `ripe0x` = `0xCB43…17F9`), and the full lifecycle ran with real transactions: a fixed sale with royalty, a falling sale cancelled and recovered, a persistent rising bid filled twice, topped up, cancelled and recovered, and a PaintAction repaint. On 2026-11-10 and 11 an arena (`script/Arena.s.sol`) traded between separate seller, bidder, holder and royalty contracts, matched a falling sale into a rising bid through an independent matcher, and ran 17 attacks against the live contracts; all were refused and every ETH flow reconciled. Every transaction was dry-run first and read back after. An earlier candidate deployed on 2026-11-06 left `Market`, the implementation and `FillVerifier` (reused) and seven obsolete contracts. Record: [DEPLOYMENT.md](DEPLOYMENT.md#deployment-record).

| Contract | Kind | State |
| --- | --- | --- |
| `Market`, `Order` (`src/`) | Core | `Order` unchanged since PR #2. `Market` records each order's creation time (`createdAt`, D306, 2026-11-16), a recorded core change; this moved `Market`'s address; the new `Market` is deployed on Sepolia (2026-11-16) |
| `NFTSale`, `NFTBid`, `NFTTrade`, `HandlerBase`, `FeeConfig` (`handlers/`) | Supported NFT trading | Unit, fuzz, invariant, composition and mainnet fork tested. Both handlers authenticate their caller (S1, D302) and read the shared `FeeConfig` (D309) for a fee set per order at creation, up to 1%, settable within that cap by a `FeeConfig` admin that also sets a changeable recipient (D305, D307, D309, 2026-11-16); royalty capped at price less fee (D308). Deployed on Sepolia 2026-11-16 |
| `FillVerifier` (`periphery/`) | Optional periphery | Unchanged |
| `PaintAction`, `Artwork` (`examples/`) | Example, not supported for value | Unit tested; pays one payee (D303) |
| `DutchAuction`, `TokenExchange`, `AcquisitionBid`, strategies, `CapitalPool`, demo script | Removed (D301) | History at commit `4598764` |

## Evidence

Candidate: production code at commit `33a5c6d` (the next commit adds two `NFTBid` tests and this file). Toolchain: forge 1.8.1 (`982849d`), solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-10.

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | Exit 0. 167 passed, 0 failed, 19 suites, including the 14 mainnet fork tests. Fuzz 1,000 runs each. `test/NFTBid.t.sol` then 18 passed with the two added tests. |
| Invariants | `test/Invariant.t.sol` in the full suite | 6 invariants, 128 runs x 64 calls, 0 reverts. About 930 attacker calls and 914 owner attempts on active orders per campaign, none succeeded. |
| Deep invariants | `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-path test/Invariant.t.sol` | All 6 hold, 128,000 calls, 0 reverts. |
| Mainnet fork | `forge test --match-path "test/fork/*"` | 14 passed at block 26,357,000 (BAYC, Azuki, Moonbirds, Opepen, Chimpers, ENS, CryptoPunks); gas in `snapshots/NFTFork.json`. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | `snapshots/GasTest.json`, table below. |
| Coverage | `CANDIDATE_RUN=1 forge coverage --ir-minimum --report summary --no-match-coverage 'test\|script\|lib' --no-match-path "test/fork/*"` | 90.1% lines (181/201), 90.5% statements, 90.7% branches (39/43), 100% functions over `src/`, `handlers/`, `periphery/`, `examples/`. Uncovered lines are mostly inline assembly, which `--ir-minimum` does not attribute. Approximate. |
| Sizes | `forge build --sizes` | Runtime bytes: `Order` 2,133, `Market` 1,359 (1,277 before the creation-time record, D306), `FeeConfig` 1,902 (new, D309), `NFTSale` 3,520, `NFTBid` 3,718 (smaller than the 4,345 and 4,613 of D307/D308 now the fee logic lives in `FeeConfig`), `FillVerifier` 1,058, `PaintAction` 1,168, `Artwork` 3,813. Each order clone 149. |
| Compiler and EVM | `forge build --use 0.8.28 --evm-version cancun src handlers periphery examples` | Compiles. |
| Static analysis | Slither 0.11.5, 101 detectors, `src/`, `handlers/`, `periphery/`, `examples/` compiled together | 21 results, none actionable. Triage below. |
| Independent review | AI agent on `69f2455` | Nothing above informational; 9 PoC tests, all refusals (SECURITY.md, fifth review). |
| Deployment gas | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` (simulation) | Supported release 3,682,037 gas, against 6,704,108 for the previous script's eleven contracts (45% less). `examples()`: 424,083. |
| Mainnet fork rehearsal | `script/rehearse.sh https://mainnet.gateway.tenderly.co` | Chain 1 forked at block 26,386,482: Deploy, examples, Lifecycle (fixed sale with royalty, falling sale cancelled and recovered, persistent bid filled twice and topped up, PaintAction) and recover all succeed. |
| Sepolia fork rehearsal | `script/rehearse.sh` | Chain 11155111 forked at block 12,106,569: same, all succeed; `Market` and `FillVerifier` skipped as already deployed. |
| Sepolia deployment | `script/Deploy.s.sol`, `examples()`, `script/Lifecycle.s.sol`, `recover` from `main` | All 29 transactions succeeded; post-state read back (DEPLOYMENT.md). Contracts verified on Etherscan and Sourcify. |
| Sepolia arena | `script/Arena.s.sol` `setup`, `attack`, `settle`, `cleanup` from `main` at `9d0ebe9` | 29 transactions succeeded; 17 attacks refused with the intended errors; payouts sum to the 0.012 ETH the bid paid; all balances end at 0 (DEPLOYMENT.md, Arena). |
| Sepolia live fork | `forge test --match-path test/fork/SepoliaLive.t.sol` at `cd0d369` | 6 passed at block 12,107,304 against the handlers deployed before the fee. Removed with the fee change (their code no longer matches the source); to be rewritten against the redeployed handlers. |
| Fee (D305), superseded by the row below | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `review/*`, and `test/fork/NFTFork.t.sol --isolate` | Evidence for the earlier fixed 0.5% fee (commit `9739154`). All passed on 2026-11-16. `Fee.t.sol` 9 tests: exact split at 1 ETH with 5% royalty (seller 0.945, royalty 0.05, fee 0.005), seller minimum net of fee, royalty above 99.5% refused, refusing fee recipient blocks fills but not recovery, fee recipient cannot reenter, prices under 200 wei pay no fee. The split, the royalty-above-price behaviour and the 200 wei threshold have since changed (D307, D308); see the row below. |
| Settable fee and royalty cap (D306 to D308) | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `Core`, `Clone`, `PaintAction`, `FillVerifier`, `NewOrderType`, `review/*`, `test/fork/NFTFork.t.sol --isolate`, and `test/Gas.t.sol --isolate` | All pass on 2026-11-16 at commit `0a3064a` (binary-search lookup; fee, invariant, sale, bid, gas and fork files rerun after it). Per file: Fee 15, NFTSale 24, NFTBid 18, Compose 6, SharedHandler 5, Invariant (with `setFee` in the fuzz driver: 128 runs, 8,192 calls, 810 `setFee` calls, 0 reverts), Eip7702Filler 4, Core 32, Clone 10, PaintAction 11, FillVerifier 10, NewOrderType 1, `review/*` all pass, mainnet fork 14 (`--isolate`), Gas 6 (`--isolate`). Example split at 1 ETH, 5% royalty, 1% fee: buyer 1, royalty 0.05, fee 0.01, seller 0.94; at 100% royalty: royalty 0.99, fee 0.01, seller 0. Prices under 100 wei pay no fee. Independent AI review of `a867d55` (not an audit): no money or authority defect; its unbounded-scan note was fixed by `0a3064a`, and its doc notes by this revision. **The whole suite (`CANDIDATE_RUN=1 forge test`) was not run at this commit.** |
| Shared `FeeConfig` (D309) | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `Core`, `Clone`, `PaintAction`, `FillVerifier`, `NewOrderType`, `review/*`, `test/fork/NFTFork.t.sol --isolate`, and `test/Gas.t.sol --isolate` | All pass on 2026-11-16 at commit `fc179ad` (fee terms moved to `FeeConfig` with a separate admin and changeable recipient in `bb635b5`; two-step admin handoff in `efeafeb`). Per file: Fee 19 (adds admin-only setters, a recipient change applying to old orders, two-step admin handoff and a withdrawn offer, a refusing recipient being replaceable, and owner recovery while the recipient refuses), NFTSale 24, NFTBid 18, Compose 6, SharedHandler 5, Invariant (fuzz driver now calls `setFee` 736 times and `setRecipient` 691 times; fees checked against the sum of both recipients), Eip7702Filler 4, Core 32, Clone 10, PaintAction 11, FillVerifier 10, NewOrderType 1, `review/*` all pass, mainnet fork 14 (`--isolate`), Gas 6 (`--isolate`). Independent AI review of `bb635b5` (not an audit): no money or authority defect; its one-step-handoff note was fixed in `efeafeb`, and its EOA-admin note is the owner's call (SECURITY.md, 23). **The whole suite (`CANDIDATE_RUN=1 forge test`) was not run at this commit.** |
| Sepolia fee release (2026-11-16) | Broadcast by the owner (`script/Deploy.s.sol`, `ripe0x`); readback with `cast`; `forge test --match-path test/fork/SepoliaLive.t.sol` (fork pinned at block 12,150,234) | 4 transactions succeeded; addresses, sizes and `FeeConfig` settings read back as planned; verified on Etherscan and Sourcify (DEPLOYMENT.md). Live fork: 7 of 7 pass: bytecode matches this build, fee terms, the admin's rate cut binding only later orders and a recipient change binding every fill (1 ETH sales: 0.01 and 0.005 to the new recipient), the arena end to end (every wei returned except 0.000133333333333332 ETH of fees, exactly 1% of its three trades), a royalty receiver refused re-entry, an EIP-7702 wallet buying with `FillVerifier` (seller 0.094, royalty 0.005, fee 0.001), and 64 fuzzed sales conserving ETH. Not run onchain: the arena and lifecycle against these contracts |
| Remappings | `forge script script/Deploy.s.sol` with and without OpenZeppelin's nested submodules | Same addresses after `auto_detect_remappings = false` (PR #6); before, a recursive checkout compiled to different addresses. |
| Idempotence | `Deploy.s.sol` broadcast twice to a local mainnet fork | Second run: "No transactions to broadcast". |
| S1 regression | `forge test --match-path test/review/SaleEventPoC.t.sol` | 2 passed; both emitted a false `Sold` before the fix. |

Slither triage. `arbitrary-send-eth` (`Order.execute`): authorized by the lifecycle rules. `arbitrary-send-erc20` (`NFTBid._transfer`): `from` is the authenticated filler. `locked-ether` (`Market`): `create` forwards its ETH into the new order. `reentrancy-no-eth`, `reentrancy-events` (`Order.fill`, both handlers): reentry into the same order is refused by `filling`; events after calls only affect log order. `timestamp`: price schedules are time based by design. `missing-zero-check` (`execute` target): the caller's choice. `assembly`, `low-level-calls`: reviewed (`_arg`, `_isOrder`, `execute`'s revert bubbling, `FillVerifier`'s transient storage).

### Gas

Whole-transaction gas, isolated runs, local mocks (`snapshots/GasTest.json`). Real collections: [NFT_TRADING.md](NFT_TRADING.md#gas).

| Operation | Gas |
| --- | --- |
| Create: NFTSale order | 117,318 |
| Create: NFTBid order, funded | 117,709 |
| Fill: NFTSale, fixed price, no royalty, exact payment | 143,176 |
| Fill: NFTSale, fixed price, no royalty, after one rate change | 150,995 |
| Fill: NFTSale, falling price, royalty, refund | 195,129 |
| Fill: NFTBid, rising collection bid, royalty | 186,861 |
| Fill: NFTBid, last fill closes | 146,770 |
| Fill: PaintAction, paint + resign + close | 109,600 |
| Owner closes | 47,129 |
| Owner withdraws an NFT after closing | 64,080 |

The fill authentication added to `NFTSale` (S1) costs about 2,500 gas per sale fill on the fork. The fee (D305, D307) adds about 12,000 per fill when the recipient already exists, 25,000 more if it does not; moving the fee terms into the shared `FeeConfig` (D309) adds about 5,100 more per fill than the per-handler rate of the previous revision (an external call and its cold storage reads). Recording the creation time (D306) adds about 22,200 to each create (one cold `SSTORE`). Once the rate has been changed, each fill looks up its order's creation time and searches the rate history by binary search: the fixed sale costs 150,995 after one rate change against 143,176 before any.

## Not verified

1. No human audit. AI reviews and Slither only (SECURITY.md).
2. Fork tests impersonate holders; real wallet software and EIP-7702 delegates other than the one Opepen holder's were not exercised.
3. Gas figures are local and fork measurements; real costs depend on calldata, warm or cold accounts and gas price.
4. The full suite ran only on solc 0.8.30 for Prague; 0.8.28 for Cancun was compiled, not tested.
5. Sepolia runs used contracts controlled by one signer and test collections; no third-party wallets, independent fillers or real collections on a public chain.

## Next actions

1. Economic pass against the approved outcomes O1 to O10 in [OWNER-REQUIREMENTS.md](../OWNER-REQUIREMENTS.md): flow breakdown under each regime and a one-screen scorecard.
2. Mainnet: the checklist in [DEPLOYMENT.md](DEPLOYMENT.md#mainnet-release-checklist), then the owner's explicit approval.
3. Independent human audit of `src/`, `handlers/` and `periphery/` before any value-bearing deployment.
