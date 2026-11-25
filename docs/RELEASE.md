# Release outcomes and scorecard (unified action candidate)

**Status: draft for owner approval.** Nothing here is approved until the owner says so. Rates and prices in the measured column are local test conditions, not launch settings.

## Proposed outcomes

| # | Outcome (where assets end up) | Number |
| --- | --- | --- |
| O1 | A sale buyer pays at most their `maxPrice`; anything sent above the price returns to them in the same transaction. The seller's `proceedsTo` receives `price - fee - royalty`. | Fee rate at most 1% (100 bps). |
| O2 | Royalty never exceeds `price - fee` nor the seller's `maxRoyaltyBps`; a covered purchase's royalty is fixed at activation. | Seller receives at least `price * (10000 - feeBps - maxRoyaltyBps) / 10000`. |
| O3 | A bid seller receives at least their `minProceeds`. A bidder's unspent deposit is fully withdrawable after cancel or expiry. | 100% of free balance recoverable by the residual. |
| O4 | A covered right's holder pays exactly the fixed price and receives the NFT; issuer proceeds and royalty become withdrawable credits. On surrender or expiry the residual recovers the NFT. | 100% of escrowed NFTs recoverable; 0 royalty on surrender or expiry. |
| O5 | The fee rate of a live order never changes. The fee admin can only set the rate (at most 1%, later activations only) and the recipient (later executions). No one can move an order's assets except through its bound action. | Max fee 100 bps; admin powers: 2. |
| O6 | No ETH is stranded: every order keeps `balance >= totalCredits`; every credit is withdrawable by its beneficiary in every terminal state. | 0 wei shortfall. |
| O7 | Market, Actions and the shared actions hold no user ETH between transactions. | 0 wei. |

## Scorecard

| # | Unit and adversarial tests | Invariant 1000 x 128 | Mainnet fork | Local signed rehearsal (client, 36 tx) | Sepolia | Mainnet canary |
| --- | --- | --- | --- | --- | --- | --- |
| O1 | Pass (`Exchange.t.sol`) | Pass | Pass (5 fork tests, block 26,450,000; lifecycle rehearsal at 26,493,718) | 1 ETH sale: fee 0.01, royalty 0.05, proceeds 0.94, 0.2 refunded | Pending | Pending |
| O2 | Pass, incl. royalty capped at `price - fee` | Pass | Pass | Royalty 5% within limit; over-limit listing shown blocked | Pending | Pending |
| O3 | Pass | Pass | Pass | 0.5 ETH bid: fee 0.005, royalty 0.0125, proceeds 0.4825; 0.5 ETH recovered via cancel + `withdrawSurplus` | Pending | Pending |
| O4 | Pass (`Covered.t.sol`) | Pass | Fork lifecycle: acquire payer spent exactly 6 ETH, 1 ETH refunded | 0.5 ETH exercise: royalty credit 0.0125, proceeds credit 0.4875, both withdrawn; NFT recovered via surrender + release | Pending | Pending |
| O5 | Pass (`Core`, `Exchange`, review PoCs) | Pass | n/a | n/a | Pending | Pending |
| O6 | Pass (`Credits.t.sol`) | Pass, 0 reverts | n/a | All credits withdrawn to zero | Pending | Pending |
| O7 | Pass | Pass | n/a | Not measured | Pending | Pending |

## Values that only increase

Each needs the owner's reason before launch:

1. `Market.isOrder` entries are permanent (provenance).
2. `ExchangeAction` bid execution counters only increase (no replay past `maxExecutions`).
3. Reservation records are permanent per executor address (single use; finding R1).
4. Burned Actions token ids are never reused.

## Gaps

- No launch-scale amounts measured (for example a 100 ETH sale or a 1,000-item collection bid).
- Sepolia and mainnet columns need real transactions.
- No independent external audit.
- The core has no caps or pause; a canary limits only the owner's own usage.
