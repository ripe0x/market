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
| Deployment | `script/Deploy.s.sol` simulated locally and against mainnet RPC; never broadcast |
| Frontend, indexer, keeper | Not built (out of scope for this milestone) |

## Evidence

RESULTS_PENDING

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
