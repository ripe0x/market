# Status

Updated 2026-11-05. Branch `feat/execution-protocol-v1`.

## State

Exploratory implementation, complete for the first milestone: the core, four examples, a fifth minimal order type, an optional fill verifier, tests, local demo and dry-run deployment. On 2026-11-05 orders became ERC-1167 clones after owner review (DECISIONS D004). In a second review the same day, Policy was renamed OrderHandler (D017) and active orders were committed to their handler: while an order is active only its handler can make it act, and only during a fill; the owner can close it and act only after closing (D003). **Not audited, not deployed.** No mainnet transaction, funded signing or paid service has been used.

| Area | State |
| --- | --- |
| Core (`src/`) | Implemented: `Market`, `Order` (clone implementation), `IOrderHandler` |
| Periphery (`periphery/`) | Implemented: `FillVerifier`, optional |
| Example 1, NFT sale (`DutchAuction`) | Implemented and tested |
| Example 2, ERC20 exchange (`TokenExchange`) | Implemented and tested |
| Example 3, artwork action (`PaintAction`, `Artwork`) | Implemented and tested |
| Example 4, persistent bid (`AcquisitionBid`, strategies, `CapitalPool`) | Implemented and tested; price 0 refused |
| New order type without core change (`BellHandler`) | Test only |
| Owner maintenance through a handler (`RestockableSale`) | Test only (`test/SharedHandler.t.sol`) |
| Composition (sale matched into bid) | Test only (`Matcher` in `test/Compose.t.sol`) |
| Filler-side receipt checks | Contract fillers (`test/Compose.t.sol`); EIP-7702 delegated EOA with a generic batch executor and `FillVerifier` (`test/Eip7702Filler.t.sol`) |
| Local demo | `script/demo.sh` runs all four examples on anvil, including closing and recovering an exchange's unsold inventory |
| CI | `.github/workflows/test.yml`: `forge build --sizes` and `forge test` on pull requests and pushes to `main`, Foundry v1.8.1 |
| Deployment | `script/Deploy.s.sol` simulated locally and against mainnet RPC; never broadcast |
| Frontend, indexer, keeper | Not built (out of scope for this milestone) |

## Evidence

Candidate: code at commit `dd71a9e`; the commit after it adds only comments, documentation and the third review's PoC tests, and the full suite was rerun on it. Coverage, the compiler matrix and the deploy dry run ran on `dd71a9e`. Toolchain: forge 1.8.1 (`982849d`), solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-05.

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | Exit 0. 148 passed, 0 failed, 16 suites. Fuzz tests 1,000 runs each. (142 passed, 15 suites, on `dd71a9e` before the third review's PoC file.) |
| Invariants | (in the full suite) `test/Invariant.t.sol` | 5 invariants, 128 runs x 64 calls = 8,192 calls, 0 reverts. In the final campaign: 906 attacker calls and 904 owner attempts to take from active orders, none succeeded. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | `snapshots/GasTest.json`, table below. |
| Coverage | `CANDIDATE_RUN=1 forge coverage --ir-minimum --report summary --no-match-coverage 'test\|script\|lib'` | `src/`, `periphery/` and `examples/`: 93.0% lines (213/229), 92.6% statements (274/296), 84.8% branches (39/46), 98.0% functions. `Market`, `Order` and `FillVerifier` branches 100%; their uncovered lines are inline assembly, which `--ir-minimum` coverage does not attribute. Approximate. |
| Sizes | `forge build --sizes` | `Order` implementation 2,133 bytes runtime, `Market` 1,277, `FillVerifier` 1,058; each order clone 149 bytes; largest example `Artwork` 3,813. |
| Compiler and EVM | `forge build --use <solc> --evm-version <evm> src periphery examples` | Compiles with solc 0.8.28 and 0.8.30, each for Cancun and Prague. `forge test --use 0.8.28 --evm-version cancun --match-path "test/{Core,Clone,Compose,SharedHandler}.t.sol"`: 51 passed. |
| Local demo | `script/demo.sh` | All four examples executed on a throwaway anvil node (chain 31337): "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL". The exchange step tops up an active order, then closes it and recovers the unsold 50 GIVE. |
| Deploy dry run | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` | Simulation only, nothing broadcast. Estimated 4,655,610 gas for Market (with the implementation), `FillVerifier` and six example contracts. Market's CREATE2 address would be `0x8210144750E6237740bf71b819f87A834905445d`, the implementation `0xB11Fb472aC4DCd74296A18b82195B2127A7e0f87`. |
| Independent review | AI agent on `dd71a9e` | No critical, high, medium or low findings; four informational notes (H1 to H4), documented. PoC tests `test/review/LifecycleReviewPoC.t.sol`, 6 passed. See SECURITY.md, third review. |

Tests per suite: Core 32, Clone 10, SharedHandler 5, FillVerifier 10, Eip7702Filler 4, DutchAuction 14, TokenExchange 13, PaintAction 11, AcquisitionBid 20, Compose 4, NewOrderType 1, Gas 6, Invariant 1 (5 invariants), first review PoC 5, second review PoC 6, third review PoC 6.

### Gas

Whole-transaction gas from isolated runs, including the 21,000 base cost and calldata. "Before" is the clone design before the lifecycle change (`4a15d12`); the full-contract column is the design before clones (`c8bad35`). D004 in DECISIONS.md also lists a storage-initialized clone.

| Operation | Now | Before (clone) | Full contract |
| --- | --- | --- | --- |
| Create an order (any handler) | 93,973 to 96,890 | 93,973 to 96,890 | 482,124 to 485,024 |
| Fill: DutchAuction, 1 payee, with refund, closes | 122,214 | 122,360 | 117,189 |
| Fill: DutchAuction, 2 payees | 150,754 | 150,900 | 145,717 |
| Fill: TokenExchange, first partial / repeat | 114,634 / 80,434 | 114,664 / 80,464 | 110,522 / 76,322 |
| Fill: PaintAction, paint + resign + close | 111,432 | 111,578 | 106,416 |
| Fill: AcquisitionBid, own funds / drawing from pool | 132,738 / 110,535 | 132,768 / 110,580 | 128,637 / 105,713 |
| Owner closes | 47,129 | 46,994 | 44,173 |
| Owner withdraws an NFT (after closing) | 64,080 | 61,966 | 59,073 |

The lifecycle change costs nothing on fills (30 to 146 gas cheaper, from function dispatch after the rename and `close` no longer reading the owner during a fill). Owner recovery costs 2,114 more because `execute` reads the cold `closed` flag, and closing 135 more because it reads `filling` first. Fills that pay an address for the first time include 25,000 gas for creating that account; first writes to a storage slot cost 20,000, which is why closing costs about 22,000. At a 0.1 gwei base fee, creating an order costs about 0.00001 ETH.

## Not verified

1. No fork tests against real mainnet tokens, NFT collections or artworks. All tests use local contracts, including deliberately hostile ones.
2. No human audit. Three independent AI reviews (see SECURITY.md).
3. EIP-7702 fillers are tested only in Foundry's local EVM (`test/Eip7702Filler.t.sol`), with a stand-in batch executor, not with real wallet software. `FillVerifier` gas inside a real batch was not measured.
4. The full suite has run only on Solidity 0.8.30 with via-IR for Prague; on 0.8.28 for Cancun only the Core, Clone, Compose and SharedHandler suites.
5. Gas figures are local measurements under Prague rules; real costs depend on calldata size, warm or cold accounts and gas price.
6. Block explorer display and verification of clone orders has not been checked.
7. Owner maintenance through a handler is shown with a test-only handler; none of the four examples offers it.

## Next actions

1. Owner review of the items in DECISIONS.md, Owner review (license holder, cheap sales restarting the rising bid, the core's OpenZeppelin `Clones` import, setup and maintenance of active orders going through handlers).
2. If the primitive holds up, fork tests with real assets (a mainnet ERC721 and USDC or USDT through `TokenExchange`), then an independent audit before any deployment that holds value.
3. A minimal read-only page or script that lists orders from `Market.Created` and decodes known handlers, if useful for experiments.
