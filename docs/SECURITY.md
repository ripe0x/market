# Security

**Not audited.** Passing tests and an internal review do not make this safe. A qualified independent audit is required before any deployment that holds value.

## Permissions

| Actor | Can | Cannot |
| --- | --- | --- |
| Seller | Sign a listing; cancel it with `Seaport.cancel` or `incrementCounter`; revoke the conduit approval | Be paid less than the current price |
| Buyer | `Market.buy` at the current price plus 0.2% | Buy below the current price; buy a cancelled, expired, filled or unapproved listing |
| Executor (anyone) | `Market.matchOffer` with any WETH offer that covers the price plus fees; earns 0.3% | Keep surplus; leave the NFT or WETH in Market; fill without the seller's signature |
| Protocol | Receives 0.2% at a fixed address | Change fees, pause, upgrade, move user assets, alter a signed listing |
| Market contract | Call Seaport as fulfiller inside `buy` and `matchOffer` | Act outside those calls: it signs nothing, implements no ERC-1271 or zone hook, and holds no user approvals |
| Keeper service | Submit matches; record sales | Affect settlement rules; a dead keeper blocks nothing |

Approvals: sellers approve the OpenSea conduit (`setApprovalForAll`). That approval is shared with OpenSea listings and survives cancellation. Market's only approval is its own WETH allowance to Seaport, set in the constructor.

## Properties and how they are checked

| Property | Mechanism | Tests |
| --- | --- | --- |
| Only Market fills its listings | Seaport calls the zone unless the caller is the zone; Market has no zone hook | `test_listingOnlyFillableThroughMarket` |
| Seller gets at least the current price | Seaport consideration item to the seller | `test_revertWhenOfferBelowMinimumPlusFees`, fuzz `testFuzz_priceMatchesSeaport` |
| Seller gets all surplus minus 0.5% | Unspent offer WETH goes to Market; split in the same call; checked subtraction reverts if fees exceed surplus | `test_matchRealOffer` (both real offers), `test_syntheticMatchSplitsSurplus` |
| Price never increases, equals Seaport to the wei | Same AmountDeriver formula, rounding up | `testFuzz_priceNeverIncreases`, `testFuzz_priceMatchesSeaport` |
| One fill per listing; replay fails | Seaport order status | `test_revertOnSecondBuy`, `test_revertOnReplayEvenIfSellerReacquires`, replay in `test_matchRealOffer` |
| Cancel is binding without our service | Seaport `cancel`, `incrementCounter` | `test_revertWhenCancelled`, `test_revertWhenCounterIncremented`, UI cancel on fork |
| Atomic; nothing left in Market | Single Seaport call; NFT-left check; WETH swept; overpayment returned as WETH | `test_revertWhenNftLeftInMarket`, balance assertions in all fills |
| Only WETH offers | Offer shape check | `test_revertWhenOfferNotWeth` |
| Reentrancy | Transient lock on both entry points; Seaport's own guard | `test_reentryDuringSettlementReverts` |
| Signature binding | Seaport EIP-712 over all terms, chain id and Seaport address; zone address binds fee terms | `test_revertWhenSignatureWrong`, `test_revertWhenFulfillerDiffers` |
| Ownership and approval changes stop fills | Conduit transfer fails | `test_revertWhenSellerNoLongerOwns`, `test_revertWhenSellerRevokedApproval` |
| Offer-side failures revert both legs | Single Seaport match | `test_revertWhenBidderLacksWeth`, `test_revertWhenZoneSignatureExpired` |
| API stores only valid, owned, signed listings | Signature (EOA or ERC-1271), counter, ownership, shape checks | `npm run e2e:keeper`: bad signature, non-owner, wrong zone, stale counter rejected; valid stored |

## Known risks

1. **Surplus can be taken by arbitrage.** Anyone may buy at the current price and sell into a higher offer themselves. This is inherent to a public declining price.
2. **Executor fee can be front-run.** A keeper transaction's calldata works for any caller (the zone signature names Market, not the keeper). The seller is unaffected; the keeper loses its fee. The keeper refuses to match on mainnet without `SUBMIT_RPC_URL` (a private relay).
3. **Old listings revive if the seller reacquires the NFT** before the listing ends and the conduit approval is still on. Cancel to prevent.
4. **OpenSea dependency.** Live matching depends on OpenSea issuing zone signatures for Market as fulfiller (unverified, needs API key) and on its API's availability and rate limits.
5. **Stray WETH sent to Market** is paid to the next matched seller. Nothing else can withdraw it.
6. **Operator-restricted (ERC721-C) collections** are untested.
7. **No pause.** A bug fix needs a new deployment, and sellers must cancel old listings.
8. **Metadata is untrusted.** Only http(s)/ipfs image URLs pass; names are trimmed text rendered as text.

## Review findings

Independent AI review of commit `2018970` (not a human audit), scope: `Market.sol`, listing intake API, keeper. Reviewer tests: `test/review/Review.t.sol` (4/4 pass).

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Medium | Keeper submitted to the public mempool when `SUBMIT_RPC_URL` was unset, so its executor fee could be front-run | Fixed: off a local fork, matching stays off without a private submission endpoint |
| 2 | Low | Stray WETH sent to Market is paid to the next matched seller; the contract comment claimed Market never holds WETH | Accepted and documented (risk 5). Not profitable to anyone but the seller; comment corrected |
| 3 | Low | Stuck-tx replacement could be underpriced after a base fee drop, stalling the keeper | Fixed: replacement fees are at least 115% of the last send (`replacementFees`, unit tested) |
| 4 | Info | A searcher can buy at the current price and resell into a higher offer | By design (D013); risk 1 |
| 5 | Info | Attacker-supplied consideration, resolvers and fulfillments cannot skim surplus | Confirmed by `test_cannotRouteSurplusToExecutorViaFulfillments`, `test_extraFulfillmentCannotSkimSurplus` |

No critical or high findings. Not tested by the reviewer: live OpenSea API paths, real partial-fill collection offers, mempool behavior.
