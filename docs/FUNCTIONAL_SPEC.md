# Functional specification: Market

Status: revised 2026-10-30 after Phase 0. Implemented; see `STATUS.md`.

## 0. Revisions from implementation evidence

1. Settlement is a native Seaport 1.6 listing restricted to zone = Market. Market is the only possible fulfiller and splits the surplus (D004, D015).
2. The price falls from start to floor and the listing ends there. No hold at floor (D016). Section 3.1 step 2 and 4.1 below are amended.
3. Direct buyers pay ETH; overpayment returns as WETH (D014, D017). Direct-buy fee is 0.20% to protocol, paid by the buyer (D006).
4. Sellers approve the OpenSea conduit, usually already done; Market holds no approvals (D018). Proceeds go to the seller (D019).
5. Fee limits are bound by the signed zone address: each Market deployment has constant fees (D015).
6. Supported offers: WETH item offers and collection offers on Seaport 1.6; trait offers excluded (D020).
7. Matching needs an OpenSea API key; keyless access is unreliable (D021).


## 1. Purpose and product promise

A holder who wants to sell one Ethereum NFT should be able to set a price that automatically declines and leave the sale alone. A buyer can purchase at the current price. Separately, the product watches existing onchain offers, initially OpenSea Seaport, and attempts an atomic sale when an available offer meets the seller's authorized minimum net proceeds.

The seller keeps the NFT until settlement. The product does not guarantee a sale or the best market price. It does not need its own bidders, trading token, liquidity pool, or large marketplace.

The key differentiation over an ordinary Dutch auction is automatic matching to outside liquidity and seller protection on the execution surplus. Most of an existing offer's net value should reach the seller, rather than being left for a matcher to capture without disclosure.

## 2. Audience and usage

Primary user: NFT holders who wish to exit an asset with minimal ongoing attention. Particularly relevant for holders of multiple NFTs in established collections with existing bids.

Secondary user: buyers who want to purchase a listed NFT directly at its current asking price. Executors or keepers are infrastructure participants, not the primary customer.

Not intended for initial mint drops, complex auctions, guaranteed liquidation, collection market making, loans, or ERC20 swaps.

## 3. Product flows

### 3.1 Seller creates a listing

1. Connect an Ethereum wallet and select an ERC721 NFT that the wallet owns.
2. Enter starting seller net price, minimum seller net price and the time until the price reaches that minimum, which is also when the listing ends. The minimum must be at most the start, and the start must be above zero. The UI presents plain values and clear transaction and authorization details.
3. Show a live projected net price schedule and the extra execution fees required for a direct buyer. The listed price is the minimum NET proceeds guaranteed to the seller in WETH, after our protocol and executor fees and any external mandatory consideration. Display the distinction explicitly.
4. Seller signs a bounded order or authorization and grants only the necessary NFT approval to the verified settlement operator. Prefer standard signed Seaport orders and native approvals if they can enforce the same guarantees; otherwise use the smallest EIP712 sale authorization and settlement contract that does.
5. Save the signed listing through an authenticated endpoint and show its onchain signature validity and live state. No NFT escrow or token deposit.
6. Support cancel by a binding onchain cancellation or nonce invalidation. Hiding a listing in the database alone is not adequate cancellation. An expired, canceled, transferred or revoked order cannot execute.

Recommend a nonzero floor by default. Permit an explicit zero floor only with a conspicuous confirmation that near zero execution is possible. It still does not guarantee a sale.

### 3.2 Direct buyer purchases

1. A public listing page displays the NFT, the current net target, total buyer consideration including fees, the remaining decline and expiry.
2. A buyer can fulfill the signed sale at the current executable price. The seller receives at least their current required net. All payments and the NFT transfer happen atomically.
3. The order becomes unfillable after one successful sale. Buyer sees a clear failure if sold, revoked, expired, or insufficiently approved.

Existing marketplace distribution is desirable only when compatible without weakening the seller's protected proceeds. Do not promise OpenSea will index arbitrary custom orders.

### 3.3 Automatic match to an external offer

1. A minimal worker discovers active OpenSea item and collection offers for supported collections through a documented API. The external API is a discovery surface, never the source of settlement truth.
2. Compute the actual WETH that a specified offer would deliver after mandatory order consideration, external fees, royalties and constraints. Use signed order data, not only a headline bid price. Match only offers that are executable for this exact NFT.
3. Compare possible net proceeds to the current seller minimum, protocol fee and executor reward. Simulate the actual atomic path and apply conservative gas and profitability limits.
4. Submit a single Ethereum transaction that consumes the seller authorization and fills the external bid. On success the NFT ends with the offer's buyer, the seller gets all available net WETH from that selected offer less disclosed protocol and executor fees, and fees are transferred to explicit recipients.
5. If either side is invalid or execution fails, the entire transaction reverts and the NFT is not left in a matcher wallet. The executor may lose gas on failed attempts.
6. A permissionless external executor can submit an equivalent settlement if it meets the same enforced invariants. The protocol may operate its own matching worker, but the contract must not require that worker's ongoing operation.

Do not assert global best execution: the system can optimize among offers it actually sees and supports, while another bidder or marketplace may have a better order. Anyone may purchase at the authorized minimum even if a higher external offer existed. Contract guarantees focus on net settlement of the chosen offer and user consent, not the theoretical best price anywhere.

### 3.4 Seller manages listings

Show active listings, price now, price at expiry, ownership, order validity, recent execution status, and completed sales. Support onchain cancellation. Completed sales show actual NFT transfer, WETH received by the seller, the offer consumed, royalty and recipient transfers, executor fee, protocol fee, transaction link, and any difference between the executed bid and authorized minimum.

## 4. Pricing and order policy

1. V1: a deterministic linear decline by block timestamp from the start net amount to the floor net amount, ending at the order's end time; then the order is invalid. Rounding follows Seaport (consideration rounds up), and the price never increases. Inputs are fixed by a wallet signature. Never increase the seller's required amount through rounding.
2. All settlement accounting and authorization are in WETH on Ethereum mainnet. The frontend may display an ETH equivalent because WETH and ETH are redeemable 1:1, but it must make the actual token payment clear. Optional native ETH convenience may be added only if straightforward and tested.
3. One ERC721 per listing, one fill per listing, no partial fills, leverage, complex bids or multichain routing. Supported collections may initially be curated by the app for tested compatibility; avoid unnecessary mutable contract allowlists.
4. Initial tentative total fee: 0.50% of available proceeds after mandatory external considerations. Tentative split: 0.30% executor and 0.20% protocol, with explicit recipients. Revisit these exact values using real fork gas and offer economics before implementation freeze. A keeper may skip uneconomic fills. Do not subsidize every sale or seize any extra spread.
5. Seller authorization must enforce the maximum total fee, approved settlement protocol, proceeds recipient and minimum net. Fee settings must never change retroactively for a previously signed order. If a fully native Seaport signed listing cannot express the same guarantees, introduce the minimum bounded authorization wrapper needed.
6. No arbitrary asset withdrawals by protocol owner or executor. Protocol revenue is delivered directly to its declared recipient. Prefer immutable or noncustodial versioned deployments over upgradeable custody.

## 5. Architecture and Phase 0 technical gate

Preferred path: Seaport signed dynamic price orders and native order matching. Alternative only if necessary: a small contract that verifies a seller's typed signed authorization, temporarily controls the NFT within ONE atomic transaction, settles a selected compatible Seaport offer, and atomically distributes all proceeds with enforceable seller minimum and fees. Its code must not be able to execute arbitrary external calls or retain user NFTs or proceeds after a successful fill.

Before choosing the architecture, prove these cases on a pinned Ethereum mainnet fork using a REAL active signed OpenSea offer:

1. An NFT seller can authenticate a declining price and cancel the authorization onchain.
2. A supported item or collection offer can be fulfilled with the real Seaport order signature, approvals, offer status, criteria resolver as needed, zone behavior and deployed contract addresses.
3. A trade with available offer value above seller current minimum routes that surplus to the seller, save explicit fees, with no residual funds or NFT in the executor/settlement contract.
4. Simulate changes to bid availability, owner balances, approvals, prices, royalties and races. Both legs must revert together on failure.
5. Record the block number, order hash, data source, exact calldata route, before and after token balances, gas and any required permissions. Mocked orders test local logic but do not satisfy this gate.

Try native Seaport `matchAdvancedOrders` and `fulfillAdvancedOrder` in real tests. Test limitations before adopting either. Avoid writing a new protocol, a custom order book or generalized adapters when Seaport's existing functionality already satisfies the invariants.

If real OpenSea offers cannot be filled from a contract under certain restricted zones or criteria, document exactly which order types are supported, exclude unsupported orders and keep progressing. Do not silently use unsafe direct fulfillment. A smaller honest product with item offers first is preferable to universal unsupported claims.

## 6. Infrastructure

Build only what is needed:

1. Solidity with Foundry for any minimal settlement logic, tests and reproducible fork harness.
2. A small TypeScript Node worker using viem to discover offers, validate, price, simulate and submit profitable executions. The worker must be restart safe, idempotent and rate limit aware; it must never hold a user NFT across transactions.
3. A responsive Next.js application with wallet connection, create listing, public listing detail and browse, active listings, cancellation and sales history.
4. A minimal durable storage layer for signed orders and indexing. Prefer a simple single worker deployment and SQLite if adequate, upgrade storage only if actual hosting requirements demand it. No message bus, Kubernetes, microservices or complex generalized indexer in V1.
5. Read only API access for offer discovery, with environment based secrets and an explicit no API key mode that surfaces lack of matching coverage rather than fabricating bids.

The UI should be clean, mobile first and direct. Avoid a full marketplace with discovery rankings, gamification, recommendation engines or a new identity system. Use established NFT metadata sources; sanitize external metadata.

## 7. Security properties

1. Seller authorization is bound to chain id, verifying contract, NFT contract, token id, seller, proceeds recipient, start, floor, times, unique nonce and fee limit; every successful fill consumes it once.
2. Cancellation is effective onchain and works even if the hosted service is down. Show what happens to approvals after cancellation.
3. Noncustodial in normal state; custody, if unavoidable, exists only during the single execution transaction and never survives a revert or successful fill.
4. Reject reentrancy, untrusted callbacks, malicious NFT transfer hooks, arbitrary target calls, counterfeit Seaport addresses, bad consideration tokens, delegated approvals and unexpected wrapped native token behavior.
5. Only validate funds that actually arrive and are distributable in the execution. Prevent executor, protocol or third party from capturing unallocated surplus; prevent stranded funds or NFTs. Use precise balance and NFT transfer assertions in tests.
6. Test canceled, expired, filled, replayed, chain spoofed, transferred or approval revoked orders; malformed signatures, criteria proofs, restricted zones, royalties, varying gas, front running and competing fills. No ability for an administrator to alter a signed minimum or drain assets.
7. Investigate MEV and failing transaction gas economics; keepers may use private submission, but the contract must be safe through the public mempool too.
8. No deployment with real funds before independent review and explicit authorization. Any unaddressed severe finding means not launch ready.

## 8. Economic and operational requirements

Measure profitability for matching orders of 0.05, 0.1, 0.5, 1, 5 and 10 ETH equivalent across realistic gas/base fee regimes. Include Seaport execution, NFT approvals, any external royalty considerations, API access, worker overhead and protocol/executor revenue. Derive the minimum economically viable fill threshold instead of assuming small trades are profitable.

Measure seller outcomes against accepting an available bid immediately and listing at a fixed price. Do not claim declining auctions maximize sale proceeds. Estimate how often the external matching path would actually add a fill, using real observable offer snapshots if obtainable, and label sparse evidence honestly.

The worker must respect cancelability, RPC failures, stale data, stuck transactions, nonce replacement, transaction confirmation, reorgs and throttling. Provide metrics/logs for matching candidates, submitted txs, successful txs, reverted txs, net proceeds and revenue. It can stop without freezing seller cancellations or valid buyer fulfillment.

## 9. Acceptance criteria

1. A seller can list an NFT without transferring it to the protocol, see its price decline, cancel irrevocably onchain, and buy/sell can never execute beyond authorization.
2. A buyer can purchase directly through a tested route.
3. A real Seaport offer can be fulfilled atomically on a fork with seller net proceeds and fee distributions verified exactly, or the product explicitly documents and scopes a supported alternative after a failed POC.
4. The own keeper completes an eligible fill, a third party can perform a permissionless fill, and invalid offers fail atomically.
5. A complete, usable responsive frontend and service exist with setup/deployment instructions, unit, integration, fork, adversarial and end to end tests.
6. An independent review's actionable findings are resolved; gas and execution profitability boundaries are documented; no claim of formal audit or real launch is made.

## 10. Exclusions

No ERC20 selling product; no native token; no CC flywheel; no yield, loans, NFT fractions, auction bids collected in a new pool, liquidity mining, artificial scarcity, generalized arbitrary call router, complex governance, perpetual keeper subsidies, mobile app, multi chain support, or promises of guaranteed execution.

## 11. Sources to verify at implementation time

1. Seaport documentation: https://github.com/ProjectOpenSea/seaport/blob/main/docs/SeaportDocumentation.md
2. Seaport interface and advanced matching: https://docs.opensea.io/docs/seaport-interface
3. OpenSea collection offer discovery: https://docs.opensea.io/reference/get_offers_collection
4. OpenSea offer fulfillment payload: https://docs.opensea.io/reference/generate_offer_fulfillment_data_v2
5. Official Ponytail instructions: https://github.com/DietrichGebert/ponytail/blob/main/INSTALL.md

These sources establish available capabilities, not proof that the proposed exact composition of calls works. The fork POC supplies that proof.
