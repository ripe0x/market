# Actions and integration guide

Every order runs one action implementation through `Order.execute(input)`. This guide covers the shipped implementations, the reservation interface, how to integrate them, and recovery. Which promise comes from where:

| Promise | Source |
| --- | --- |
| Commitments are fixed and readable; lifecycle, admission, deadline, phase guard, credit accounting, token mint/burn rules | Core (`Market`, `Order`, `Actions`) |
| Prices, fees, royalties, custody checks, delivery, who may trigger cleanup | The action implementation |
| A reserved operation stays available to its executor until used, released or expired | The target contract (for `ReservedAction`) |

## ExchangeAction: sales and bids

One shared contract. Orders must be Public and their residual must be the issuer.

```solidity
struct Schedule { uint256 startPrice; uint256 endPrice; uint64 startTime; uint64 endTime; }
struct Config { Side side; IERC721 nft; Schedule schedule; uint16 maxFeeBps; bytes terms; }
struct SaleTerms { uint256 tokenId; address proceedsTo; uint16 maxRoyaltyBps; }
struct BidTerms { bool anyToken; uint256 tokenId; address recipient; uint64 maxExecutions; uint64 minActionTimeLeft; }
```

**Price.** Linear from `startPrice` at `startTime` to `endPrice` at `endTime`, then constant. Equal prices give a fixed price. Interpolation uses `mulDiv` and rounds the movement down, so the price never moves further from `startPrice` than the line (a falling price rounds up, a rising price rounds down). An order may activate before `startTime`; execution before it reverts `NotStarted`. Expiry is the order's deadline; activation rejects a finite deadline at or before `startTime`.

**Money.** `price` is all the buyer spends. `fee = price * feeBps / 10_000`, where `feeBps` is `FeeConfig.feeBps()` at activation and must not exceed `maxFeeBps`; it is stored as the activation terms and never changes. The fee goes to `FeeConfig.recipient()` at execution. `royalty` is the collection's ERC2981 answer, capped at `price - fee`; a reverting lookup or a nonzero royalty without receiver reverts. `proceeds = price - fee - royalty`. All transfers are immediate and atomic with the execution.

**Sale.** The NFT is transferred to the order (or its predicted address) before activation; activation checks custody. Input `abi.encode(address recipient, uint256 maxPrice, uint64 minActionTimeLeft)`. The buyer sends at least the price; the excess returns to the actor. The royalty must not exceed `maxRoyaltyBps` of the price. The sale completes on delivery. To withdraw a listing: `cancel()`, then `release(recipient, "")` from the residual. A canonical Actions token that is no longer live cannot move and its release reverts `ActionNotLive`; `cancel` still works.

**Bid.** Funded by ETH sent at creation or to the order later; each execution checks current free balance. Input `abi.encode(uint256 tokenId, uint256 minProceeds, address proceedsTo)`, no ETH. The seller approves **ExchangeAction**, preferably for the single token, never the order. ExchangeAction moves only the executing actor's named token to the bid's fixed `recipient`. `maxExecutions` must be positive; the order completes after the last one. `anyToken` requires `tokenId == 0`. To withdraw: `cancel()`, then `withdrawSurplus`.

**Actions tokens.** Trading one requires its underlying order to be live with at least `minActionTimeLeft` before its deadline (sale: purchaser input; bid: bid term). Collection-wide bids on Actions are refused. Ordinary NFTs require `minActionTimeLeft == 0`. The Actions collection reports no ERC2981 royalty: an Actions resale premium is separate from the price its own action charges.

`quote(order, input)` is advisory: it does not check custody, funding, approvals, remaining executions or liveness. Event: `Exchanged(order, tokenId, side, actor, nftRecipient, proceedsTo, price, fee, royalty)`.

## CoveredNFTPurchase

A Holder order whose token owner may buy one escrowed ordinary NFT at a fixed price. Residual must be the issuer; canonical Actions tokens are refused as collateral.

`Config { IERC721 nft; uint256 tokenId; uint256 price; address proceedsTo; uint16 maxRoyaltyBps; }`

Activation snapshots `(royaltyTo, royalty)` from ERC2981 for `price`, within `maxRoyaltyBps`. Execution input `abi.encode(address recipient)` with exactly `price` ETH: delivers the NFT, credits the royalty and `price - royalty` to `proceedsTo`, completes and burns the token. No trading fee. A zero price is allowed. Surrender and expiry charge no royalty; the residual recovers the NFT with `release`. An issuer that holds or buys back the token can surrender and recover its collateral. Address checks do not establish beneficial ownership. An Actions token escrowed by mistake is rejected at activation and is recoverable only while its own order stays live; afterwards it cannot move and stays in the order.

## ReservedAction and IReservedActionTarget

`IReservedActionTarget` is this project's proposed interface, not an Ethereum standard:

```solidity
enum ReservationState { None, Reserved, Consumed, Released }
function reservationOf(address executor) external view returns (bytes32 operationHash, uint64 deadline, uint256 value, ReservationState state);
function performAction(bytes calldata operation, bytes calldata input) external payable returns (bytes memory);
function releaseReservation() external;
```

The target authorizes reservation creation with its own rules, records one permanent reservation per executor address, and enforces the operation hash, exact `msg.value`, its own deadline and single consumption (consumed before effects; a revert restores it). Release only affects the caller's reservation, makes no external calls and never clears a newer grant in the same scope. `reservations/ReservedActionTarget.sol` implements this bookkeeping. A target needs no knowledge of Market.

`ReservedAction` `Config { target; bytes operation; uint256 price; uint256 targetValue; address proceedsTo; }`, `targetValue <= price`. Activation requires a matching Reserved reservation for the order address with the same deadline and value, and commits the target's runtime code hash. Execution takes exactly `price`, calls `performAction{value: targetValue}` from the order, verifies consumption and credits `price - targetValue`. Works with either admission. Release: residual only while Pending; anyone once ended.

`examples/Artwork.sol` reserves one palette or renderer change among an allowed bitmask. Reservations survive transfer, block burning while live, and do not stop the owner's own later changes. A perpetual reservation to an unusable executor occupies its scope permanently.

## AcquireAndExecute

`acquireAndExecute(Params)` buys a listed Actions token and executes its covered purchase to `recipient` in one call. It binds the listing, account, NFT and token id, execution price, activation terms hash, `maxPremium`, `maxTotal`, `recipient`, `refundTo` and an exclusive `deadline`, and checks both orders' Market provenance, implementations, admission, custody and liveness. It pays from the call's ETH only and refunds the rest to `refundTo`. The underlying order's actor is the helper; the event records the payer and recipient.

## Integration walkthrough

1. Build an `OrderSpec` and pick a salt. `Market.orderAddress(issuer, spec, salt)` gives the address.
2. Put backing in place: transfer the NFT to the predicted address (sale, covered), have the target reserve for it (reserved), or send ETH with creation (bid).
3. `Market.createAndActivate{value}(spec, salt)`, or `create` then `activate`. `previewActivation()` on a Pending order shows the terms activation would store.
4. Execute with `order.execute{value}(input)`.
5. After termination, withdraw credits (`releaseCredit`/`withdrawCredit`), release backing (`release`) and surplus (`withdrawSurplus`).

### Discovery and recovery without an indexer

Treat any order address from an index as untrusted. Authenticate with `Market.isOrder(addr)`, then read `issuer()`, `action()`, `actionCodehash()` (compare with the deployed action's code hash), `admission()`, `deadline()`, `residual()` and `config()` directly from the order. These remain readable after termination and burn, so recovery needs only the address and the configured Market.
