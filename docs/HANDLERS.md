# Building on Market

A guide for Solidity developers who want to write an OrderHandler, create orders, or fill orders they did not write. You need this page, [`src/Order.sol`](../src/Order.sol) and [`src/Market.sol`](../src/Market.sol) (206 lines together). The rest of the repository is examples and evidence.

> **Experimental, unaudited.** Read [SECURITY.md](SECURITY.md) before putting value in an order.

## The model

**Market creates orders. Orders hold authority. OrderHandlers define behavior. Fills execute that behavior.**

| Piece | What it is | You call |
| --- | --- | --- |
| `Market` | Factory. Deploys each order as a 149-byte clone and emits `Created(order, owner, handler, salt, config)`. Holds nothing, calls nothing afterwards. | `create(handler, config, salt)`, `orderAddress(owner, handler, keccak256(config), salt)` |
| `Order` | One account per commitment: its own address, ETH, tokens, approvals, roles and storage. Its terms (owner, handler, handler code hash, config hash) are part of its code and address. | `fill(config, input)`; owner: `close()`, then `execute(target, value, data)` |
| `IOrderHandler` | Your contract. `onFill(caller, value, config, input)` runs inside a fill and makes the order act through `Order(msg.sender).execute`. One handler serves many orders. | Nothing: the order calls it |
| Fill | One call to `order.fill`. Everything in it succeeds or everything reverts. | |

Who may make an order act:

| Order state | Who can call `execute` | Owner can |
| --- | --- | --- |
| Active, not filling | Nobody | `close()` |
| Active, filling | Only the handler | Nothing (the order refuses `close` and `execute` from the owner) |
| Closed | Only the owner, outside fills | `execute` anything as the order: withdraw, revoke |

## What Market guarantees, and what depends on the handler

| Guaranteed by Market and `Order` | Depends on the handler |
| --- | --- |
| The order's terms never change: same owner, handler, handler bytecode (checked on every fill) and config | What a fill does, what it costs and what it delivers |
| While active, nothing leaves the order except through its handler during a fill | Whether the handler takes only from `caller`, builds its own calls and keys state by order |
| Nobody, including the owner, can act as an active order outside a fill | Whether the price, limits and expiry are what you think they are |
| A fill is atomic and cannot reenter the same order | Whether nested fills of other orders on the same handler stay apart |
| After `close`, no more fills, and the owner can recover everything | Whether a single-use order closes itself after use |
| Each order's assets and approvals are usable by no other order | Whether external contracts the handler reads (prices, NFTs, royalty receivers) behave |
| Market takes no fee, has no owner and no registry | Any fee, split or royalty |

Market does not check that a fill gave the filler anything. That is the handler's promise, and a filler who does not trust the handler checks the result itself (see "Filling an order you did not write").

## Write a handler

Smallest complete example: sell the right to call `ring()` on a bell that lets only the order ring it.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderHandler, Order} from "market/src/Order.sol";

contract BellHandler is IOrderHandler {
    struct Config {
        address bell;
        uint256 fee;
        address payee;
    }

    function onFill(address, uint256 value, bytes calldata config, bytes calldata) external returns (bytes memory) {
        Config memory c = abi.decode(config, (Config));
        require(value == c.fee, "fee");
        Order(payable(msg.sender)).execute(c.bell, 0, abi.encodeWithSignature("ring()"));
        Order(payable(msg.sender)).execute(c.payee, value, "");
        return "";
    }
}
```

The order has already checked `config` against its commitment and already holds `value`. `msg.sender` is the order (or someone pretending to be one; see rule 1). The full test is [`test/NewOrderType.t.sol`](../test/NewOrderType.t.sol).

Inherit [`handlers/HandlerBase.sol`](../handlers/HandlerBase.sol) for `_exec` (one call as the order), `_sendETH`, `_tokenCall` (ERC20 calls that tolerate missing return values and reject `false`), `_pay` (basis-point split) and `_close`.

### Rules

1. **Act only through the calling order.** Hold no assets, approvals or roles in the handler: anyone can call `onFill` directly. Exception: a handler that must pull a filler's assets may hold the filler's approval if it first proves `msg.sender` is a genuine, filling `Order` clone bound to it, as [`NFTBid`](../handlers/NFTBid.sol) does in `_isOrder`.
2. **Take only from `caller`, never under an approval to the order.** An approval a filler gives the order is also the owner's after closing: the owner can close and spend it before the filler's fill lands (SECURITY.md, A1). Have fillers send ETH with the fill, or approve the handler under rule 1's exception.
3. **Build every call yourself.** Never pass a target or calldata from `input` to `execute`.
4. **Use `value` for this fill's ETH**, not the order's balance.
5. **Key state by `msg.sender`** and write it before external calls. Nested fills of other orders on your handler are allowed by the core; this rule is what keeps them apart.
6. **Verify by state**: `ownerOf` or balances before and after, not return values.
7. **End single-use orders**: close in the fill (`_close()`), first if you can, and consume or return any permission the order held.
8. **Stay immutable**: no owner, proxy, `delegatecall` or switches. Market pins the handler's bytecode, not the state or contracts it reads; every external contract you call is part of your trust surface.
9. **Expose a quote view** so fillers see current terms without simulating.
10. **Give fillers limits**: a maximum price, a minimum received, a deadline, whatever bounds a stale quote.

### Test it

Use Foundry with the repository's helpers, or your own:

```solidity
Market market = new Market();
BellHandler bells = new BellHandler();
Bell bell = new Bell();

vm.prank(creator);
Order order = market.create(bells, abi.encode(BellHandler.Config(address(bell), 0.01 ether, creator)), bytes32(0));
bell.setRinger(address(order)); // the permission the order holds

vm.prank(filler);
order.fill{value: 0.01 ether}(config, "");
```

Test at least: the happy path, every revert, a direct call to `onFill`, a second fill, the owner trying to act while active, `close` and recovery, and a hostile counterparty (a recipient that reverts or reenters). The NFT handler tests ([`test/NFTSale.t.sol`](../test/NFTSale.t.sol), [`test/NFTBid.t.sol`](../test/NFTBid.t.sol)) show each.

### Deploy it

Handlers need no registration. Deploy with any method; for the same address on every chain, deploy through the standard CREATE2 deployer as [`script/Deploy.s.sol`](../script/Deploy.s.sol) does. Deploy before anyone predicts an order address for it: `orderAddress` uses the handler's current code hash.

## Use Market from another project

```bash
forge install ripe0x/market
```

Remapping: `market/=lib/market/`. Import `market/src/Order.sol` for `IOrderHandler` and `Order`, `market/src/Market.sol` for `Market`, and `market/handlers/HandlerBase.sol` if you want the helpers. The core needs OpenZeppelin Contracts v5 (`Clones`).

Deployed addresses for each chain are in [DEPLOYMENT.md](DEPLOYMENT.md).

## Create, fund, fill and cancel without a frontend

With `cast`, using the reference sale handler. Replace the addresses with those for your chain; `$ME` is your account and signing flags (`--account <keystore>`) are omitted.

```bash
SALT=0x0000000000000000000000000000000000000000000000000000000000000001
START=$(cast block latest -f timestamp); END=$((START + 86400))
SALE_T="(address,uint256,(uint256,uint256,uint256,uint256,uint256),address,uint16)"
TERMS="($NFT,$ID,(1000000000000000000,100000000000000000,$START,$END,0),$ME,1000)"  # 1 ETH falling to 0.1 over a day, 10% royalty cap
CONFIG=$(cast abi-encode "f($SALE_T)" "$TERMS")

# Seller: create the order, then escrow the token
cast send $MARKET "create(address,bytes,bytes32)" $NFT_SALE $CONFIG $SALT
ORDER=$(cast call $MARKET "orderAddress(address,address,bytes32,bytes32)(address)" $ME $NFT_SALE $(cast keccak $CONFIG) $SALT)
cast send $NFT "transferFrom(address,address,uint256)" $ME $ORDER $ID

# Anyone: quote, then fill (input: recipient, maxPrice)
PRICE=$(cast call $NFT_SALE "quote($SALE_T)(uint256,address,uint256)" "$TERMS" | head -1 | awk '{print $1}')
cast send $ORDER "fill(bytes,bytes)" $CONFIG $(cast abi-encode "f(address,uint256)" $BUYER $PRICE) --value $PRICE

# Seller, instead of a sale: cancel and recover
cast send $ORDER "close()"
cast send $ORDER "execute(address,uint256,bytes)" $NFT 0 $(cast calldata "transferFrom(address,address,uint256)" $ORDER $ME $ID)
```

The create, escrow, quote and fill steps above were run as written against a local anvil deployment (2026-11-06).

Fill inputs are always `abi.encode` of the handler's documented tuple. The full flow in Solidity, including a persistent bid and the PaintAction example, is [`script/Lifecycle.s.sol`](../script/Lifecycle.s.sol); [`script/rehearse.sh`](../script/rehearse.sh) runs it on a fork.

To discover orders, read `Market.Created` logs: they carry the owner, handler, salt and full config. Decode the config with the handler's ABI. No indexer is required.

## A complete non-NFT example: selling one repaint of an artwork

[`examples/Artwork.sol`](../examples/Artwork.sol) is an ordinary ERC721 that knows nothing about Market. Each token has a color. Its owner can paint it and can name one **painter** who may paint it too. A painter can resign; any transfer clears the painter.

[`examples/PaintAction.sol`](../examples/PaintAction.sol) sells one repaint:

```solidity
struct Config {
    Artwork art;
    uint256 tokenId;
    uint256 allowedColors; // bit i set: color i allowed
    uint256 price;
    Payee[] payees;
}
// input: abi.encode(uint8 color)
```

The lifecycle, with the permission held by the order and granted by an independent contract:

1. The token's owner creates an order: `market.create(paintAction, config, salt)`.
2. The owner grants the permission: `art.setPainter(tokenId, order)`. The order now holds the right to paint, and only the order.
3. Anyone fills with a color and the price: `order.fill{value: price}(config, abi.encode(color))`. `PaintAction` checks the color and payment, makes the order call `art.paint(tokenId, color)`, then `art.resign(tokenId)` so the permission cannot be used again, pays the payees, refunds the excess and closes the order.
4. If nobody buys, the owner closes the order and takes the permission back: `order.close()`, then `order.execute(art, 0, resign(tokenId))`, or simply calls `art.setPainter` again from the token.

Nothing in Market knows what an artwork, a color or a painter is. The same `Market` and `Order` that escrow an NFT for `NFTSale` here hold a role in another contract, and the same lifecycle rules decide who can use it. Tests: [`test/PaintAction.t.sol`](../test/PaintAction.t.sol) (11 tests, including that the role is consumed after one paint, that a transfer of the token makes the offer stale, that closing leaves the role until revoked, and that the creator can revoke without touching the order). Real transactions: the `paint` step of [`script/Lifecycle.s.sol`](../script/Lifecycle.s.sol).

## Filling an order you did not write

1. **Read the order's terms**: `order.handler()`, `order.handlerCodehash()` (compare with the handler's current `codehash`), `order.configHash()` (compare with `keccak256` of the config from `Created`), `order.closed()`.
2. **Read the handler.** Its code is fixed, but check what it reads: owners, proxies, external price or capital contracts can still change its behaviour.
3. **Quote, then bound.** Use the handler's quote view and pass its limits (maximum price, minimum proceeds) in `input`.
4. **Check your receipt atomically if you do not trust the handler.** From a contract or a batching wallet (EIP-5792, EIP-7702), snapshot what you expect to receive, fill, and require the increase in the same transaction with [`periphery/FillVerifier.sol`](../periphery/FillVerifier.sol). If the check fails, the fill and its payment revert.
5. **Never approve someone else's order.** Approve a handler only if you have read it and it authenticates orders as `NFTBid` does.
6. **Do not send ETH or tokens to an order or a handler** except as the handler documents.
