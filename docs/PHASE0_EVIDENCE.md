# Phase 0 evidence

Recorded 2026-10-30. Revision: see `git log`; contract `contracts/Market.sol`.

## Result

**Escrow route proven on a fork (2026-10-30).** Real signed OpenSea offers, with OpenSea's real zone signature and signer, fill from Market custody through `Seaport.fulfillAdvancedOrder` with Market as fulfiller. Splits are exact to the wei and nothing remains in Market. See "Escrow fill" below.

The original noncustodial design (sections up to "Live fulfiller check") passed on chain mechanics but cannot get OpenSea's zone signature, because OpenSea signs only for the NFT's owner. That led to escrow (D023).

**Open item:** OpenSea must sign for the deployed Market address. Only a mainnet canary can show it (`OPERATIONS.md`, step 6).

## Native Seaport test (D004)

| Question | Finding | Evidence |
| --- | --- | --- |
| Can a native Seaport listing carry the declining price? | Yes. Consideration `startAmount` to `endAmount` over `[startTime, endTime)`. Seaport rounds consideration up. | `test/Buy.t.sol::testFuzz_priceMatchesSeaport` (256 runs, exact equality) |
| Can native matching route surplus to the seller? | **No.** `matchAdvancedOrders` sends unspent offer items to a caller-chosen `recipient`. A zone cannot see that recipient, and a percentage fee on a variable amount cannot be expressed in signed consideration. | Seaport 1.6 source, `ZoneParameters` struct |
| Can only our code fill the listing? | Yes, natively. Seaport skips zone checks only when `msg.sender == zone` (`ZoneInteraction._isRestrictedAndCallerNotZone`). With zone = Market and FULL_RESTRICTED, any other caller triggers `authorizeOrder` on Market, which does not exist, so the fill reverts. | `test/MatchOffer.t.sol::test_listingOnlyFillableThroughMarket` |
| Native cancel? | Yes. `Seaport.cancel` and `incrementCounter`. | `test_revertWhenListingCancelled`, `test_revertWhenCounterIncremented` |
| Native approvals? | Yes. The listing uses the OpenSea conduit key, so a seller who already approved the OpenSea conduit needs no new transaction. Market receives no approvals. | `Base.t.sol::giveNftToSeller` |

**Smallest contract that closes the gap:** `Market` is the listing's zone and its only fulfiller. It validates the listing shape, calls Seaport, then splits the WETH Seaport leaves with it. 1 storage-free contract, no owner, no upgrade.

## Real offers used

Both from mainnet `matchAdvancedOrders` calldata (OpenSea accept-offer route). The fork is pinned one block before each original fill, so the offer is live and unfilled. Calldata is stored verbatim in `test/fixtures/`.

| Fixture | Original tx | Fork block | Offer | Mandatory consideration | Zone substandard |
| --- | --- | --- | --- | --- | --- |
| `item_offer` | `0xbea8ca7637254e552e9d5538f99161c1d57d82a7d4b9aab5cf0336ad03e29447` | 26303107 | Item offer, Otherdeed `0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258` #48816, 0.0617 WETH, FULL_RESTRICTED | OpenSea fee 0.000617 | 0 |
| `collection_offer_royalty` | `0xc5992f3784e47e73ba469daebe37df46b7299d71a53246c8e0e23297250bf88f` | 26303123 | Collection offer (ERC721_WITH_CRITERIA, criteria 0), `0x7EEB9b28833934Aa9f79DA82d29AEbFa29b779F3` resolved to #2066, 0.235 WETH | OpenSea fee 0.00235, royalty 0.01175 | 0 |

Data source: Seaport `OrderFulfilled` logs with zone `0x000056F7000000EcE9003ca63978907a00FFD100` (OpenSea SignedZone, verified source on Sourcify), Tenderly public RPC.

Zone signature format (from verified source): EIP-712 `SignedOrder(address fulfiller,uint64 expiration,bytes32 orderHash,bytes context)`; extraData = `0x00 ‖ fulfiller(20) ‖ expiration(8) ‖ compact sig(64) ‖ substandard(1) ‖ tokenId(32)`. Observed expirations are about 5 minutes after signing. `fulfiller = 0` would allow any caller; OpenSea signs a specific fulfiller.

## Route

`Market.matchOffer(listing, offer, resolvers, fulfillments)` calls `Seaport.matchAdvancedOrders([listing, offer], resolvers, fulfillments, recipient = Market)`:

1. listing offer[0] (NFT) to offer consideration[0] (bidder), via OpenSea conduit from the seller
2. offer offer[0] (WETH) to listing consideration[0] (seller's current price)
3. offer offer[0] to each offer fee item (OpenSea fee, royalty)
4. unspent offer WETH to Market, then split: 0.30% executor, 0.20% protocol on (price + surplus), remainder to the seller

Criteria resolver for collection offers: `{orderIndex: 1, side: CONSIDERATION, index: 0, identifier: tokenId, proof: []}`.

## Assertions (both fixtures, `forge test --match-path test/MatchOffer.t.sol`)

`test_matchRealOffer`: NFT owner = bidder; bidder WETH down by exactly the offer; each fee recipient up by exactly its amount; seller up by `released - 0.5%`, which exceeds the current minimum; executor and protocol exact; Market WETH 0, Market ETH unchanged; replay reverts.

Collection offer with royalty: released 0.2209 WETH; seller 0.2197955, executor 0.0006627, protocol 0.0004418.
Item offer: released 0.061083 WETH; seller 0.060777585, executor 0.000183249, protocol 0.000122166.

Failure cases, each atomic with the NFT left with the seller where applicable: offer below minimum plus fees, exact boundary (passes at `minimum = released - 0.5%`), cancelled listing, expired listing, expired zone signature, seller approval revoked, seller no longer owns, bidder lacks WETH, different Market address (zone rejects fulfiller), direct Seaport fill attempt.

## Gas

| Action | Gas | Source |
| --- | --- | --- |
| matchOffer, real OpenSea item offer, whole tx | 383,763 | anvil receipt, `npm run e2e:keeper` |
| matchOffer, local offer with OpenSea-style fee | 340,816 | anvil receipt, local fork session |
| buy (direct, ETH) | 221,501 | anvil receipt, local fork session |
| setApprovalForAll (OpenSea conduit) | 46,187 | anvil receipt |
| Seaport.cancel | 53,637 | anvil receipt |
| Deploy Market | 2,343,271 | anvil receipt |
| OpenSea's own accept-offer, for comparison | 263,662 / 300,422 | mainnet receipts of the two fixture txs |

The 384k figure includes two first-time WETH balance writes for fresh fee recipients; recurring recipients are cheaper.

## Keeper path on a fork

`npm run e2e:keeper` (in `app/`) starts anvil at block 26303107, places Market's runtime at the zone-signed fulfiller, has a throwaway seller sign a listing, and runs the keeper's production `round()`: it prices the real offer from signed data, builds fulfillments, estimates gas, submits, records the receipt and syncs the `Sale` event joined to Seaport's order hash. Result: `{"ok":true,"gasUsed":"383763","available":"61083000000000000","seller":"60777585000000000"}`.

## Live fulfiller check (2026-10-30, with API key)

**Result: fails for Market as designed.** OpenSea's `POST /api/v2/offers/fulfillment_data` signs zone data only when the fulfiller owns the NFT in OpenSea's indexed state.

| Fulfiller requested | NFT and offer | Response |
| --- | --- | --- |
| Market deployed on a latest-block fork (`npm run live:fulfiller -- 0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258 48816`) | Otherdeed #48816, live item offer | `400 Item is not owned by the fulfiller` |
| `0x1111111111111111111111111111111111111111` (non-owner) | same | `400 Item is not owned by the fulfiller` |
| The NFT's current owner | same | Signed; returns a `fulfillAdvancedOrder` call, not a match |
| Seaport contract (non-owner) | same | `400 Account can not perform trading operations` |
| Contracts that own Milady #3, #14, #19, #32 | Milady collection offer | Signed; extraData names each contract as fulfiller |
| Contract that owns Milady #2 (`0x6FFd7EdE62328b3Af38FCD61461Bbfc52F5651fE`) | same | `400 Account can not perform trading operations` |

Consequences:

- The noncustodial design (seller keeps the NFT, Market fills through Seaport) cannot get a zone signature. The chain mechanics proven above still hold; the blocker is OpenSea's API policy.
- A contract holding the NFT can be signed, so an escrow Market is viable, subject to OpenSea not blocking its address and to indexing delay after deposit.
- Options and recommendation: `DECISIONS.md` D023.

## Escrow and venue investigation (2026-10-30)

Question A: will OpenSea sign offers for an independent contract that holds the NFT, and how soon after it arrives? Question B: is there meaningful bid liquidity outside OpenSea that a noncustodial Market could fill?

**A1. Contract eligibility.** `npx tsx research/eligibility.ts` (in `app/`, with `OPENSEA_API_KEY`). For live criteria-0 collection offers in Milady, Pudgy Penguins, Otherdeed, BAYC, MAYC and Lil Pudgys, it asked OpenSea to sign for up to 8 contract holders per collection, head block 26306418.

| Result | Count | Notes |
| --- | --- | --- |
| Signed, matchAdvancedOrders shape | 44 | Safe proxies, clones and custom contracts; newest created at block 26243422, about 10 hours earlier (`0x5AFe00Ea2870004f0656db5FeBa14AC9a4005AfE`) |
| Signed, fulfillAdvancedOrder shape | 1 | OpenSea sometimes returns a direct fulfillment instead of a match |
| `Account can not perform trading operations` | 2 | `0x6FFd7EdE62328b3Af38FCD61461Bbfc52F5651fE` (2021), `0xE9827e11ED5E27eD7Dea736D13e49cbabA0a4555` (2022). The Seaport contract gets the same answer. OpenSea publishes no rule for this |

**A2. Indexing delay.**
- `npx tsx research/indexing-recent.ts`: 20 of 20 transfers 6 to 100 minutes old were already indexed. OpenSea signed for the new owner every time and refused the previous owner every time.
- `npx tsx research/indexing-live.ts`: it watched new ERC721 transfers in any collection with an OpenSea offer, then polled every 5 seconds. Five transfers were signed for the new owner **2 to 8 seconds** after the block. A sixth failed with `Seller cannot accept their own offers`, because the new owner was the bidder; that is unrelated to indexing.

**B. Other venues.** 24 hours, blocks 26299200 to 26306400, ERC721 bids paying WETH or BETH. Measured by an independent research agent and spot-checked: over blocks 26305331 to 26306531, 612 bid fills went through the OpenSea SignedZone, 5 through the OpenSea PausableZone, and 0 were unrestricted.

| Venue | Bid fills | Volume | Fills at or above 0.064 | Fillable by an independent contract? |
| --- | --- | --- | --- | --- |
| OpenSea SignedZone | 4,075 | 214.1 WETH | 331 | Only if the fulfiller owns the NFT (A1) |
| Blur V2 (`0xb2ecfE4E4D61f8790bbb9DE2D1259B9e2410CEA5`) | 44 | 22.19 BETH | 32 | No: needs a Blur server signature and has no public order API |
| Seaport, zone 0 (unrestricted) | 0 | 0 | 0 | Yes, but there is no demand |
| LooksRare V2 | 0 (0 in about a week) | 0 | 0 | Yes, but there is no demand |
| OpenSea PausableZone | 7 | 0.106 WETH | 0 | Negligible |
| X2Y2 | 0 | 0 | 0 | - |

Reservoir's NFT API was sunset on 2025-10-15, so it is not an order source.

A flash loan cannot fix the OpenSea refusal. OpenSea checks ownership offchain, minutes before the transaction, so taking ownership mid-transaction comes too late. Zero-fee flash loans from Balancer V2 and Morpho Blue exist, but every venue that needs no offchain signature has no demand.

**Conclusions.**
- Escrow is practical. OpenSea signs for contracts that hold the NFT, including one deployed hours earlier, and sees a deposit within seconds.
- Noncustodial matching has no meaningful liquidity source. OpenSea carries about 99% of Seaport ERC721 bids, and the only other venue with demand (Blur) is closed to independent fillers.
- One fact cannot be proven without a mainnet deployment: whether OpenSea will accept Market's own address. 2 of 48 contracts were refused, for reasons OpenSea does not publish.
- The escrow fill must accept either response shape from OpenSea.

## Limits

- Trait offers are excluded (need proofs; criteria other than 0).
- Offers paying anything but WETH, or with non-WETH fee items, are excluded.
- ERC721-C collections (zone substandards 7 to 9) are not tested.
- Keyless OpenSea API responses are only served for cached URLs; per-NFT best offers and uncached metadata return 401. Discovery needs a key in practice.

## Escrow fill (2026-10-30)

`forge test --match-path test/OpenSea.t.sol`: 22/22 pass (11 per fixture).

Route: the seller deposits the NFT with `safeTransferFrom(seller, market, id, 0x00 ‖ abi.encode(Listing))`. `Market.fillOffer(listing, id, offer, resolvers)` approves Seaport for that token and the offer's WETH consideration, calls `Seaport.fulfillAdvancedOrder(offer, resolvers, 0, market)`, checks the NFT left and Market's WETH did not fall, then pays fees and the seller. Resolvers index the offer as order 0.

Both fixtures are OpenSea **match-shaped** fills (`matchAdvancedOrders`). Their zone extraData verifies unchanged under direct fulfillment. The zone checks fulfiller, expiration and order hash, not the call shape, so one onchain route covers both OpenSea response shapes (D034).

| Fixture | Sale price (bidder paid) | Offer fee items | Seller | Executor 0.30% | Protocol 0.20% |
| --- | --- | --- | --- | --- | --- |
| `item_offer` | 0.0617 | 0.000617 | 0.0607745 | 0.0001851 | 0.0001234 |
| `collection_offer_royalty` | 0.235 | 0.0141 (fee + royalty) | 0.2197250 | 0.000705 | 0.00047 |

Assertions per fixture: NFT to bidder; bidder WETH down by the offer; each fee item paid exactly; seller, executor, protocol exact; Market WETH 0; listing consumed; replay reverts. Failure cases: ask one wei above proceeds, cancelled listing (then withdrawn), expired zone signature, zone disabled, Market at an address OpenSea did not sign for. Adversarial synthetic offers (zone relaxed to reach Seaport): an offer whose consideration takes more WETH out of Market than it pays in reverts with escrow intact; an offer that names another token reverts; a well-formed one splits exactly.

Gas: `fillOffer` execution 435,583 on the item offer (`test/Gas.t.sol`).
