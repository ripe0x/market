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

Execution gas on a pinned fork with real WETH and a real NFT (Otherdeed), first touch of every slot (`forge test --match-path test/Gas.t.sol -vv`). Execution excludes the 21,000 base and calldata.

| Action | Execution gas | Whole transaction, estimated |
| --- | --- | --- |
| List (`safeTransferFrom` deposit) | 156,605 | about 182,000 |
| `buy` with ETH | 214,067 | about 240,000 |
| `createBid` with ETH | 108,215 to 125,311 | about 135,000 |
| Sell into a bid | 216,792 | about 245,000 |
| `matchBid` | 232,125 | about 263,000 |
| `fillOffer`, real OpenSea item offer | 435,583 | about 482,000 |
| `cancelListing` | 58,846 | about 82,000 |
| `withdrawListing` | 102,033 | about 125,000 |
| `withdrawBid` | 65,240 | about 90,000 |

Whole-transaction figures add the base and an estimate of calldata; the keeper end-to-end run records receipts. `fillOffer` includes three first-time WETH balances (seller, executor, protocol); recurring recipients cost about 40,000 less. OpenSea's own accept-offer for the same offer used 263,662.

Listing now costs a deposit transaction (about 182,000 gas, about 0.00007 ETH at 0.4 gwei). The old design listed by signature only.

## Keeper profitability

Profit = executor fee (0.30% of the sale price) minus gas, before API and hosting cost.

**`fillOffer`, about 482,000 gas:**

| Sale price (WETH) | Executor fee | Protocol fee | 0.4 gwei | 1 gwei | 3 gwei | 10 gwei | 30 gwei |
|---|---|---|---|---|---|---|---|
| 0.05 | 0.00015 | 0.00010 | -0.00004 | -0.00033 | -0.00130 | -0.00467 | -0.01431 |
| 0.1 | 0.00030 | 0.00020 | +0.00011 | -0.00018 | -0.00115 | -0.00452 | -0.01416 |
| 0.5 | 0.00150 | 0.00100 | +0.00131 | +0.00102 | +0.00005 | -0.00332 | -0.01296 |
| 1 | 0.00300 | 0.00200 | +0.00281 | +0.00252 | +0.00155 | -0.00182 | -0.01146 |
| 5 | 0.01500 | 0.01000 | +0.01481 | +0.01452 | +0.01355 | +0.01018 | +0.00054 |
| 10 | 0.03000 | 0.02000 | +0.02981 | +0.02952 | +0.02855 | +0.02518 | +0.01554 |

**Minimum viable sale price** (keeper default margin 1.25x gas):

| Base fee | `fillOffer` break-even | with margin | `matchBid` break-even | with margin |
| --- | --- | --- | --- | --- |
| 0.4 gwei | 0.064 | 0.080 | 0.035 | 0.044 |
| 1 gwei | 0.161 | 0.201 | 0.088 | 0.110 |
| 3 gwei | 0.482 | 0.603 | 0.263 | 0.329 |
| 10 gwei | 1.607 | 2.008 | 0.877 | 1.096 |
| 30 gwei | 4.820 | 6.025 | 2.630 | 3.288 |

The keeper computes this per candidate from the live base fee and skips anything below it. Below the threshold a listing still sells by direct buy or a bid sell, which cost the executor nothing.

## How often matching adds a fill

OpenSea carried about 99% of Ethereum ERC721 bid fills over 24 hours: 4,075 fills, 214.1 WETH, 331 at or above 0.064 WETH (`PHASE0_EVIDENCE.md`). At 0.4 gwei the `fillOffer` threshold (0.08 WETH with margin) admits a few hundred offers a day across all collections. Market's own bids add a second source that is cheaper to fill. There is no evidence yet of Market bid demand.

## Seller outcome versus alternatives

- **Accepting the offer yourself on OpenSea:** you get the released amount and pay about 264k gas. Through Market you pay the deposit (about 182k gas) and 0.5% of the sale price, and need not watch. If you would accept today's best offer anyway, accept it directly.
- **Fixed price:** sells only at that price. A falling price trades time for price discovery; it does not maximize proceeds.
- **Surplus:** a falling ask usually crosses an existing offer and fills just after, so surplus is small. `matchBid` gives the seller the whole gap to the bid; arbitrage through `buy` plus an outside resale can take it first (D025).

## Fee decision (D033)

Keep 0.30% executor and 0.20% protocol, with a 0.10% referral share out of the protocol fee. At today's gas, OpenSea fills are viable from about 0.08 WETH and Market bid matches from about 0.044 WETH. Revisit if typical base fee rises above about 3 gwei.

## Operating cost

- OpenSea API key: free tier, rate limited. Required for offer discovery and zone signatures.
- RPC: public endpoint works for development; a paid RPC is advisable for the keeper.
- Hosting: one small Node host for web and keeper with a local SQLite file.
- Keeper wallet: holds only ETH for gas.
