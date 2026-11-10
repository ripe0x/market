# Status

Updated 2026-11-10. `main` after PR #3 (NFT trading, merged as `33659c5`) and PR #4 (deployment and developer docs).

## State

Experimental. The core was merged to `main` on 2026-11-06 (PR #2). PR #3 added the NFT trading handlers and, after a simplification review on 2026-11-10, cut the repository down to the supported release (DECISIONS D301 to D304). PR #4 adds the deployment scripts and developer documentation. **Not audited. Not deployed to mainnet.** No mainnet transaction or paid service has been used.

**Sepolia:** the supported release and the PaintAction example are deployed and verified on Sepolia (2026-11-10, from `main` at `865829a`, signer `ripe0x` = `0xCB43…17F9`), and the full lifecycle ran with real transactions: a fixed sale with royalty, a falling sale cancelled and recovered, a persistent rising bid filled twice, topped up, cancelled and recovered, and a PaintAction repaint. Every transaction was dry-run first and read back after. An earlier candidate deployed on 2026-11-06 left `Market`, the implementation and `FillVerifier` (reused) and seven obsolete contracts. Record: [DEPLOYMENT.md](DEPLOYMENT.md#deployment-record).

| Contract | Kind | State |
| --- | --- | --- |
| `Market`, `Order` (`src/`) | Core | Unchanged since PR #2 |
| `NFTSale`, `NFTBid`, `NFTTrade`, `HandlerBase` (`handlers/`) | Supported NFT trading | Unit, fuzz, invariant, composition and mainnet fork tested. Both handlers authenticate their caller (S1, D302) |
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
| Sizes | `forge build --sizes` | Runtime bytes: `Order` 2,133, `Market` 1,277, `NFTSale` 3,183, `NFTBid` 3,424, `FillVerifier` 1,058, `PaintAction` 1,168, `Artwork` 3,813. Each order clone 149. |
| Compiler and EVM | `forge build --use 0.8.28 --evm-version cancun src handlers periphery examples` | Compiles. |
| Static analysis | Slither 0.11.5, 101 detectors, `src/`, `handlers/`, `periphery/`, `examples/` compiled together | 21 results, none actionable. Triage below. |
| Independent review | AI agent on `69f2455` | Nothing above informational; 9 PoC tests, all refusals (SECURITY.md, fifth review). |
| Deployment gas | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` (simulation) | Supported release 3,682,037 gas, against 6,704,108 for the previous script's eleven contracts (45% less). `examples()`: 424,083. |
| Mainnet fork rehearsal | `script/rehearse.sh https://mainnet.gateway.tenderly.co` | Chain 1 forked at block 26,386,482: Deploy, examples, Lifecycle (fixed sale with royalty, falling sale cancelled and recovered, persistent bid filled twice and topped up, PaintAction) and recover all succeed. |
| Sepolia fork rehearsal | `script/rehearse.sh` | Chain 11155111 forked at block 12,106,569: same, all succeed; `Market` and `FillVerifier` skipped as already deployed. |
| Sepolia deployment | `script/Deploy.s.sol`, `examples()`, `script/Lifecycle.s.sol`, `recover` from `main` | All 29 transactions succeeded; post-state read back (DEPLOYMENT.md). Contracts verified on Etherscan and Sourcify. |
| Remappings | `forge script script/Deploy.s.sol` with and without OpenZeppelin's nested submodules | Same addresses after `auto_detect_remappings = false` (PR #6); before, a recursive checkout compiled to different addresses. |
| Idempotence | `Deploy.s.sol` broadcast twice to a local mainnet fork | Second run: "No transactions to broadcast". |
| S1 regression | `forge test --match-path test/review/SaleEventPoC.t.sol` | 2 passed; both emitted a false `Sold` before the fix. |

Slither triage. `arbitrary-send-eth` (`Order.execute`): authorized by the lifecycle rules. `arbitrary-send-erc20` (`NFTBid._transfer`): `from` is the authenticated filler. `locked-ether` (`Market`): `create` forwards its ETH into the new order. `reentrancy-no-eth`, `reentrancy-events` (`Order.fill`, both handlers): reentry into the same order is refused by `filling`; events after calls only affect log order. `timestamp`: price schedules are time based by design. `missing-zero-check` (`execute` target): the caller's choice. `assembly`, `low-level-calls`: reviewed (`_arg`, `_isOrder`, `execute`'s revert bubbling, `FillVerifier`'s transient storage).

### Gas

Whole-transaction gas, isolated runs, local mocks (`snapshots/GasTest.json`). Real collections: [NFT_TRADING.md](NFT_TRADING.md#gas).

| Operation | Gas |
| --- | --- |
| Create: NFTSale order | 95,143 |
| Create: NFTBid order, funded | 95,534 |
| Fill: NFTSale, fixed price, no royalty, exact payment | 121,094 |
| Fill: NFTSale, falling price, royalty, refund | 173,042 |
| Fill: NFTBid, rising collection bid, royalty | 164,840 |
| Fill: NFTBid, last fill closes | 124,749 |
| Fill: PaintAction, paint + resign + close | 109,600 |
| Owner closes | 47,129 |
| Owner withdraws an NFT after closing | 64,080 |

The fill authentication added to `NFTSale` (S1) costs 2,531 gas per sale fill on the fork.

## Not verified

1. No human audit. AI reviews and Slither only (SECURITY.md).
2. Fork tests impersonate holders; real wallet software and EIP-7702 delegates other than the one Opepen holder's were not exercised.
3. Gas figures are local and fork measurements; real costs depend on calldata, warm or cold accounts and gas price.
4. The full suite ran only on solc 0.8.30 for Prague; 0.8.28 for Cancun was compiled, not tested.
5. Lifecycle on Sepolia used one account in every role and a test collection; no third-party wallets or real collections on a public chain.

## Next actions

1. Owner decisions in DECISIONS.md, Owner review (items 1, 3, 4, 7, 8 open).
2. Mainnet: the checklist in [DEPLOYMENT.md](DEPLOYMENT.md#mainnet-release-checklist), then the owner's explicit approval.
3. Independent human audit of `src/`, `handlers/` and `periphery/` before any value-bearing deployment.
