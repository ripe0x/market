# Status

Updated 2026-11-04. Branch `feat/execution-protocol-v1`.

## State

Exploratory implementation, complete for the first milestone: the core, four examples, a fifth minimal order type, tests, local demo and dry-run deployment. **Not audited, not deployed.** No mainnet transaction, funded signing or paid service has been used.

| Area | State |
| --- | --- |
| Core (`src/`) | Implemented: `Market`, `Order`, `IPolicy` |
| Example 1, NFT sale (`DutchAuction`) | Implemented and tested |
| Example 2, ERC20 exchange (`TokenExchange`) | Implemented and tested |
| Example 3, artwork action (`PaintAction`, `Artwork`) | Implemented and tested |
| Example 4, persistent bid (`AcquisitionBid`, strategies, `CapitalPool`) | Implemented and tested |
| New order type without core change (`BellPolicy`) | Test only |
| Composition (sale matched into bid) | Test only (`Matcher` in `test/Compose.t.sol`) |
| Filler-side receipt checks | Test only: guarded contract buyer (`test/Compose.t.sol`), EIP-7702 delegated EOA (`test/Eip7702Filler.t.sol`) |
| Local demo | `script/demo.sh` runs all four examples on anvil |
| CI | `.github/workflows/test.yml`: `forge build --sizes` and `forge test` on pull requests and pushes to `main`, Foundry v1.8.1 |
| Deployment | `script/Deploy.s.sol` simulated locally and against mainnet RPC; never broadcast |
| Frontend, indexer, keeper | Not built (out of scope for this milestone) |

## Evidence

Candidate: code at commit `c8bad35` (later commits change only docs and the gas snapshot). Toolchain: forge 1.8.1 (`982849d`), solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-04.

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | Exit 0. 100 passed, 0 failed, 11 suites. Fuzz tests 1,000 runs each. |
| Invariants | (in the full suite) `test/Invariant.t.sol` | 4 invariants, 128 runs x 64 calls = 8,192 calls, 0 reverts; 993 attacker attempts, none succeeded. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | `snapshots/GasTest.json`, table below. |
| Coverage | `CANDIDATE_RUN=1 forge coverage --ir-minimum --report summary --no-match-coverage 'test\|script'` | `src/` and `examples/`: 97.7% lines (172/176), 95.6% statements, 81.1% branches, 97.3% functions. `--ir-minimum` coverage is approximate. |
| Sizes | `forge build --sizes` | `Order` 2,085 bytes runtime, `Market` 3,116; largest example `Artwork` 3,813. |
| Local demo | `script/demo.sh` | All four examples executed on a throwaway anvil node (chain 31337): "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL". |
| Deploy dry run | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` | Simulation only, nothing broadcast. Estimated 4,124,384 gas for Market plus six example contracts at base fee 0.115 gwei. Market's CREATE2 address would be `0xBd8Ed979dd8E733CD9B2f7a43ce04697ea6B4670`. |
| Independent review | AI agent on `a50ff04`; repair re-review on `c8bad35` | No critical, high or medium findings. F2, F3, F4 fixed; F1 documented. See SECURITY.md. |

Tests per suite: Core 27, DutchAuction 13, TokenExchange 13, PaintAction 10, AcquisitionBid 18, Compose 4, NewOrderType 1, Eip7702Filler 2, Gas 6, Invariant 1 (4 invariants), review PoC 5.

### Gas

Whole-transaction gas from isolated runs, including the 21,000 base cost and calldata.

| Operation | Gas |
| --- | --- |
| Create an order (any policy) | 482,124 to 485,024 |
| Fill: DutchAuction, 1 payee, with refund, closes | 117,189 |
| Fill: DutchAuction, 2 payees | 145,717 |
| Fill: TokenExchange, first partial / repeat | 110,522 / 76,322 |
| Fill: PaintAction, paint + resign + close | 106,416 |
| Fill: AcquisitionBid, own funds / drawing from pool | 128,637 / 105,713 |
| Owner closes / withdraws an NFT | 44,173 / 59,073 |

Fills that pay an address for the first time include 25,000 gas for creating that account; first writes to a storage slot cost 20,000. At a 0.1 gwei base fee, creating an order costs about 0.00005 ETH.

## Not verified

1. No fork tests against real mainnet tokens, NFT collections or artworks. All tests use local contracts, including deliberately hostile ones.
2. No human audit. One independent AI review (see SECURITY.md).
3. EIP-7702 fillers are tested only in Foundry's local EVM (`test/Eip7702Filler.t.sol`), not with real wallet software.
4. Only Solidity 0.8.30 with via-IR has been compiled and tested.
5. Gas figures are local measurements under Prague rules; real costs depend on calldata size, warm or cold accounts and gas price.

## Next actions

1. Owner review of the open decisions in DECISIONS.md (deployment gas, filler protection boundary, mutable policies, no signatures, license).
2. If the primitive holds up, fork tests with real assets (a mainnet ERC721 and USDC or USDT through `TokenExchange`), then an independent audit before any deployment that holds value.
3. A minimal read-only page or script that lists orders from `Market.Created` and decodes known policies, if useful for experiments.
