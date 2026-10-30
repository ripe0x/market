# Project status

Updated: 2026-10-30

## State

Implemented and locally verified: settlement contract, real-offer fork proof, direct buy, onchain cancel, keeper, order storage, web app, dry-run deployment. **Not deployed, not audited, not launch ready.** No real asset transactions, no mainnet deployment, no remote push.

## Milestone ledger

| Phase | State | Evidence |
| --- | --- | --- |
| 0. Seaport integration proof | Chain mechanics pass; live OpenSea signing fails: OpenSea signs only for the NFT owner (D023) | `PHASE0_EVIDENCE.md`, `test/MatchOffer.t.sol` |
| 1. Settlement | Done | `contracts/Market.sol`; `test/Buy.t.sol`, `test/Adversarial.t.sol` |
| 2. Matcher | Built; blocked on mainnet by D023 | `app/keeper/`, `npm run e2e:keeper` |
| 3. User interface | Done; exercised end to end on a local fork | `scripts/fork.sh` session below |
| 4. Review and economics | Independent review done (see `SECURITY.md`); economics measured | `SECURITY.md`, `ECONOMICS.md` |
| 5. Deployment readiness | Dry run passes; mainnet blocked on audit and owner decisions | `OPERATIONS.md` |

## Verification record

| Check | Command | Result |
| --- | --- | --- |
| Real OpenSea offers, both fixtures | `forge test --match-path test/MatchOffer.t.sol` | 20/20 pass |
| Direct buy, pricing fuzz | `forge test --match-path test/Buy.t.sol` | 15/15 pass (fuzz 256 runs each) |
| Adversarial | `forge test --match-path test/Adversarial.t.sol` | 7/7 pass |
| TS unit and fixture parity | `cd app && npm test` | 8/8 pass |
| Independent review tests | `forge test --match-path test/review/Review.t.sol` | 4/4 pass |
| Keeper on fork, real offer, API intake | `cd app && npm run e2e:keeper` | pass, 383,787 gas |
| OpenSea eligibility and indexing; venue liquidity | `cd app && npx tsx research/eligibility.ts`, `research/indexing-recent.ts`, `research/indexing-live.ts` | 45/48 contracts signed; indexed in 2 to 8 s; OpenSea carries about 99% of bids |
| Live OpenSea fulfiller, latest-block fork | `cd app && npm run live:fulfiller -- <nft> <tokenId>` with `OPENSEA_API_KEY` | fail: `Item is not owned by the fulfiller` (D023) |
| Typecheck, production build | `npx tsc --noEmit`, `npx next build` | pass |
| Deploy dry run | `forge script script/Deploy.s.sol --rpc-url mainnet` | pass, 2.34M gas |
| UI on local fork | list, approve, sign, buy, keeper match, cancel, yours page, mobile, light and dark | pass |

Full suite as a release candidate (`CANDIDATE_RUN=1`) has not been run.

## Open blockers

1. **D023: OpenSea signs offers only for the NFT owner.** Checked live on 2026-10-30. Investigation done: escrow is practical (45 of 48 contract holders signed; deposits indexed in 2 to 8 seconds), and there is no usable noncustodial liquidity elsewhere. Recommendation: escrow for all listings. Owner approval needed. Evidence: `PHASE0_EVIDENCE.md`.
2. **Independent audit** of `contracts/Market.sol` by a qualified human reviewer before any deployment with value.
3. **Owner decisions:** fee recipient address, D016 (no floor hold), D017 (WETH refund). See `DECISIONS.md` Owner Review.

## Next action

Owner approves or rejects escrow (D023). If approved: redesign Market for custody, prove it on a fork with live OpenSea zone data, and get an independent review. Then plan a mainnet canary with one low-value NFT, which needs separate authorization.

## Launch boundary

No transactions with real assets, mainnet deployment, paid services, public launch, or remote push without explicit owner authorization.
