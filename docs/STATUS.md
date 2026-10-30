# Project status

Updated: 2026-10-30

## State

Escrow design (owner decisions D023 to D035) implemented and locally verified: contract, real-offer fork proof, keeper, indexer, web app, dry-run deployment, independent AI review. **Not deployed, not audited, not launch ready.** No real asset transactions, no mainnet deployment.

## Milestone ledger

| Phase | State | Evidence |
| --- | --- | --- |
| 0. Seaport integration proof | Done for escrow: real OpenSea offers fill from Market custody | `test/OpenSea.t.sol`, `PHASE0_EVIDENCE.md` |
| 1. Settlement (escrow) | Done | `contracts/Market.sol`; `test/Local.t.sol`, `test/Invariant.t.sol`, `test/OpenSea.t.sol`, `test/review/Review.t.sol` |
| 2. Keeper and indexer | Done; both routes settle on a fork | `app/keeper/`, `app/lib/server.ts`, `npm run e2e:keeper` |
| 3. User interface | Done; exercised on a local fork | sell, buy, bids, sell into bid, cancel, withdraw, mobile |
| 4. Review and economics | Independent AI review done, finding 1 fixed; economics measured | `SECURITY.md`, `ECONOMICS.md` |
| 5. Deployment readiness | Dry run passes; mainnet blocked on audit, canary and owner decisions | `OPERATIONS.md` |

## Verification record

Revision `99d2c20` (contract) and `e62cc3d` (app). Run on 2026-10-30.

| Check | Command | Result |
| --- | --- | --- |
| Real OpenSea offers from escrow, both fixtures, adversarial offers | `forge test --match-path test/OpenSea.t.sol` | 22/22 pass |
| Listings, buys, bids, matches, royalties, strategies, callbacks, fuzz | `forge test --match-path test/Local.t.sol --fuzz-runs 2000` | 28/28 pass |
| Escrow solvency and custody invariants | `forge test --match-path test/Invariant.t.sol` | pass, 64 runs x 100 calls, sales in every run |
| Independent review PoCs | `forge test --match-path test/review/Review.t.sol` | 5/5 pass |
| Gas per path | `forge test --match-path test/Gas.t.sol -vv` | 5/5 pass; figures in `ECONOMICS.md` |
| TS unit (shape normalization, price and fee math, encoders) | `cd app && node --test --import tsx lib/*.test.ts keeper/*.test.ts` | 11/11 pass |
| Keeper on fork: real OpenSea offer via `fillOffer`, native `matchBid` | `cd app && npm run e2e:keeper` | pass; 314,473 and 136,407 gas |
| Typecheck, production build | `cd app && npx tsc --noEmit`, `npx next build` | pass |
| Deploy dry run | `PROTOCOL_FEE_RECIPIENT=… MARKET_OWNER=… forge script script/Deploy.s.sol --rpc-url mainnet` | pass, 5.3M gas estimate |
| UI on local fork | browse, buy, create bid, sell into bid, zero-floor warning, 375px width | pass (app agent run; `scripts/fork.sh`) |

Not run: full suite as a release candidate (`CANDIDATE_RUN=1`); `fillOffer` inside the invariant handler (fork only); live OpenSea signing for a deployed Market.

## Open blockers

1. **Mainnet canary (D023):** only a deployment can prove OpenSea signs for Market's address. Needs separate owner authorization and one low-value NFT (`OPERATIONS.md`, step 6).
2. **Independent human audit** of `contracts/Market.sol` before any deployment with value. Market holds custody.
3. **Owner decisions:** owner and fee recipient addresses; self-referral (review finding 2); see `DECISIONS.md` Owner Review.

## Known gaps

- Owned-NFT pickers need an OpenSea API key; without one, sell and sell-into-bid take a manual contract and token id.
- `buy` passes the quoted price as `maxPrice`; a rising listing can tick up before inclusion and revert, so the buyer retries.
- Header navigation is tight at 375px.

## Next action

Owner reviews `DECISIONS.md` Owner Review. Then: freeze a release candidate, run `CANDIDATE_RUN=1`, commission the human audit, and plan the canary under separate authorization.

## Launch boundary

No transactions with real assets, mainnet deployment, paid services, public launch, or remote push without explicit owner authorization.
