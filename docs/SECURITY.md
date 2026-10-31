# Security

**Not audited.** Passing tests and an internal review do not make this safe. Market holds users' NFTs and bid budgets, so a qualified independent audit is required before any deployment that holds value.

## Permissions

| Actor | Can | Cannot |
| --- | --- | --- |
| Seller | Deposit an NFT with terms (only as the owner itself); update terms; cancel; withdraw to any address | Be paid less than the ask on any fill |
| Buyer | `buy` at the quoted price within `maxPrice`; create, cancel and withdraw bids | Pay more than `maxPrice`, or more than a bid's `maxPrice`, budget or quantity |
| Holder | Sell into a bid with a `minProceeds` bound | Be paid without delivering an eligible NFT |
| Executor (anyone) | `matchBid`, `fillOffer`; earns 0.30% | Keep surplus; spend other users' escrow; move any NFT but the listed one |
| Owner | Enable currencies and OpenSea zones; transfer the role | Move assets, change fees or orders, pause, upgrade, block withdrawals |
| Strategy contract | Return a price (read-only, 100k gas) | Move the price outside the order's bounds; block withdrawals |
| Collection | Set ERC-2981 royalty; receive `onMarketSale` (100k gas, no value) | Reenter Market; undo a sale |
| Keeper service | Submit fills; index events | Affect settlement rules; a dead keeper blocks nothing |

Approvals: users give Market no NFT approvals. ERC20 currencies need an allowance to Market for `buy` or `createBid` unless paying ETH. Market approves Seaport only inside `fillOffer`: the one listed token and the exact currency consideration, reset afterwards.

## Properties and how they are checked

| Property | Mechanism | Tests |
| --- | --- | --- |
| Escrow solvency: Market's balance equals the unspent budgets of open bids | Full budget deposited at creation; delta-checked deposits; balance check on `fillOffer` | `invariant_escrowEqualsOpenBudgets`, `test_revertWhenOfferWouldSpendEscrow`, `test_rejectFeeOnTransferToken` |
| Custody: an escrowed NFT has exactly one open listing, and leaves only to a buyer or the seller's withdrawal address | Hash per order; delete before external calls; token-level Seaport approval; delivery check | `invariant_custodyMatchesListings`, `test_revertWhenOfferAsksForAnotherNft` |
| Seller gets at least the ask | Checked after royalty and fees on every path | `test_listEscrowsAndBuyPaysEveryone`, `test_matchRevertsBelowAsk`, `test_revertWhenAskAboveProceeds`, handler asserts |
| Buyer pays at most its bound | `maxPrice` on `buy`; bid price clamped to `maxPrice` and unspent budget | `test_buyRespectsMaxPrice`, `test_budgetAndQuantityBound`, handler asserts |
| Bids never exceed budget, quantity or `maxPrice` under any interleaving | `spent` and `fills` update in the fill, under one lock | `test_quantityBound`, `test_bidStrategyUsesFills`, invariant handler |
| Gross-up is exact enough | Iterated to cover the ask; within 4 wei of exact | `testFuzz_buyQuoteIsNearMinimal` (2,000 runs), `test_nonProportionalRoyaltyStillCoversAsk` |
| Built-in price monotone and rounds toward the owner | Linear interpolation, up for asks, down for bids | `testFuzz_linearAsk` |
| Strategy output bounded; failing strategy blocks only fills | Clamp; `staticcall` with gas limit | `test_externalStrategyIsClampedToFloor` |
| Cancel is independent of transfers | `cancelListing` changes state only | `test_cancelWithdrawAndFailedTransfer` |
| Disabled currency keeps withdrawals | Fills check the allowlist; withdrawals do not | `test_disabledCurrencyStopsFillsNotWithdrawals` |
| Owner cannot touch assets | Only `setCurrency`, `setZone`, `setOwner` exist | `test_onlyOwnerConfigures`, `test_onlyOwnerSetsZones` |
| Deposits only by the owner, with real delivery | `operator == from`; `ownerOf` check | `test_rejectsBadDeposits`, `test_fakeDeliveryIsRejected` |
| Callbacks cannot undo a sale or be starved | ERC-165 opt-in; fixed gas; result ignored; gas floor | `test_failingObserversCannotUndoSale`, `test_executorCannotStarveObserver` |
| Reentrancy | Transient lock on every state-changing entry point, including the deposit hook | `test_failingObserversCannotUndoSale` (reentrant observer) |
| Real OpenSea offers settle exactly from escrow | `fulfillAdvancedOrder` with Market as fulfiller | `test_fillRealOffer` (both fixtures) |
| Replay and expiry | Order hash deleted on fill; expiry checked; OpenSea zone signature expiry | `test_fillRealOffer` replay, `test_revertWhenZoneSignatureExpired` |
| Only enabled zones | Zone allowlist | `test_revertWhenZoneDisabled` |

## Known risks

1. **Custody.** Market holds NFTs and bid budgets. A contract bug could lose them. There is no pause and no admin rescue by design; a fix needs a new deployment, and users must withdraw from the old one.
2. **OpenSea may refuse Market's address** ("Account can not perform trading operations"). 2 of 48 contracts were refused in research. Only a mainnet canary can prove it. If refused, Market still works for direct buys and Market bids.
3. **OpenSea dependency.** Offer discovery and zone signatures depend on OpenSea's API, rate limits and policies. A new OpenSea zone needs the owner to enable it.
4. **Executor fee front-running.** `fillOffer` and `matchBid` calldata works for any caller; the seller is unaffected, the keeper loses its fee. The keeper requires a private submission endpoint off a local fork.
5. **Arbitrage takes surplus** (D025): anyone can buy at the ask and resell higher.
6. **Royalty choices** (D032): ERC-2981 only on native sales; OpenSea fills pay what OpenSea's offer pays. A collection can make its tokens unsellable on Market by setting a royalty above the price.
7. **Stray assets.** An NFT sent with plain `transferFrom`, or tokens sent directly, have no order and cannot be withdrawn by anyone.
8. **Currency risk.** An enabled token that later changes behavior (rebasing, fees, pausing, blocklists) can block fills or withdrawals in that token. A blocklisted royalty receiver or protocol recipient blocks sales in that token.
9. **ERC721 variants.** Tokens without `safeTransferFrom` hooks cannot be listed. Operator-restricted collections (ERC721-C) are untested; their validators may block Market or Seaport.
10. **External strategies** are third-party code and may be mutable. Bounds are the only guarantee.
11. **Wash trades.** Anyone can sell to themselves at any price; `onMarketSale` observers must not treat Market sale prices as trustworthy market data.
12. **Metadata is untrusted.** Only http(s)/ipfs image URLs pass; names are trimmed text rendered as text.
13. **Collection contracts are trusted for delivery.** A bid on a hostile or non-standard ERC721 can pay for an NFT that never moves.

## Review findings

Independent AI review of `contracts/Market.sol` at `606cc05` (not a human audit). Reviewer tests: `test/review/Review.t.sol`, 5/5 pass. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Low | `cancelListing` reverted when the owner had disabled the listing's currency, so cancelling depended on the owner (withdrawal still worked) | Fixed: `cancelListing` checks only the order and seller. `test_cancelListingIgnoresDisabledCurrency` |
| 2 | Low | Any buyer or seller can name itself as referrer and take the 0.10% referral, so the effective protocol fee is 0.10% for anyone who does | Accepted and documented (D033). A check against the caller is bypassed by a second address. Owner review |
| 3 | Info | A listing with floor 0 and price 0 sells for nothing; a bid with maxPrice 0 buys for nothing | The owner's own terms. The app warns before a zero floor |
| 4 | Info | A hostile NFT contract can fake delivery and collect a bid's payment | Inherent to any marketplace: bids trust the collection contract. Known risk 13 |
| 5 | Info | Starving the royalty call to evade royalty | Not exploitable: the rest of the sale needs more gas than the 1/64 left |

Not covered by the reviewer: rerunning fork tests, `fillOffer` inside the invariant handler, non-WETH currencies beyond mocks, OpenSea zone paths beyond the two fixtures.
