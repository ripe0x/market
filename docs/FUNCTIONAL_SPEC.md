# Functional specification: Market

Status: revised 2026-10-30 for the owner's escrow and open-protocol decisions (D023 to D035). Implementation state: `STATUS.md`.

## 1. Purpose

Market is an open onchain exchange for Ethereum ERC721 tokens. **The contracts are the product; our web app is one interface.** Every operation is permissionless and callable by wallets, contracts, agents and other frontends.

A holder lists an NFT with a price that can be fixed, rise or fall over time, and walks away. It sells to a direct buyer, to a Market bid, or to a compatible OpenSea offer, whichever first meets the seller's minimum. A buyer can run a bid that acquires one token, any token in a range, or any token in a collection, within a budget.

Market guarantees authorized execution, not best execution or a sale.

## 2. Roles

| Role | Does |
| --- | --- |
| Seller | Deposits an NFT with listing terms; updates, cancels, withdraws; sells into a bid |
| Buyer | Buys a listing; creates, cancels and withdraws bids |
| Executor (anyone) | Runs `matchBid` and `fillOffer`; earns the executor fee |
| Referrer | Named by an interface on `buy` or a sell into a bid; earns part of the protocol fee |
| Collection | Optionally receives sale notifications; may set ERC-2981 royalty |
| Owner | Enables currencies and OpenSea zones. No access to assets |

## 3. Flows

### 3.1 List

1. Seller calls `nft.safeTransferFrom(seller, market, tokenId, 0x00 ‖ abi.encode(Listing))`. One transaction; no approval. Only the owner itself may make this transfer.
2. Terms: currency, proceeds recipient, `floor`, expiry, price (built-in or external strategy). Seller, NFT and token id come from the transfer.
3. Market stores a hash of the terms and emits `Listed` with the full terms.
4. The seller may `updateListing` (new terms, same NFT), `cancelListing` (stops fills; NFT stays), or `withdrawListing` (NFT to any address). Cancel needs no transfer, so a failing NFT cannot leave a listing fillable.

### 3.2 Buy

`quoteBuy` gives the price and split. `buy(listing, id, maxPrice, recipient, referrer)` pays with ETH (WETH listings) or the currency. The NFT goes to `recipient`; the seller gets at least the ask. Excess ETH returns as WETH.

### 3.3 Bid (acquisition program)

`createBid` deposits the whole budget. Terms: collection, `[minTokenId, maxTokenId]`, currency, budget, `maxPrice` per NFT, quantity, recipient, expiry, price. A bid fills:

- when a holder calls `safeTransferFrom(holder, market, tokenId, 0x01 ‖ abi.encode(Bid, bidId, minProceeds, referrer))`, or
- when anyone calls `matchBid(listing, listingId, bid, bidId)` for an eligible escrowed listing. The sale is at the bid's price, so the seller keeps the surplus over the ask.

Budget, quantity and per-NFT bounds hold under any interleaving of fills. `cancelBid` stops fills; `withdrawBid` returns the unspent budget.

### 3.4 OpenSea offer

The keeper finds the best OpenSea offer for an escrowed listing, asks OpenSea to sign zone data for Market as fulfiller (OpenSea signs only for the NFT's owner), and calls `fillOffer(listing, id, offer, resolvers)`. Market fills the offer through `Seaport.fulfillAdvancedOrder`. The offer's consideration pays OpenSea's fee and any creator fee; Market adds none. The seller gets everything released minus Market's fees, and at least the ask.

Accepted: offers in an enabled zone (OpenSea SignedZone), one ERC20 offer item in the listing's currency, consideration that Market can pay from what the offer releases. OpenSea returns either a `fulfillAdvancedOrder` or a `matchAdvancedOrders` shape; the keeper converts both (D034).

## 4. Pricing (D030)

- Built-in: linear from `start` at `startTime` to `end` at `endTime`, holding `start` before and `end` after. Fixed when `start == end`. Rounds up for a listing, down for a bid.
- External: `IPricingStrategy.price(orderId, isBid, nft, tokenId, fills, data)`, read-only, 100k gas. Anyone may write one. `fills` lets a bid price change after each acquisition.
- Bounds, independent of the strategy: a listing's ask is never below `floor`. A bid pays at most `maxPrice` and the unspent budget. A failing strategy blocks fills only.
- Interfaces must label external strategies as unaudited third-party code and show the bounds as the guarantee.

## 5. Economics (D024, D025, D033)

- Sale price = what the buyer pays. Royalty, protocol fee and executor fee come out of it; the rest is the seller's proceeds.
- Ask = seller's minimum proceeds. Bid price = buyer's maximum payment.
- Protocol fee 0.20% of the sale price, every sale. Executor fee 0.30% on `matchBid` and `fillOffer`. Referral 0.10% paid out of the protocol fee.
- Royalty: ERC-2981 at the sale price on native sales (D032). None added on OpenSea fills.
- Every split is visible before execution through the quote functions and in the `Sale` event.

## 6. Currencies (D031)

WETH always. Other ERC20s once the owner enables them, including artist and collection tokens. Fee-on-transfer tokens are rejected at deposit; rebasing tokens must not be enabled. Disabling stops new orders and fills; withdrawals continue.

## 7. Collection callbacks (D028)

A collection that reports `ISaleObserver` through ERC-165 receives `onMarketSale(tokenId, seller, buyer, currency, price)` after each sale, with 100k gas and no value. It cannot reenter Market. A failure is ignored. Callbacks never carry settlement-critical state.

## 8. Security properties

1. An NFT leaves Market only to a sale's buyer or to its seller's chosen address on withdrawal.
2. Market's balance in each currency covers every open bid's unspent budget; a call that would break this reverts.
3. A seller receives at least the ask; a buyer pays at most its bound; bids never exceed budget, quantity or `maxPrice`.
4. Cancellation and withdrawal depend on no strategy, callback, OpenSea or owner.
5. One reentrancy lock covers every state-changing entry point, including the deposit hook.
6. Market approves Seaport only for the listed token and the exact currency amount, inside `fillOffer`.
7. No administrator can move escrowed assets, change fees or alter orders.

Known risks: `SECURITY.md`.

## 9. Infrastructure

- Foundry contracts and tests; pinned mainnet fork tests for real OpenSea offers.
- One Next.js app and one keeper process sharing a SQLite file (D009). The chain is the source of truth: the app indexes `Listed`, `ListingUpdated`, `BidCreated`, `Cancelled`, `Withdrawn` and `Sale` events.
- The keeper matches listings with Market bids and with OpenSea offers when the fee covers gas. It is optional: anyone can run the same calls.
- OpenSea API key needed for offer discovery and zone signatures (D021).

## 10. Acceptance

1. A seller lists in one transaction, sees the ask over time, cancels and withdraws without our service.
2. A buyer buys through the app and directly through the contract.
3. A holder sells into a bid; a listing matches a bid; bounds hold under fuzzing and invariants.
4. Real OpenSea offers fill from escrow on a pinned fork with exact splits.
5. The app and keeper run end to end on a local fork.
6. Independent review findings resolved; gas and economic bounds recorded; no claim of audit or launch.

## 11. Exclusions

ERC1155, trait (merkle) bids, buying OpenSea listings for a bid, Blur, cross-chain, a token, governance, upgradeability, and guarantees of execution.
