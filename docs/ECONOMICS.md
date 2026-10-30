# Economics

Measured 2026-10-30. Gas from fork receipts (`docs/PHASE0_EVIDENCE.md`). Mainnet base fee at measurement: 0.40 gwei.

## Fees

| Path | Who pays | Fee | Recipient |
| --- | --- | --- | --- |
| Direct buy | Buyer, on top of the price | 0.20% of price | Protocol |
| Offer match | Taken from WETH the offer releases (seller amount + surplus) | 0.30% | Executor (caller) |
| | | 0.20% | Protocol |

The seller always receives at least the listing's current price. On a match the seller also receives all surplus minus the 0.5%.

## Keeper profitability

One match costs **383,763 gas** (real OpenSea offer, whole transaction). Profit = executor fee minus gas, before API and hosting cost.

| Released (WETH) | Executor fee | Protocol fee | 0.4 gwei | 1 gwei | 3 gwei | 10 gwei | 30 gwei |
|---|---|---|---|---|---|---|---|
| 0.05 | 0.00015 | 0.00010 | -0.00000 | -0.00023 | -0.00100 | -0.00369 | -0.01136 |
| 0.1 | 0.00030 | 0.00020 | +0.00015 | -0.00008 | -0.00085 | -0.00354 | -0.01121 |
| 0.5 | 0.00150 | 0.00100 | +0.00135 | +0.00112 | +0.00035 | -0.00234 | -0.01001 |
| 1 | 0.00300 | 0.00200 | +0.00285 | +0.00262 | +0.00185 | -0.00084 | -0.00851 |
| 5 | 0.01500 | 0.01000 | +0.01485 | +0.01462 | +0.01385 | +0.01116 | +0.00349 |
| 10 | 0.03000 | 0.02000 | +0.02985 | +0.02962 | +0.02885 | +0.02616 | +0.01849 |

**Minimum viable match** (keeper default margin 1.25x gas):

| Base fee | Gas cost | Break-even released | With 1.25x margin |
| --- | --- | --- | --- |
| 0.4 gwei | 0.000154 ETH | 0.051 | 0.064 |
| 1 gwei | 0.000384 ETH | 0.128 | 0.160 |
| 3 gwei | 0.001151 ETH | 0.384 | 0.480 |
| 10 gwei | 0.003838 ETH | 1.279 | 1.599 |
| 30 gwei | 0.011513 ETH | 3.838 | 4.797 |

The keeper computes this per candidate from the live base fee and skips anything below it. Listings below the threshold can still sell by direct buy, or by any executor willing to subsidize.

Failed attempts cost the executor gas only. Simulation before submission makes them rare; the remaining causes are races (offer filled, cancelled, or the listing bought first) and zone signatures expiring in the mempool.

## How often matching adds a fill

Sparse evidence, one hour (300 blocks before 26303129): 7 OpenSea accept-offer fills on Seaport 1.6. Offer sizes: 0.002, 0.0072, 0.0074, 0.0124, 0.0128, 0.0617, 0.235 WETH. At 0.4 gwei only 2 of 7 clear the threshold. Matching is a meaningful path for established collections with offers above roughly 0.1 WETH; it is not a reason to expect sales of small NFTs.

## Seller outcome versus alternatives

- **Accept the offer yourself on OpenSea:** you get the released amount and pay about 264k gas. Through Market you get 0.5% less and pay no gas, without watching. If the seller would accept today's best offer anyway, accepting it directly is cheaper.
- **Fixed-price listing:** sells only at that price. A declining price trades time for price discovery; it does not maximize proceeds.
- **Surplus is not guaranteed.** The price falls continuously, so a match usually fires just after the price crosses an existing offer, leaving little surplus. Surplus is large only when a new, higher offer appears while the price is still above it.
- **Anyone can buy at the current price and resell into a higher offer.** That arbitrage takes the surplus a match would have paid the seller. Running the keeper often and submitting privately narrows the window; it cannot close it.

## Fee decision (D006)

Keep 0.30% executor and 0.20% protocol. At today's gas, matching is viable from about 0.06 WETH. A higher executor share would lower the threshold but take more from every seller; a fixed fee would overcharge large sales. Revisit if typical base fee rises above about 3 gwei.

## Operating cost

- OpenSea API key: free tier, rate limited. Required in practice (see `PHASE0_EVIDENCE.md`).
- RPC: public endpoint works for development; a paid RPC is advisable for the keeper.
- Hosting: one small Node host for web and keeper with a local SQLite file.
- Keeper wallet: holds only ETH for gas.
