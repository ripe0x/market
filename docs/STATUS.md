# Status

Updated 2026-11-05. Branch `feat/execution-protocol-v1`.

## State

Exploratory implementation, complete for the first milestone: the core, four examples, a fifth minimal order type, an optional fill verifier, tests, local demo and dry-run deployment. On 2026-11-05 orders became ERC-1167 clones after owner review (DECISIONS D004). **Not audited, not deployed.** No mainnet transaction, funded signing or paid service has been used.

| Area | State |
| --- | --- |
| Core (`src/`) | Implemented: `Market`, `Order` (clone implementation), `IPolicy` |
| Periphery (`periphery/`) | Implemented: `FillVerifier`, optional |
| Example 1, NFT sale (`DutchAuction`) | Implemented and tested |
| Example 2, ERC20 exchange (`TokenExchange`) | Implemented and tested |
| Example 3, artwork action (`PaintAction`, `Artwork`) | Implemented and tested |
| Example 4, persistent bid (`AcquisitionBid`, strategies, `CapitalPool`) | Implemented and tested; price 0 refused |
| New order type without core change (`BellPolicy`) | Test only |
| Composition (sale matched into bid) | Test only (`Matcher` in `test/Compose.t.sol`) |
| Filler-side receipt checks | Contract fillers (`test/Compose.t.sol`); EIP-7702 delegated EOA with a generic batch executor and `FillVerifier` (`test/Eip7702Filler.t.sol`) |
| Local demo | `script/demo.sh` runs all four examples on anvil |
| CI | `.github/workflows/test.yml`: `forge build --sizes` and `forge test` on pull requests and pushes to `main`, Foundry v1.8.1 |
| Deployment | `script/Deploy.s.sol` simulated locally and against mainnet RPC; never broadcast |
| Frontend, indexer, keeper | Not built (out of scope for this milestone) |

## Evidence

Candidate: code at commit `0567907` (later commits change only docs). Toolchain: forge 1.8.1 (`982849d`), solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-05.

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | Exit 0. 129 passed, 0 failed, 14 suites. Fuzz tests 1,000 runs each. |
| Invariants | (in the full suite) `test/Invariant.t.sol` | 4 invariants, 128 runs x 64 calls = 8,192 calls, 0 reverts; 1,012 attacker calls, none succeeded. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | `snapshots/GasTest.json`, table below. |
| Coverage | `CANDIDATE_RUN=1 forge coverage --ir-minimum --report summary --no-match-coverage 'test\|script'` | `src/`, `periphery/` and `examples/`: 93.0% lines (212/228), 92.6% statements, 84.8% branches, 98.0% functions. `Market`, `Order` and `FillVerifier` branches 100%; their uncovered lines are inline assembly, which `--ir-minimum` coverage does not attribute. Approximate. |
| Sizes | `forge build --sizes` | `Order` implementation 2,118 bytes runtime, `Market` 1,277, `FillVerifier` 1,058; each order clone 149 bytes; largest example `Artwork` 3,813. |
| Compiler and EVM | `forge build --use <solc> --evm-version <evm> src periphery examples` | Compiles with solc 0.8.28 and 0.8.30, each for Cancun and Prague. `forge test --use 0.8.28 --evm-version cancun --match-path "test/C*.t.sol"`: Core, Clone and Compose suites, 41 passed (at `03c263f`, same core). |
| Local demo | `script/demo.sh` | All four examples executed on a throwaway anvil node (chain 31337): "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL". Run at `03c263f`; core and examples are unchanged in the candidate. |
| Deploy dry run | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` | Simulation only, nothing broadcast. Estimated 4,635,965 gas for Market (with the implementation), `FillVerifier` and six example contracts. Market's CREATE2 address would be `0xFf89fd6936CB291122be089F87dcC5AEC5d9de3c`, the implementation `0x39CAB65251035776D9cfC1734d01dc69b582e396`. |
| Independent review | AI agent on `03c263f` | No critical, high or medium findings. G1 (low, `FillVerifier` snapshot reuse) fixed in `0567907`. See SECURITY.md. |

Tests per suite: Core 27, Clone 10, FillVerifier 10, Eip7702Filler 4, DutchAuction 13, TokenExchange 13, PaintAction 10, AcquisitionBid 19, Compose 4, NewOrderType 1, Gas 6, Invariant 1 (4 invariants), first review PoC 5, second review PoC 6.

### Gas

Whole-transaction gas from isolated runs, including the 21,000 base cost and calldata. The full-contract column is the previous design at `c8bad35`; D004 in DECISIONS.md also lists a storage-initialized clone.

| Operation | Clone (now) | Full contract (before) |
| --- | --- | --- |
| Create an order (any policy) | 93,973 to 96,890 | 482,124 to 485,024 |
| Fill: DutchAuction, 1 payee, with refund, closes | 122,360 | 117,189 |
| Fill: DutchAuction, 2 payees | 150,900 | 145,717 |
| Fill: TokenExchange, first partial / repeat | 114,664 / 80,464 | 110,522 / 76,322 |
| Fill: PaintAction, paint + resign + close | 111,578 | 106,416 |
| Fill: AcquisitionBid, own funds / drawing from pool | 132,768 / 110,580 | 128,637 / 105,713 |
| Owner closes / withdraws an NFT | 46,994 / 61,966 | 44,173 / 59,073 |

Fills that pay an address for the first time include 25,000 gas for creating that account; first writes to a storage slot cost 20,000, which is why closing costs about 22,000. At a 0.1 gwei base fee, creating an order costs about 0.00001 ETH.

## Not verified

1. No fork tests against real mainnet tokens, NFT collections or artworks. All tests use local contracts, including deliberately hostile ones.
2. No human audit. Two independent AI reviews (see SECURITY.md).
3. EIP-7702 fillers are tested only in Foundry's local EVM (`test/Eip7702Filler.t.sol`), with a stand-in batch executor, not with real wallet software. `FillVerifier` gas inside a real batch was not measured.
4. The full suite has run only on Solidity 0.8.30 with via-IR for Prague; on 0.8.28 for Cancun only the Core, Clone and Compose suites.
5. Gas figures are local measurements under Prague rules; real costs depend on calldata size, warm or cold accounts and gas price.
6. Block explorer display and verification of clone orders has not been checked.

## Next actions

1. Owner review of the items in DECISIONS.md, Owner review (license holder, cheap sales restarting the rising bid, the core's OpenZeppelin `Clones` import, the policy code pin and delegated-account refusal).
2. If the primitive holds up, fork tests with real assets (a mainnet ERC721 and USDC or USDT through `TokenExchange`), then an independent audit before any deployment that holds value.
3. A minimal read-only page or script that lists orders from `Market.Created` and decodes known policies, if useful for experiments.
