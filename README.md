# Market

Market is a permissionless Ethereum protocol for trading authorized onchain executions.

Someone who can make something happen onchain (transfer an NFT, spend ETH, repaint an artwork, call any contract) turns that ability into an **order**: an independent account holding the authority, bound to code that says on what terms anyone may use it. Anyone can **fill** the order by meeting those terms. The execution and its payment settle in one transaction or not at all.

The core is two small contracts with no owner, no fees, no registry, no upgrade path and no knowledge of what is traded.

> **Status: experimental, unaudited.** Tests and automated reviews are evidence about tested behaviour, not a safety claim ([docs/STATUS.md](docs/STATUS.md), [docs/SECURITY.md](docs/SECURITY.md)). Nothing is deployed to mainnet.

## How it works

**Market creates orders. Orders hold authority. OrderHandlers define behavior. Fills execute that behavior.**

| Part | What it is |
| --- | --- |
| [`Market`](src/Market.sol) | Factory. `create(handler, config, salt)` deploys an order as a 149-byte ERC-1167 clone and emits `Created(order, owner, handler, salt, config)`. Holds nothing and calls nothing afterwards. |
| [`Order`](src/Order.sol) | One account per order, with its own ETH, tokens, approvals and roles. Its terms (owner, handler, handler code hash, config hash) are written into its code and address, so they never change. |
| OrderHandler | Any contract implementing [`IOrderHandler.onFill`](src/Order.sol). Decides what the order does in a fill and what the filler must give. One handler serves many orders, each with its own config. |
| Fill | `order.fill(config, input)`, by anyone. The order calls its handler, which makes the order act through `Order.execute`. Any revert undoes everything. |

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
(uint256 price,,) = nftSale.quote(c);
order.fill{value: price}(config, abi.encode(buyer, price)); // recipient, max price

// Seller, to cancel instead: close, then recover.
order.close();
order.execute(address(nft), 0, abi.encodeCall(IERC721.transferFrom, (address(order), seller, 7)));
```

`Market.orderAddress(owner, handler, keccak256(config), salt)` gives the address before creation, so assets can be sent first.

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
| [`NFTTrade`](handlers/NFTTrade.sol), [`HandlerBase`](handlers/HandlerBase.sol) | Shared bases | Fill authentication, linear price schedule, ERC2981 royalties (paid atomically, never skipped), `ownerOf` delivery check; `execute` helpers. |
| [`FillVerifier`](periphery/FillVerifier.sol) | Optional periphery | Lets a batching wallet revert its own fill unless it received what it expected. Market never calls it. |
| [`PaintAction`](examples/PaintAction.sol) + [`Artwork`](examples/Artwork.sol) | Example | A non-trading handler: sells one repaint of an artwork using a painter role the artwork contract grants the order, then resigns the role and closes. |

NFT trading semantics, lifecycle, compatibility with real collections and gas: [docs/NFT_TRADING.md](docs/NFT_TRADING.md). Composition: [test/Compose.t.sol](test/Compose.t.sol) settles a falling `NFTSale` against a rising `NFTBid` written by strangers, through an independent matcher, in one transaction.

## What Market guarantees, and what depends on the handler

| Guaranteed by `Market` and `Order` | Depends on the handler and other contracts |
| --- | --- |
| Terms never change: owner, handler, handler bytecode (checked every fill), config | What a fill does, costs and delivers |
| While active, only the handler can make the order act, and only during its fill | Whether the handler follows the rules above |
| A fill is atomic and cannot reenter the same order | Prices, limits, expiry, royalties |
| After `close`, no fills; the owner recovers without calling the handler | Behaviour of NFT collections, royalty receivers and other contracts called |
| One order's assets and approvals are unusable by any other order | Approvals given to a handler, or to an order by someone other than its owner |
| No fee, owner, registry or upgrade path | Whether a filler received what it expected (check it yourself, e.g. with `FillVerifier`) |

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

Fork tests read `MAINNET_RPC_URL`, defaulting to `https://mainnet.gateway.tenderly.co`, and pin block 26,357,000. `script/Deploy.s.sol` deploys the supported contracts through the standard CREATE2 deployer; without `--broadcast` it only simulates. Addresses, Sepolia commands and the release checklist: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Repository

```
src/        Market.sol, Order.sol (with IOrderHandler): the core
handlers/   NFTSale, NFTBid and their bases NFTTrade, HandlerBase
periphery/  FillVerifier.sol (optional)
examples/   PaintAction + Artwork
test/       unit, fuzz, invariant, composition, review PoCs and gas; test/fork: mainnet fork
script/     Deploy.s.sol, Lifecycle.s.sol, rehearse.sh
docs/       HANDLERS, SPEC, NFT_TRADING, DEPLOYMENT, SECURITY, DECISIONS, STATUS
```

## License

MIT, see [LICENSE](LICENSE).
