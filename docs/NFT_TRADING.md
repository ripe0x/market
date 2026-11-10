# NFT trading handlers

`NFTSale` and `NFTBid` are the reference handlers for trading ERC721s for native ETH on Market. They are ordinary handlers: no core change, no registry, no fee. Any number of orders can use one deployment of each, each with its own configuration.

> **Status: experimental, unaudited.** Tested with unit, fuzz, invariant and mainnet fork tests (see [STATUS.md](STATUS.md)). That is evidence about tested behaviour, not a safety claim.

| Contract | Role |
| --- | --- |
| [`handlers/NFTTrade.sol`](../handlers/NFTTrade.sol) | Shared base: fill authentication, price schedule, ERC2981 royalty lookup, delivery check |
| [`handlers/NFTSale.sol`](../handlers/NFTSale.sol) | A listing. The order escrows one ERC721 and sells it for ETH |
| [`handlers/NFTBid.sol`](../handlers/NFTBid.sol) | A funded bid. The order escrows ETH and buys one token, or up to `maxFills` tokens of a collection |
| [`handlers/HandlerBase.sol`](../handlers/HandlerBase.sol) | Helpers every handler here uses: `_exec`, `_sendETH`, `_close` |

## Money terms

The same in both handlers:

1. **`price`** is everything the buyer spends. Nothing is added on top.
2. **`royalty`** is what the collection's ERC2981 `royaltyInfo(tokenId, price)` asks, paid out of `price` to the collection's receiver in the same transaction.
3. **`proceeds = price - royalty`** go to the seller.

Royalty rules:

1. A collection that reports ERC2981 through ERC165 (`supportsInterface(0x2a55205a)`) is always paid. A collection that does not report it pays nothing, even if it has a `royaltyInfo` function.
2. A royalty is never skipped. The fill reverts if `royaltyInfo` reverts, asks more than `price`, asks a nonzero amount with no receiver, or the receiver refuses the ETH.
3. A sale's seller caps the royalty share with `maxRoyaltyBps`; above it the sale reverts rather than pay the seller less than agreed. A bid's seller is protected by `minProceeds`, which is net of royalty.

There are no other fees. Applications that want a fee or a split can write their own handler, or pay `proceedsTo` into a splitter.

## Price schedule

```solidity
struct Schedule {
    uint256 startPrice;
    uint256 endPrice;
    uint256 startTime;
    uint256 endTime;
    uint256 expiry; // 0: never
}
```

The price moves linearly from `startPrice` at `startTime` to `endPrice` at `endTime`, then stays at `endPrice`. Fills revert before `startTime` (`NotStarted`) and from `expiry` on (`Expired`).

| Shape | Schedule |
| --- | --- |
| Fixed price | `startPrice == endPrice` |
| Falling (Dutch) listing | `endPrice < startPrice` |
| Rising bid | `endPrice > startPrice` |
| Price that steps once at a time `T` | `startTime == endTime == T`: `startPrice` before (if fills are allowed then), `endPrice` from `T` |

Rounding: the movement between the end points rounds down, so the price is never further from `startPrice` than the exact line. A falling price rounds up (for the seller), a rising one down (for the bidder). `priceAt(schedule, t)` is a public view on both handlers.

## NFTSale

**Config** (`abi.encode(NFTSale.Config)`):

| Field | Meaning |
| --- | --- |
| `nft`, `tokenId` | The token for sale |
| `schedule` | Price schedule and fill window |
| `proceedsTo` | Receives `price - royalty`. Must not be zero |
| `maxRoyaltyBps` | Highest royalty share the seller accepts, in basis points of `price` |

**Input** (`abi.encode(address recipient, uint256 maxPrice)`): `recipient` receives the token; the fill reverts if the current price is above `maxPrice`. Send at least the price as ETH; the excess returns to the caller.

**Fill**, in order: refuse unless called by a genuine order bound to this handler during its fill (`NotAFill`), check config and window, compute price and royalty, check `maxPrice` and payment, close the order, transfer the token with `transferFrom` and check `ownerOf(tokenId) == recipient`, pay the royalty, pay `proceedsTo`, refund the caller. Returns `abi.encode(price, royalty)`. Emits `Sold(order, buyer, recipient, price, royalty)`.

**Lifecycle:**

1. Seller: `market.create(nftSale, config, salt)`, then `nft.transferFrom(seller, order, tokenId)`. Or transfer to `market.orderAddress(seller, nftSale, keccak256(config), salt)` first and create after; the address has no code until then, so `safeTransferFrom` makes no callback.
2. Buyer: `sale.quote(config)` for `(price, royaltyTo, royalty)`, then `order.fill{value: price}(config, abi.encode(recipient, price))`.
3. Cancel: `order.close()`, then `order.execute(nft, 0, transferFrom(order, seller, tokenId))`. Stray ETH: `order.execute(seller, amount, "")`.

The order holds no approvals, so nothing remains to revoke after a sale or cancellation.

## NFTBid

**Config** (`abi.encode(NFTBid.Config)`):

| Field | Meaning |
| --- | --- |
| `nft` | The collection |
| `anyToken`, `tokenId` | `anyToken`: any token of `nft`. Otherwise only `tokenId` |
| `schedule` | Price schedule and fill window. The bid pays exactly the current price |
| `recipient` | Receives every token bought |
| `maxFills` | Tokens to buy before the order closes itself. 0 or 1: one |

**Funding.** The bid pays from its order's ETH: send it with `create`, or send ETH to the order at any time (anyone may top up). A fill reverts `InsufficientFunds` while the balance is below the current price. The owner cannot withdraw from an active bid; closing returns everything.

**Seller's approval goes to the handler, not the order.** The holder calls `nft.approve(nftBid, tokenId)` or `nft.setApprovalForAll(nftBid, true)`. See "Why the bid handler holds the approval" below.

**Input** (`abi.encode(uint256 tokenId, uint256 minProceeds, address proceedsTo)`): the token to sell, the least `price - royalty` the seller accepts, and where to send it (not zero).

**Fill**, in order: refuse unless called by a genuine order bound to this handler during its fill, refuse ETH, check token eligibility, window and funds, compute price and royalty, check `minProceeds`, count the fill and close if it is the last, move the token from the caller to `recipient` and check `ownerOf`, pay the royalty, pay `proceedsTo`. Returns `abi.encode(price, royalty)`. Emits `Bought(order, seller, tokenId, price, royalty)`. `fills(order)` counts tokens bought.

**Lifecycle:**

1. Bidder: `market.create{value: funds}(nftBid, config, salt)`.
2. Holder: approve the handler once; `bids.quote(order, config, tokenId)` for `(price, royaltyTo, royalty)`; `order.fill(config, abi.encode(tokenId, price - royalty, me))`.
3. Cancel: `order.close()`, then `order.execute(bidder, address(order).balance, "")`.

### Both handlers act only inside a genuine fill

Anyone can call a handler's `onFill` directly, posing as an order with any `caller`, `value` and `config`, and the owner of a closed order can make the order call it outside a fill. Both handlers therefore start with `_requireFill`, which accepts only these at once:

1. `msg.sender`'s code is the 149-byte ERC-1167 clone of Market's `Order` implementation, so it runs `Order` and reports the true caller of `fill` and the ETH sent.
2. That order's handler is this contract.
3. That order is filling.

For `NFTBid` this protects the approvals it holds. For `NFTSale` it protects the meaning of `Sold`: before the check, a counterfeit order could make the real handler announce a 1,000 ETH sale of a real token with no ETH paid and no royalty (finding S1, `test/review/SaleEventPoC.t.sol`). Indexers should still read events only from the handler addresses they trust, and treat each event as describing one fill of the order named in it. A genuine `Sold` means the price was really paid and split as stated; it does not mean the parties are independent (a seller can buy its own listing) or that the collection is the one you expect (read `nft` from the order's config). A clone of the implementation deployed without Market still runs `Order`'s code and is accepted (`test_cloneOutsideMarketIsStillAnHonestOrder`); its terms are whatever its deployer appended.

### Why the bid handler holds the approval

An order's owner can close it at any moment and then make any call as the order. An approval to a bid's order is therefore an approval to the bidder: the bidder can watch for a holder's `approve(order, id)`, close the order and call `transferFrom(holder, bidder, id)` through it before the holder's fill lands (finding A1, `test_approvalToAnOrderBelongsToItsOwner`). This applies to any handler that pulls a filler's assets under an approval to the order.

`NFTBid` instead takes the approval itself. It has no owner and fixed code, and moves a token only inside a genuine fill (above), from `caller`, the account that called `fill`, to the order's `recipient`, for the order's current price. So a token moves only when its holder fills a bid themself. A direct call, a fake order, a genuine order bound to another handler, and a closed order's owner are all refused (`test_bidderCannotStealApprovedTokens`, `test_otherOrdersCannotUseTheHandlersApproval`, the invariant campaign's theft attempts). A clone of the implementation deployed without Market still runs `Order`'s code and is as safe to accept (`test_cloneOutsideMarketIsStillAnHonestOrder`).

### What an approval to NFTBid authorizes

The approval is held by the one `NFTBid` deployment and shared by every bid on it, from every bidder. Unlike authority held by an order, it is not isolated per order. Precisely, it lets `NFTBid` move a token of yours only in a genuine fill of an `NFTBid` order in which **your account is the caller of `fill`**: the token id your fill names, to that order's `recipient`, for that order's current price, with at least your `minProceeds` (net of royalty) sent to the `proceedsTo` your fill names.

What follows:

1. **Whoever can make your account call `fill` can sell your approved tokens**, into any bid, at any price, with proceeds anywhere. That includes your key, a phishing interface you sign for (one token per signed fill, review N2), a smart-wallet module or session key, an EIP-7702 delegate, and any contract holder that lets others trigger arbitrary calls. A router or other intermediary cannot: when it calls `fill`, it is the caller, so only its own tokens move (`test_phishingRouterCannotSweepApprovedTokens`).
2. **A defect in `NFTBid` exposes every token approved to it**, across all holders and collections. This is the usual cost of an operator approval and the main reason the handler is small, ownerless and pinned by code hash.
3. **Approvals outlive the fill.** `setApprovalForAll` also covers tokens you acquire later. Approve one token when you can, approve and fill in one batch if your wallet allows, and revoke when done.

## Security assumptions

1. **The collection is honest.** Delivery is checked with `ownerOf` before and after the transfer; a collection that lies in `ownerOf` can fake delivery. Buyers and bidders choose the collection and must trust it.
2. **Royalty receivers can block fills.** A receiver that reverts or runs out of gas makes every fill of that collection revert until the collection changes it. This is deliberate: a royalty is never skipped.
3. **`proceedsTo`, `recipient` and refunds are pushed.** A sale whose `proceedsTo` rejects ETH cannot fill; the seller recovers by closing. A buyer whose account rejects the refund makes only its own fill revert.
4. **No callbacks to recipients.** Tokens move with `transferFrom`. A contract recipient that cannot handle ERC721s will hold the token anyway; the account choosing `recipient` is responsible.
5. **Reentrancy.** Each handler closes or counts before any external call. A royalty receiver, refund recipient or collection that calls back can fill other orders (nested fills stay available) but cannot refill the same order (`Order` refuses with `Reentrant`, then `OrderClosed`). Neither handler keeps state that one order's fill could corrupt for another.
6. **Stale quotes.** Prices move with time and royalties can change between a quote and inclusion. `maxPrice` (sales) and `minProceeds` (bids) bound what the filler accepts.
7. **Collection bids pay for any token.** Sellers will offer the least valuable eligible token. Use `anyToken = false` or another handler for narrower criteria.
8. **MEV.** Fills are first come, first served. A falling listing or rising bid that crosses another venue's price will be taken by whoever sees it first.
9. **Market binding.** Both handlers recognize orders of the Market they were deployed with. Deploy one of each per Market.

## Compatibility

Tested on a mainnet fork pinned at block 26,357,000 (`test/fork/NFTFork.t.sol`), holders impersonated, every contract the deployed one:

| Collection | Implementation | Royalty | Result |
| --- | --- | --- | --- |
| BAYC | OpenZeppelin ERC721 | none (no ERC2981) | Sale and bid settle |
| Azuki | ERC721A | none | Sale and bid settle |
| Moonbirds #1 | ERC721 with nesting, held by a contract | 1% to an EOA | Sale settles |
| Moonbirds #7, nested | Nesting blocks transfers | | Incompatible while nested: bid fill reverts, funds untouched |
| Opepen | Manifold creator core | 2.5% to an EOA | Sale and bid settle; the bid's seller is an EIP-7702 account |
| Chimpers | ERC721 | 5.5% to a splitter contract that forwards on receipt | Sale and bid settle; a seller limit of 5% makes the sale revert |
| ENS .eth names | BaseRegistrar | none | Sale settles; the buyer must `reclaim` to control records, as after any ENS transfer |
| CryptoPunks | Not ERC721 | | Incompatible: bid fill reverts, funds untouched. Use a wrapper collection |

Also tested: a royalty receiver given code that reverts (sale reverts, token stays escrowed); cancellation and recovery of a real listing and bid.

Not covered: ERC1155, ERC20 payment, criteria other than one token or a whole collection, non-ERC721 tokens.

## Gas

Whole-transaction gas, isolated runs on the fork (`forge test --match-path test/fork/NFTFork.t.sol --isolate`, `snapshots/NFTFork.json`). Includes 21,000 base, calldata and first-time account creation for new recipients (up to 25,000 per new account).

| Operation | Gas |
| --- | --- |
| Create a listing | 95,227 |
| Deposit the token into the listing | 67,026 (Azuki) to 110,187 (BAYC) |
| Create a funded bid | 95,618 |
| Sale fill, no royalty | 165,277 (Azuki) to 219,670 (BAYC) |
| Sale fill with royalty | 185,595 (Moonbirds 1%) to 212,366 (Chimpers 5.5%, splitter) |
| Bid fill, no royalty | 132,592 (Azuki) to 187,306 (BAYC) |
| Bid fill with royalty | 165,447 (Opepen 2.5%) to 174,491 (Chimpers) |
| Close | 47,129 |
| Recover the NFT from a closed sale | 54,705 |
| Recover the ETH from a closed bid | 34,685 |

### Against Seaport

Seaport 1.6 fills of single orders sent directly to Seaport in mainnet blocks 26,356,800 to 26,357,000 (receipts in `snapshots/seaport-receipts-26356800-26357000.txt`):

| Seaport call | Receipts | Gas |
| --- | --- | --- |
| `fulfillBasicOrder_efficient_6GL6yc` | 4 | 111,622 to 159,238 |
| `fulfillAdvancedOrder` | 17 | 137,011 to 273,243, median 208,695 |

What the numbers mean:

1. **Fills cost about the same.** Market fills sit inside Seaport's single-order range: a bit above its most efficient basic path, near the median of advanced orders. Market's fill pays for the clone's `delegatecall`, closing a single-use order (about 22,000 for the first write of `closed`), the `ownerOf` delivery checks, and the genuine-fill check (about 2,500).
2. **Placing an order costs gas on Market and nothing on Seaport.** A Seaport listing or offer is an offchain signature plus a one-time approval. A Market listing costs a create (95,227) plus a transaction moving the token into escrow (67,026 to 110,187), about 162,000 to 205,000 in all; a Market bid costs one create with its ETH (95,618). At 1 gwei that is about 0.0001 to 0.0002 ETH per order.
3. **What the gas buys.** The order exists onchain with its funds or token escrowed, so it needs no offchain order book, cannot be filled after it is unfunded or the token has moved elsewhere, and can be discovered from `Market.Created` events alone. Seaport's offers are cheaper to place and can be over-subscribed against one WETH balance; a Market bid escrows exactly what it can spend.
4. **Escrow tradeoff.** A listed NFT is in its order, not the seller's wallet. Other marketplaces will not show it as the seller's, and it cannot be listed elsewhere at the same time.

These measurements do not cover Seaport's criteria or partial fills, Blur, or aggregated multi-order fills.
