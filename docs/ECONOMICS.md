# Economics

Measured 2026-10-30 for the escrow design (D023 to D035). Mainnet base fee at measurement: 0.40 gwei.

## Fees (D033)

All fees come out of the sale price, the amount the buyer pays.

| Path | Royalty (ERC-2981) | Protocol | Executor | Referral |
| --- | --- | --- | --- | --- |
| `buy` | yes | 0.20% | none | 0.10% of the 0.20%, if named |
| Sell into a bid | yes | 0.20% | none | 0.10% of the 0.20%, if named |
| `matchBid` | yes | 0.20% | 0.30% to caller | none |
| `fillOffer` (OpenSea) | none from Market; the offer pays OpenSea's fee and creator fee | 0.20% | 0.30% to caller | none |

The seller always receives at least the ask. A direct buyer pays the ask grossed up for royalty and the protocol fee: about `ask / (1 - royalty - 0.002)`.

## Gas

Whole-transaction receipts from `cd app && npm run e2e:keeper` (anvil fork at block 26303107, real OpenSea item offer):

| Action | Gas used (receipt) |
| --- | --- |
| `fillOffer`, real OpenSea item offer | 314,473 |
| `matchBid` | 136,407 |

Execution gas of the other paths on a pinned fork with real WETH and Otherdeed (`forge test --match-path test/Gas.t.sol -vv`, `gasleft` around each call). These run inside one test transaction and read higher than receipts (the same harness reports 435,583 for `fillOffer`), so treat them as upper bounds:

| Action | Execution gas, upper bound |
| --- | --- |
| List (`safeTransferFrom` deposit) | 156,605 |
| `buy` with ETH | 214,067 |
| `createBid` with ETH | 108,215 to 125,311 |
| Sell into a bid | 216,792 |
| `cancelListing` | 58,846 |
| `withdrawListing` | 102,033 |
| `withdrawBid` | 65,240 |

OpenSea's own accept-offer for the same offer used 263,662. Listing now costs a deposit transaction; the old design listed by signature only.

## Keeper profitability

Profit = executor fee (0.30% of the sale price) minus gas, before API and hosting cost.

**`fillOffer`, 314,473 gas:**

| Sale price (WETH) | Executor fee | Protocol fee | 0.4 gwei | 1 gwei | 3 gwei | 10 gwei | 30 gwei |
|---|---|---|---|---|---|---|---|
| 0.05 | 0.00015 | 0.00010 | +0.00002 | -0.00016 | -0.00079 | -0.00299 | -0.00928 |
| 0.1 | 0.00030 | 0.00020 | +0.00017 | -0.00001 | -0.00064 | -0.00284 | -0.00913 |
| 0.5 | 0.00150 | 0.00100 | +0.00137 | +0.00119 | +0.00056 | -0.00164 | -0.00793 |
| 1 | 0.00300 | 0.00200 | +0.00287 | +0.00269 | +0.00206 | -0.00014 | -0.00643 |
| 5 | 0.01500 | 0.01000 | +0.01487 | +0.01469 | +0.01406 | +0.01186 | +0.00557 |
| 10 | 0.03000 | 0.02000 | +0.02987 | +0.02969 | +0.02906 | +0.02686 | +0.02057 |

**Minimum viable sale price** (keeper default margin 1.25x gas):

| Base fee | `fillOffer` break-even | with margin | `matchBid` break-even | with margin |
| --- | --- | --- | --- | --- |
| 0.4 gwei | 0.042 | 0.052 | 0.018 | 0.023 |
| 1 gwei | 0.105 | 0.131 | 0.045 | 0.057 |
| 3 gwei | 0.314 | 0.393 | 0.136 | 0.171 |
| 10 gwei | 1.048 | 1.310 | 0.455 | 0.568 |
| 30 gwei | 3.145 | 3.931 | 1.364 | 1.705 |

The keeper computes this per candidate from the live base fee and skips anything below it. Below the threshold a listing still sells by direct buy or a bid sell, which cost the executor nothing.

## How often matching adds a fill

OpenSea carried about 99% of Ethereum ERC721 bid fills over 24 hours: 4,075 fills, 214.1 WETH, 331 at or above 0.064 WETH (`PHASE0_EVIDENCE.md`). At 0.4 gwei the `fillOffer` threshold (0.052 WETH with margin) admits a few hundred offers a day across all collections. Market's own bids add a second source that is cheaper to fill. There is no evidence yet of Market bid demand.

## Seller outcome versus alternatives

- **Accepting the offer yourself on OpenSea:** you get the released amount and pay about 264k gas. Through Market you pay the deposit (under 160k execution gas) and 0.5% of the sale price, and need not watch. If you would accept today's best offer anyway, accept it directly.
- **Fixed price:** sells only at that price. A falling price trades time for price discovery; it does not maximize proceeds.
- **Surplus:** a falling ask usually crosses an existing offer and fills just after, so surplus is small. `matchBid` gives the seller the whole gap to the bid; arbitrage through `buy` plus an outside resale can take it first (D025).

## Fee decision (D033)

Keep 0.30% executor and 0.20% protocol, with a 0.10% referral share out of the protocol fee. At today's gas, OpenSea fills are viable from about 0.052 WETH and Market bid matches from about 0.023 WETH. Revisit if typical base fee rises above about 3 gwei.

## Operating cost

- OpenSea API key: free tier, rate limited. Required for offer discovery and zone signatures.
- RPC: public endpoint works for development; a paid RPC is advisable for the keeper.
- Hosting: one small Node host for web and keeper with a local SQLite file.
- Keeper wallet: holds only ETH for gas.
