# Market

Market is a permissionless Ethereum protocol for immediate onchain executions and transferable rights to execute later.

An **order** is a cancelable offer that executes when filled. A **right** is a transferable entitlement backed by its own account: acquiring or reselling its ERC721 token does not execute the operation. The current token owner may exercise it once under committed conditions, or it may expire or be surrendered.

The core has no owner, fee, registry or upgrade path. The reference NFT trading handlers charge a fee of up to 1% per fill, set per order when the order is created. Exercise of a covered NFT purchase right has no trading fee.

> **Status: experimental, unaudited.** Tests and automated reviews are evidence about tested behaviour, not a safety claim ([docs/STATUS.md](docs/STATUS.md), [docs/SECURITY.md](docs/SECURITY.md)). Nothing is deployed to mainnet.

The rights implementation is merged, but the rights-enabled contracts are **not deployed on Sepolia**. The verified 2026-11-16 Sepolia addresses are for the order-only release. The current metadata build is recorded in [status](docs/STATUS.md) and the [deployment reference](docs/DEPLOYMENT.md); the client maintains separate legacy and rights release manifests.

## How it works

**Market creates orders and right accounts. Orders execute on fill. Rights hold authority until their ERC721 holder exercises or terminates them.**

| Part | What it is |
| --- | --- |
| [`Market`](src/Market.sol) | Factory for isolated order and right accounts. Records order creation time. Holds no user assets and takes no fee. |
| [`Order`](src/Order.sol) | One account per order, with its own ETH, tokens, approvals and roles. Its terms (owner, handler, handler code hash, config hash) are written into its code and address, so they never change. |
| OrderHandler | Any contract implementing [`IOrderHandler.onFill`](src/Order.sol). Decides what the order does in a fill and what the filler must give. One handler serves many orders, each with its own config. |
| Fill | `order.fill(config, input)`, by anyone. The order calls its handler, which makes the order act through `Order.execute`. Any revert undoes everything. |
| [`Right`](src/Right.sol) | An isolated backing account with fixed issuer, handler, config, deadline and residual beneficiary. It starts pending; activation verifies backing and mints the token. |
| [`Rights`](src/Rights.sol) | The canonical ERC721. `ownerOf(tokenId)` is the sole source of current exercise and transfer entitlement. The token ID identifies its backing account. |
| Exercise handler | Implements backing validation and one committed operation. It acts through the right account only during the holder's authorized exercise. |

Who may make an order act:

| | Active | Closed (permanent) |
| --- | --- | --- |
| Anyone | `fill` on the handler's terms | Nothing |
| Handler | `execute` as the order, only during that order's fill | Nothing |
| Owner | `close`, outside a fill | `execute` anything as the order: withdraw, revoke |

So an active order commits what it holds to its handler: nothing leaves except through fills until the owner visibly closes it, and closing always lets the owner recover everything without calling the handler. Full rules: [docs/SPEC.md](docs/SPEC.md).

## Create and fill an order

```solidity
// Seller: list one NFT at a price falling from 1 ETH to 0.1 ETH over a day.
NFTSale.Config memory c = NFTSale.Config({
    nft: nft, tokenId: 7,
    schedule: NFTTrade.Schedule(1 ether, 0.1 ether, block.timestamp, block.timestamp + 1 days, 0),
    proceedsTo: seller, maxRoyaltyBps: 1000
});
bytes memory config = abi.encode(c);
Order order = market.create(nftSale, config, salt);
nft.transferFrom(seller, address(order), 7);            // the order is the escrow

// Buyer: read config from the Created event, quote, fill.
(uint256 price,,,,) = nftSale.quote(address(order), c);
order.fill{value: price}(config, abi.encode(buyer, price)); // recipient, max price

// Seller, to cancel instead: close, then recover.
order.close();
order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 7)));
```

`Market.orderAddress(owner, handler, keccak256(config), salt)` gives the address before creation, so assets can be sent first.

Canonical `Rights.tokenURI` is onchain JSON describing the backing account and generic commitment. It does not fetch a handler or nft URL. Handler-specific terms come from the authenticated `RightCreated` config and stored activation terms.

## Issue, trade and exercise a right

1. The issuer calls `Market.createRight(handler, config, deadline, residual, salt)`. The new account is **pending** and has no token. The issuer deposits the NFT or arranges a target-enforced reservation from outside that account.
2. The issuer calls `Right.activate(config)`. The bound handler verifies backing and fixes any activation terms, including the covered NFT's royalty recipient and amount. `Rights` mints token `uint256(uint160(address(account)))` to the issuer. The account cannot execute arbitrary setup calls.
3. The holder may transfer the token directly or escrow it in a normal `NFTSale` order. Filling that sale transfers the right only. The buyer may hold it, list it again, or exercise it. Closing the listing returns the token to its listing owner and leaves the right unchanged. An escrowed token belongs to the order, so its former holder cannot exercise it.
4. Before the right's deadline, the current token owner calls `Right.exercise(config, input)`, supplying the supported handler's exact exercise payment. The account calls the handler, checks and performs the operation, reserves proceeds as isolated credits, consumes the claim and burns the token. A failed call rolls all of this back. The holder can instead surrender. At the deadline, anyone can finalize an active right or an abandoned pending setup; exercise, transfer and supported sale or bid quotes already fail then.
5. The fixed residual beneficiary may recover unencumbered assets after a terminal state. Anyone may call `releaseCredit(beneficiary)` to pay a recorded credit to that beneficiary. The beneficiary alone may call `withdrawCredit(recipient)` to choose another payout destination. Neither issuer nor holder can withdraw backing while the right is live; after termination recovery belongs only to the committed residual beneficiary.

The covered NFT purchase handler activates only when the right's immutable residual beneficiary equals its immutable issuer. A buyer who surrenders or lets the right expire gets no claim on the NFT; the issuer may recover it after termination. If the issuer still holds or buys back the token, it may surrender and recover its own NFT without an exercise payment or royalty. The general core retains configurable residual beneficiaries for other handlers. An accepting royalty receiver can be paid by a third party through `releaseCredit`, even if it cannot make outbound calls. A contract that both refuses ETH and cannot authorize another destination still leaves its credit reserved and uncollected.

Check the pending account's residual address **before depositing**. A covered NFT account configured with a non-issuer residual cannot activate, but after canceled or expired setup that named residual can recover its deposits. No transferable token is minted for the rejected setup.

The right's **deadline is exclusive**: `block.timestamp >= deadline` ends exercise and transfer, without waiting for finalization. Deadline `0` is a perpetual commitment with no issuer cancellation path after activation. Keep an order's trading deadline earlier than the right's deadline to leave a useful exercise window. A generic NFT buyer must inspect the right's terms and remaining time; ordinary NFT trading cannot guarantee this window for them.

The canonical `Rights.tokenURI` provides onchain JSON for an existing entitlement: backing account, issuer, handler and code hash, configuration hash, activation terms, residual beneficiary, exact deadline string, state and effective liveness. It calls no handler or target contract. Interpret operation-specific terms from the `RightCreated` config and the bound handler; token metadata alone is not a value or safety certificate. At a finite deadline it reports expired even before finalization; pending and burned tokens have no URI.

| Action | Asset/payment effect | Who controls it |
| --- | --- | --- |
| Fill an ordinary execution order | Executes immediately under its handler | Any filler meeting its terms; listing owner may cancel first |
| Buy or resell a right token | Transfers only the entitlement; backing stays at the same right account | Actual ERC721 holder and approved transfer operator |
| Exercise a right | Executes once, consumes token, credits committed proceeds | Current token owner only |
| Cancel a right-token listing | Ends only the sale order; returns its escrowed token | Listing owner |

The covered NFT purchase right fixes its ETH exercise price and activation royalty, and verifies NFT delivery. Its issuer may earn a primary listing premium; each resale premium belongs to that listing's seller. The underlying NFT's ERC2981 royalty is credited once on exercise, **not** on every right-token resale. The ordinary trading fee applies to premium sales; exercise has no trading fee or dependency on mutable `FeeConfig`. The reserved artwork right promises one authorized modification, not permanent control over the artwork or its color. The older `PaintAction` example remains an immediate order backed by a revocable painter permission, not a durable right. See [the design and trust boundaries](docs/RIGHTS_DESIGN.md) and [the local demonstrations](docs/DEPLOYMENT.md#local-right-lifecycles).

## Write a handler

```solidity
contract BellHandler is IOrderHandler {
    function onFill(address, uint256 value, bytes calldata config, bytes calldata) external returns (bytes memory) {
        (address bell, uint256 fee, address payee) = abi.decode(config, (address, uint256, address));
        require(value == fee, "fee");
        Order(payable(msg.sender)).execute(bell, 0, abi.encodeWithSignature("ring()"));
        Order(payable(msg.sender)).execute(payee, value, "");
        return "";
    }
}
```

The bell's owner makes the order the only account allowed to `ring()`; from then on it rings for whoever pays ([test/NewOrderType.t.sol](test/NewOrderType.t.sol)). Deploy the handler; no registration is needed.

Rules that keep a handler safe to share (full guide, testing and `cast` walkthrough: [docs/HANDLERS.md](docs/HANDLERS.md)):

1. **Act only through `Order(msg.sender).execute`.** Build every call yourself; never forward calldata from `input`.
2. **Take only from `caller`,** and never under an approval to the order (below). Use `value` for the fill's ETH.
3. **Key state by `msg.sender`,** so each order changes only its own state.
4. **Hold no assets or authority of your own.** Anyone can call `onFill` directly, posing as an order. A handler that must hold approvals, or whose events others rely on, must first check it is called by a genuine order bound to it during its fill, as `NFTTrade._requireFill` does.
5. **Verify receipt by state** (`ownerOf`, balances), not by return values.
6. **End single-use orders** by consuming their authority and closing them.
7. **Stay immutable:** no owner, proxy, `delegatecall` or switches. Market pins the handler's code hash; it cannot pin what that code reads.
8. **Make owner maintenance of active orders an explicit, narrow fill,** if you offer it at all.

## Authority: orders versus shared handlers

These are different and should not be confused:

1. **Authority held by an order** (its ETH, its escrowed NFT, roles granted to it) is isolated. No other order, and no handler outside that order's fill, can use it.
2. **Approvals or permissions granted to an order by someone other than its owner** become the owner's once the order is closed: the owner can close and spend them before the granter's fill lands (finding A1). Grant authority only to orders you own.
3. **Approvals granted to a shared handler** (holders approve `NFTBid`, not a bid order) are shared across every order on that handler. `NFTBid` moves a token only in a genuine fill whose caller is the holder, but a bug in it, or anything able to make the holder's account call `fill`, reaches every approved token. See [docs/NFT_TRADING.md](docs/NFT_TRADING.md#what-an-approval-to-nftbid-authorizes).

## Reference implementations

| Contract | Kind | Purpose |
| --- | --- | --- |
| [`NFTSale`](handlers/NFTSale.sol) | Supported handler | Sell one escrowed ERC721 for ETH at a fixed, falling or rising price. Buyer sets a max price; seller caps the royalty share. |
| [`NFTBid`](handlers/NFTBid.sol) | Supported handler | Funded bid for one token or up to `maxFills` tokens of a collection, at a fixed, rising or falling price. Holders approve the handler; seller sets minimum proceeds. |
| [`NFTTrade`](handlers/NFTTrade.sol), [`HandlerBase`](handlers/HandlerBase.sol) | Shared bases | Fill authentication, linear price schedule, ERC2981 royalties (paid atomically, capped at price less fee), the up-to-1% fee read from `FeeConfig`, `ownerOf` delivery check; `execute` helpers. |
| [`FeeConfig`](handlers/FeeConfig.sol) | Shared fee terms | The recipient and rate both NFT handlers read on each fill. A separate admin sets the rate (at most 1%, locked per order at creation) and the changeable recipient. Market never calls it. |
| [`FillVerifier`](periphery/FillVerifier.sol) | Optional periphery | Lets a batching wallet revert its own fill unless it received what it expected. Market never calls it. |
| [`PaintAction`](examples/PaintAction.sol) + [`Artwork`](examples/Artwork.sol) | Example | A non-trading handler: sells one repaint of an artwork using a painter role the artwork contract grants the order, then resigns the role and closes. |
| [`CoveredNFTPurchase`](handlers/CoveredNFTPurchase.sol) | Supported exercise handler | Fully backed right to buy a specific NFT for fixed ETH; royalty recipient and amount commit at activation and proceeds become pull credits. |
| [`ReservedPaint`](examples/ReservedPaint.sol) + `Artwork` | Example exercise handler and target | One reserved artwork modification that survives artwork transfer until exercise, surrender or expiry. |

NFT trading semantics, lifecycle, compatibility with real collections and gas: [docs/NFT_TRADING.md](docs/NFT_TRADING.md). Composition: [test/Compose.t.sol](test/Compose.t.sol) settles a falling `NFTSale` against a rising `NFTBid` written by strangers, through an independent matcher, in one transaction.

## What Market guarantees, and what depends on the handler

| Guaranteed by `Market` and `Order` | Depends on the handler and other contracts |
| --- | --- |
| Terms never change: owner, handler, handler bytecode (checked every fill), config | What a fill does, costs and delivers |
| While active, only the handler can make the order act, and only during its fill | Whether the handler follows the rules above |
| A fill is atomic and cannot reenter the same order | Prices, limits, expiry, royalties |
| After `close`, no fills; the owner recovers without calling the handler | Behaviour of NFT collections, royalty receivers and other contracts called |
| One order's assets and approvals are unusable by any other order | Approvals given to a handler, or to an order by someone other than its owner |
| `Market` takes no fee and has no owner, registry or upgrade path | Whether a filler received what it expected (check it yourself, e.g. with `FillVerifier`) |

Threat model, residual risks and review findings: [docs/SECURITY.md](docs/SECURITY.md). Design decisions: [docs/DECISIONS.md](docs/DECISIONS.md).

## Usage

Requires [Foundry](https://getfoundry.sh). Dependencies are pinned submodules: forge-std v1.17.0 and OpenZeppelin Contracts v5.7.0 (the core uses only `Clones`).

```bash
git submodule update --init --recursive
```

```bash
forge build
```

```bash
forge test --no-match-path "test/fork/*"
```

```bash
forge test --match-path "test/fork/*" --isolate
```

Fork tests read `MAINNET_RPC_URL`, defaulting to `https://mainnet.gateway.tenderly.co`, and pin block 26,357,000. `script/Deploy.s.sol` deploys the supported contracts through the standard CREATE2 deployer; without `--broadcast` it only simulates. The local right demonstrations, historical Sepolia addresses and release boundaries are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Repository

```
src/        Market, Order, Right, Rights and handler interfaces: the core
handlers/   NFTSale, NFTBid, CoveredNFTPurchase, trading bases and FeeConfig
periphery/  FillVerifier.sol (optional)
examples/   PaintAction, ReservedPaint and Artwork
test/       unit, fuzz, invariant, composition, review PoCs and gas; test/fork: mainnet fork
script/     Deploy.s.sol, Lifecycle.s.sol, RightsLifecycle.s.sol, rehearse.sh
docs/       HANDLERS, SPEC, NFT_TRADING, DEPLOYMENT, SECURITY, DECISIONS, STATUS
```

## License

MIT, see [LICENSE](LICENSE).
