# Status

Updated 2026-11-06. Branches `feat/nft-trading` (milestone 2) and `feat/deployment` (milestone 4, on top of it).

## State

The experimental core (`src/`) was merged to `main` on 2026-11-06 (PR #2, merge commit `46b7794`) after its full suite passed (148/148) with green CI. On top of it:

1. **Reference NFT trading handlers** `NFTSale` and `NFTBid` (`handlers/`), with fixed, falling and rising prices, ERC2981 royalties paid from the price and never skipped, buyer and seller limits, escrow, persistent bids and cancellation. No core change.
2. **Finding A1**: an approval a filler gives an order is usable by the order's owner after closing. `NFTBid` holds sellers' approvals itself and authenticates orders (D205); the teaching examples that take approvals to their orders carry warnings. Owner decision pending (DECISIONS, Owner review 6).
3. **Mainnet fork tests** against BAYC, Azuki, Moonbirds, Opepen, Chimpers, ENS and CryptoPunks.
4. **Deployment**: CREATE2 deployment script, lifecycle script exercising sales, a persistent bid and PaintAction, fork rehearsal script, Sepolia and mainnet commands, release checklist.
5. **Developer documentation**: [HANDLERS.md](HANDLERS.md), [NFT_TRADING.md](NFT_TRADING.md), [DEPLOYMENT.md](DEPLOYMENT.md).

**Not audited. Not deployed to any public chain.** No mainnet transaction, funded signing or paid service has been used.

| Area | State |
| --- | --- |
| Core (`src/`) | Merged to `main`; unchanged since |
| Reference handlers (`handlers/`) | `NFTSale`, `NFTBid`, `NFTTrade`, `HandlerBase`; unit, fuzz, invariant and fork tested |
| Teaching examples (`examples/`) | Unchanged apart from NatSpec warnings (A1) and the `HandlerBase` move |
| Non-NFT example | `PaintAction` + `Artwork`: unit tests, documented end to end in HANDLERS.md, executed by `script/Lifecycle.s.sol` |
| Periphery | `FillVerifier`, unchanged |
| Deployment | Rehearsed on Sepolia and mainnet forks. **Sepolia broadcast not done**: see Blockers |
| CI | `forge build --sizes`, the suite without fork tests, and the fork tests as a separate job |
| Frontend, indexer, keeper | Out of scope |

## Evidence

Toolchain: forge 1.8.1, solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-06.

| Check | Command | Result |
| --- | --- | --- |
| Core merge candidate | `CANDIDATE_RUN=1 forge test` at `5a5ded8` | 148 passed, 0 failed; CI `forge` job green |
| NFT handler unit and fuzz tests | `forge test --match-path "test/NFT{Sale,Bid}.t.sol"` | 40 passed (23 sale, 17 bid), fuzz 1,000 runs each |
| NFT invariants | `forge test --match-path test/NFTInvariant.t.sol` | 5 invariants, 128 runs x 64 calls, 0 reverts; 1,018 theft attempts, none succeeded |
| Deep invariants | `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-test invariant` | All 10 invariants of both suites hold, 128,000 calls each, 0 reverts |
| Mainnet fork | `forge test --match-path test/fork/NFTFork.t.sol --isolate` | 14 passed at block 26,357,000; gas in `snapshots/NFTFork.json` |
| Static analysis | Slither 0.11.5 on `handlers/NFTBid.sol`, `handlers/NFTSale.sol`, `periphery/FillVerifier.sol`, `examples/PaintAction.sol` (and through them `src/`) with solc 0.8.30, informational and optimization excluded | No actionable result. Triage below |
| Sepolia fork rehearsal | `script/rehearse.sh` | Deploy, Lifecycle and recover all succeed on chain 11155111 forked at block 12,077,938 |
| Mainnet fork rehearsal | `script/rehearse.sh https://mainnet.gateway.tenderly.co` | Same, chain 1 forked at block 26,357,257; deploy estimate 6,704,108 gas |
| cast walkthrough | Commands in HANDLERS.md against local anvil | Create, escrow, quote and fill succeed as written |

Slither triage. `arbitrary-send-eth` (`Order.execute`): authorized by the lifecycle rules. `arbitrary-send-erc20` (`NFTBid._transfer`): `from` is the authenticated filler (D205). `locked-ether` (`Market`): `create` forwards its ETH into the new order. `reentrancy-no-eth`, `reentrancy-events` (`Order.fill`, handlers): reentry into the same order is refused by `filling`; events after calls only affect log order. `uninitialized-local` (`HandlerBase._pay`): zero start intended. `timestamp`: price schedules are time based by design. `missing-zero-check`: `execute` targets are the caller's choice. Running Slither over the whole project fails on a source-mapping error in `test/Invariant.t.sol`; production sources were analyzed directly.

### Gas

See [NFT_TRADING.md](NFT_TRADING.md#gas) for the full table and the Seaport comparison. Headline: a sale fill costs 162,746 to 217,139 gas and a bid fill 132,592 to 187,306 on real collections, within the range of direct Seaport single-order fills from the same blocks (111,622 to 273,243). Creating an order costs about 95,000; a listing also needs a deposit transaction (67,026 to 110,187).

## Blockers

1. **Sepolia deployment.** Keystores named `sepolia-deployer` and `keeper-sepolia` exist on this machine, but they are password protected and belong to other projects; no password or funded signer was provided. Everything else is done and rehearsed. To finish: run the three commands in [DEPLOYMENT.md](DEPLOYMENT.md#sepolia) with a funded keystore, then record the addresses and transaction hashes there.
2. **Mainnet deployment** needs an independent human audit, the owner decisions in DECISIONS.md and the owner's explicit approval (release checklist in DEPLOYMENT.md).

## Not verified

1. No human audit. AI reviews only (SECURITY.md).
2. No transaction on a public chain.
3. Fork tests impersonate holders; real wallet software and real EIP-7702 delegates other than the one Opepen holder uses were not exercised.
4. Explorer verification of the CREATE2 deployments and display of clone orders.
5. The teaching examples have no fork tests.
6. Gas figures are fork measurements under current rules; real costs depend on calldata, warm or cold accounts and gas price.

## Next actions

1. Owner: decide DECISIONS Owner review items, especially 6 (finding A1 and the teaching examples).
2. Provide a funded Sepolia signer; run the Sepolia commands; record the deployment.
3. Independent human audit of `src/`, `handlers/`, `periphery/` before any value-bearing deployment.
