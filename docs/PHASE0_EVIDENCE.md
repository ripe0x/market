# Phase 0 evidence

Recorded 2026-10-30. Revision: see `git log`; contract `contracts/Market.sol`.

## Result

**Gate passed for chain mechanics, with one open item.** Real signed OpenSea offers, with OpenSea's real zone signature and real zone signer, settle atomically against a declining Market listing on a pinned mainnet fork. Seller net, surplus routing, OpenSea fee, royalty, executor fee and protocol fee are exact to the wei, and nothing remains in Market.

**Open item:** the fork runs place Market's code at the address OpenSea's zone signature already names (the original fulfiller of a historical fill). Live operation needs OpenSea to sign zone data naming the deployed Market address. That requires `POST /api/v2/offers/fulfillment_data` with an API key, which this session does not have. The endpoint's documentation describes no ownership check on the fulfiller, and onchain data shows OpenSea signing for contract fulfillers (router `0x0729E2a4716d9f7dD17858d5d504426D228697f7`, listing purchases). Bid fulfillment for a non-owner contract fulfiller is not yet observed. Reproduction is below.

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

## Reproduce the open item with an API key

1. Deploy Market to an anvil fork at the latest block (`scripts/fork.sh` prints the address).
2. Run the keeper with `OPENSEA_API_KEY` and `KEEPER_UNLOCKED_ADDRESS` against that fork. `lib/opensea.ts::fulfillment` requests zone data naming the Market address.
3. Pass: a `submitted` then `confirmed` log line. Fail modes to record: API refusal (status and message), `InvalidFulfiller` from the zone, or a substandard Market does not handle.

## Limits

- Trait offers are excluded (need proofs; criteria other than 0).
- Offers paying anything but WETH, or with non-WETH fee items, are excluded.
- ERC721-C collections (zone substandards 7 to 9) are not tested.
- Keyless OpenSea API responses are only served for cached URLs; per-NFT best offers and uncached metadata return 401. Discovery needs a key in practice.
