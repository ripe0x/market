# Project status

Updated: 2026-10-30

## State

**Escrow redesign in progress (owner decisions D023 to D035).** The new `contracts/Market.sol` (shared escrow: listings, bids, OpenSea fills) is implemented and tested. The keeper and web app still target the old noncustodial contract and do not work with it yet. **Not deployed, not audited, not launch ready.**

## Milestone ledger

| Phase | State | Evidence |
| --- | --- | --- |
| 0. Seaport integration proof | Done for escrow: real OpenSea offers fill from Market custody | `test/OpenSea.t.sol`, `PHASE0_EVIDENCE.md` |
| 1. Settlement (escrow) | Implemented and tested | `contracts/Market.sol`; `test/Local.t.sol`, `test/Invariant.t.sol`, `test/OpenSea.t.sol` |
| 2. Keeper | Needs rework for escrow | `app/keeper/` |
| 3. User interface | Needs rework for escrow | `app/src/` |
| 4. Review and economics | Pending for escrow design | |
| 5. Deployment readiness | Deploy script updated; dry run pending | `script/Deploy.s.sol` |

## Verification record

| Check | Command | Result |
| --- | --- | --- |
| Real OpenSea offers from escrow, both fixtures, adversarial offers | `forge test --match-path test/OpenSea.t.sol` | 22/22 pass |
| Listings, buys, bids, matches, royalties, strategies, callbacks, fuzz | `forge test --match-path test/Local.t.sol --fuzz-runs 2000` | 28/28 pass |
| Escrow solvency and custody invariants | `forge test --match-path test/Invariant.t.sol` | pass, 64 runs x 100 calls, sales in every run |

Earlier noncustodial evidence (superseded contract) remains in git history before this commit.

## Open blockers

1. **Mainnet canary (D023):** only a deployment can prove OpenSea signs for Market's address. Needs separate owner authorization.
2. **Independent audit** of `contracts/Market.sol` before any deployment with value.
3. **Owner decisions:** owner and fee recipient addresses; see `DECISIONS.md` Owner Review.

## Next action

Rework the keeper and app for escrow, then independent review, economics and deploy dry run.

## Launch boundary

No transactions with real assets, mainnet deployment, paid services, public launch, or remote push without explicit owner authorization.
