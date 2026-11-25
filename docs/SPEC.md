# Market specification

This is the normative description of the core in `src/`: cancelable orders and transferable execution rights. The README explains why it is shaped this way; [SECURITY.md](SECURITY.md) lists what is enforced and how it is tested. If this document and the code disagree, the code is what runs, and the disagreement is a bug to fix. The historical order rules below remain applicable to orders; the rights rules are separate.

## Terms

| Term | Meaning |
| --- | --- |
| Order | An ERC-1167 clone of the `Order` implementation, deployed by `Market`. One per commitment. Its address is the order's identity. |
| Implementation | The single `Order` contract that Market deploys in its constructor. Every order runs its code; it is never an order itself. |
| Owner | The account that called `Market.create`. Fixed. |
| OrderHandler (handler) | The `IOrderHandler` contract bound to the order. Fixed, together with its code hash. Defines what a fill does; may serve many orders. |
| Config | Opaque bytes the handler interprets. The order stores only `keccak256(config)`. |
| Terms | Owner, handler, handler code hash and config hash. Appended to the order's code at deployment. |
| Input | Opaque bytes supplied by the filler on each fill. Untrusted. |
| Fill | One actual execution of an order: one call to `Order.fill`. The handler runs inside it. |
| Filling | The interval during which an order's `fill` is executing. Tracked in the order's transient storage. |
| Active | The state of every order from deployment until it is closed. |
| Closed | A permanent flag in the order's storage. A closed order accepts no fills, and only its owner can make it act. |

Identity, lifetime and executions are separate:

1. **Order identity** is the address, which commits to the implementation, owner, handler, handler code hash, config hash and salt.
2. **Order lifetime** runs from deployment until the owner or the order itself calls `close`, or forever. A handler may also make further fills fail (expiry, inventory, rules) without closing.
3. **An execution** is one successful fill, identified by its transaction and the order's `Filled` log. Market keeps no fill counter or nonce. A handler that needs one, or that must reject repeated or replayed requests (for example signed vouchers), keeps its own, keyed by order.

## Market

```solidity
address public immutable implementation;
mapping(Order order => uint256) public createdAt;
function create(IOrderHandler handler, bytes calldata config, bytes32 salt) external payable returns (Order);
function orderAddress(address owner, IOrderHandler handler, bytes32 configHash, bytes32 salt) external view returns (address);
event Created(Order indexed order, address indexed owner, IOrderHandler indexed handler, bytes32 salt, bytes config);
```

`implementation` is `new Order()`, created in Market's constructor. Market has no function that changes it.

`createdAt[order]` is the timestamp of the block in which `create` deployed `order`, and 0 for any account Market did not deploy. A handler can read it to apply the terms in force when an order was created; the reference handlers' shared `FeeConfig` uses it to date each order's fee rate (D306, D307, D309). Market stores it and nothing else about the order; it still takes no fee and has no owner or admin.

`create`:

1. Reverts `NoHandlerCode` if `handler` has no code.
2. Reverts `DelegatedHandler` if `handler`'s code is an EIP-7702 delegation designator (23 bytes beginning `0xef0100`).
3. Deploys, with CREATE2 and `salt`, an ERC-1167 clone of `implementation` whose runtime code is the 45-byte proxy followed by the 104-byte terms `abi.encodePacked(msg.sender, handler, handler.codehash, keccak256(config))`, sending it `msg.value`. Reverts if that address already has code (the same terms and salt were used before).
4. Records `createdAt[order] = block.timestamp`.
5. Emits `Created` with the full config, so the order can be rebuilt and filled from the log alone.

There is no initialization step. The terms exist from the moment the clone's code does.

`orderAddress` returns `create`'s deployment address for the given values while `handler` has its current code: the CREATE2 address over the clone's creation code (OpenZeppelin `Clones.predictDeterministicAddressWithImmutableArgs`). If the handler is not deployed yet, its code hash differs and so does the address.

Market also creates canonical `Rights` and the `Right` implementation and records genuine right accounts, as specified below. It forwards creation value to the new account. It has no administrative asset withdrawal path; forced or accidental assets at the factory are not automatically forwarded.

## Order

```solidity
bool public closed;
bool public transient filling;
function owner() external view returns (address);
function handler() external view returns (IOrderHandler);
function handlerCodehash() external view returns (bytes32);
function configHash() external view returns (bytes32);

function fill(bytes calldata config, bytes calldata input) external payable returns (bytes memory result);
function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret);
function close() external;
receive() external payable;
function onERC721Received(...) external view returns (bytes4);
function onERC1155Received(...) external view returns (bytes4);
function onERC1155BatchReceived(...) external view returns (bytes4);

event Filled(address indexed caller, uint256 value);
event Closed();
```

Each order is its own account. Its address, ETH, token balances, approvals and roles in other contracts, `closed` and `filling` belong to it alone. Only the code is shared, by `delegatecall` from the proxy to the fixed implementation.

### Terms

`owner`, `handler`, `handlerCodehash` and `configHash` read the order's terms from its own code with `extcodecopy(address(), 45 + offset, 32)` at offsets 0, 20, 40 and 72. Code cannot change, so neither can they.

### The implementation

Every entry point, including `receive` and the token hooks, reverts `NotAnOrder` when `address(this)` is the implementation. The implementation therefore has no terms, cannot be filled, executed or closed, and refuses ETH and safe token transfers. It contains no `DELEGATECALL` or `SELFDESTRUCT`, so nothing can replace the code orders run.

### `fill(config, input)`

In order:

1. Revert `OrderClosed` if `closed`.
2. Revert `Reentrant` if `filling`.
3. Revert `WrongConfig` if `keccak256(config) != configHash`.
4. Revert `HandlerCodeChanged` if `handler.codehash != handlerCodehash`.
5. Set `filling = true`.
6. Call `handler.onFill(msg.sender, msg.value, config, input)` with all available gas. A revert propagates.
7. Set `filling = false`, emit `Filled(msg.sender, msg.value)` and return the handler's result.

ETH sent with `fill` is held by the order before step 6.

### Authority lifecycle

| State | Who may `execute` | Who may `close` |
| --- | --- | --- |
| Active, outside a fill | Nobody | The owner |
| Active, during its fill | The handler | The order itself (the handler, through `execute`) |
| Closed, during the fill that closed it | The handler | The order itself (no effect) |
| Closed, outside a fill | The owner | The owner (no effect) |

A closed order cannot start a fill, so the third row exists only between a handler closing its order and that fill returning. In that window `filling` is true although the order is closed: an external contract that gates on `filling()` should treat it as "the handler is acting", not as "the order is active".

### `execute(target, value, data)`

1. If `filling`, revert `Unauthorized` unless `msg.sender == handler`. Otherwise revert `Unauthorized` unless `closed` and `msg.sender == owner`.
2. Call `target` with `value` and `data`. If the call fails, revert with its return data. Otherwise return its return data.

There is exactly one way to make an order act, and at most one party allowed to use it at any moment: the handler during a fill, the owner of a closed order otherwise, and nobody while an active order is idle.

### `close()`

If `filling`, reverts `Unauthorized` unless `msg.sender` is the order itself. Otherwise reverts `Unauthorized` unless `msg.sender` is `owner`. Sets `closed = true` and emits `Closed`. Idempotent. Permanent.

The self case is how a handler ends a single use order: during a fill it calls `execute(order, 0, close())`. The owner cannot close an order while it is being filled, for example from a receive hook triggered by the fill. A handler that closes mid-fill keeps `execute` until the fill returns; the owner gains it only then.

Closing stops fills and hands `execute` to the owner, nothing else. Approvals, roles and grants the order holds in other contracts stay in place until the owner revokes them with `execute`, or the handler or the other contract removes them. Closing does not make the order's former capabilities exclusive to anyone.

An active order commits the authority it holds to its handler: only fills can move it. That is not a guarantee that the order is funded, that its handler is correct, or that permissions granted to it by others (approvals, roles, grants) will not be revoked or changed by their grantors.

### Receiving

`receive` accepts ETH from anyone at any time. The three token hooks return their selectors so ERC721 and ERC1155 safe transfers can deliver to an order. There is no generic fallback, deliberately: a fallback that echoes selectors would make `isValidSignature` "succeed" and let signature-based protocols treat an order as having signed anything.

## IOrderHandler

```solidity
function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
    external returns (bytes memory result);
```

`msg.sender` is the order. `caller` is whoever called `fill`. `value` is the ETH sent with the fill, already in the order. `config` matches the order's commitment. `input` is whatever the caller sent.

The handler may call `Order(msg.sender).execute` any number of times before returning. Revert to reject the fill.

One handler may serve many orders. It can act through an order only while that order is filling. If fills nest (during order A's fill, the handler or someone it calls fills order B, also bound to it), both orders accept the handler until their fills return: the core cannot tell which order a shared handler is acting for, so a handler keeps orders apart by acting only through `msg.sender` and keying state by it.

Requirements on handlers are not enforced by Market; they are listed in the README under "Rules for handler authors". The two that matter most: act only through the calling order, and take only from `caller`. The code-hash check fixes the handler's bytecode, not its behaviour: what a handler does may still depend on its storage and on other contracts it calls.

## Events for discovery

To find orders: index `Market.Created`. To follow an order: index its `Filled` and `Closed` events and whatever its handler emits. Events emitted by a handler name the order as `msg.sender`, so a fake order calling a handler directly can only produce events about itself. Anyone can deploy a clone of the implementation outside Market with arbitrary terms; check that an order address came from `Market.Created` (or equals `orderAddress` for its terms) before trusting it or handler events about it.

## Periphery: FillVerifier

[`periphery/FillVerifier.sol`](../periphery/FillVerifier.sol) is optional. Market and Order never call it.

```solidity
function snapshot(address target, bytes calldata query) external;
function requireIncrease(address target, bytes calldata query, uint256 minimum) external;
function requireEqual(address target, bytes calldata query, bytes calldata expected) external view;
function ethBalance(address account) external view returns (uint256);
```

`snapshot` staticcalls `target` with `query`, requires exactly 32 bytes back, and stores the value in transient storage under `keccak256(abi.encode(msg.sender, target, query))`. `requireIncrease` reverts `NoSnapshot` unless the caller took that snapshot earlier in the same transaction and has not used it yet, and `TooLittle` unless the value is now at least `minimum` higher. It uses the snapshot up, so each check needs its own snapshot. `requireEqual` reverts `Mismatch` unless the staticcall returns exactly `expected`. A failed or malformed query reverts `QueryFailed`. The contract holds nothing, has no owner and makes no state-changing calls.

## Rights: a separate protocol object

`Market.createRight(handler, config, deadline, residual, salt)` deploys an isolated `Right` clone and marks it as Market-created. Its immutable arguments bind the issuer (`msg.sender`), handler address and code hash, config hash, deadline and residual beneficiary. `Market.rightAddress(...)` predicts the account address with those same values. Any ETH sent with creation goes to that account. The full config appears in `RightCreated`. There is no mutable holder field or setup initializer.

`Rights` is the single canonical ERC721 created by Market. A right's token ID is the backing account's address cast to `uint256`; `Rights.accountOf(id)` authenticates Market creation. The account alone mints after validated activation and burns on termination. Mint happens once. `ownerOf(id)` is the sole exercise authority, and standard ERC721 approvals can transfer the token but do not authorize `Right.exercise`. A transfer to the token's own backing account is rejected. Other custody cycles involving contracts that own each other's tokens are unsupported.

| State | How reached | What may follow | Account execution |
| --- | --- | --- | --- |
| Pending | Creation | Issuer activates after handler validation before deadline, permanently cancels setup, or anyone finalizes at deadline | None; assets enter from outside |
| Active | Activation stores effective terms, mints token to issuer | Holder exercises or surrenders; anyone finalizes at deadline | Bound handler, only inside this account's exercise |
| Exercised | Handler succeeds; token burns | Terminal recovery and beneficiary credit withdrawal | Residual beneficiary may recover free assets |
| Expired | Anyone finalizes pending or active setup at or after deadline; an active token burns | Terminal recovery and credit withdrawal | Same |
| Surrendered | Holder surrenders; token burns | Terminal recovery and credit withdrawal | Same |
| Canceled | Issuer cancels pending setup | Terminal recovery | Same |

`activate(config)` is issuer-only. It checks the immutable config hash, handler code hash and deadline, asks the handler's read-only `validate(account, config)` to check its specific backing, stores the returned activation terms, then mints. There is no generic pending account execution, so setup cannot plant an account-originated approval that survives activation. A canceled or expired pending account cannot activate. Anyone can finalize a pending setup after its deadline, allowing committed residual recovery without the issuer. A permissionless handler may still validate poorly, depend on mutable contracts or act maliciously; core validation is not a certification of arbitrary handlers.

`exercise(config, input)` is payable and current-token-owner-only. The core checks active state, `block.timestamp < deadline` (unless deadline is zero), config, bound handler code and local execution lock. It snapshots the authenticated holder, then calls `onExercise(holder, value, config, activationTerms, input)`. Only that handler may call the account's `execute` or `credit` during this window. On success the account marks itself Exercised and burns the token. Any revert rolls back the operation, payment accounting and burn. The local lock blocks same-account reentrant exercise, token transfer, surrender, expiry finalization, recovery and credit withdrawal while leaving distinct accounts composable. Handler input is untrusted; each handler constructs its own target calls and verifies the delivered state.

The same deadline boundary applies to transfer, supported trading quotes, exercise and expiry finalization: at `block.timestamp >= deadline`, no live sale or exercise can settle, even before anyone finalizes. Deadline zero means perpetual commitment with no issuer escape. Surrender is a holder action; issuer status alone gives no shortcut. An issuer who buys back the token may surrender as its current holder.

`credit(beneficiary, amount)` reserves account ETH for a beneficiary during exercise. The sum of outstanding credits is `totalCredits`. Neither handler execution nor terminal recovery may send ETH that would dip into this reserve. Anyone calls `releaseCredit(beneficiary)` to pay that recorded beneficiary without redirection. The beneficiary alone calls `withdrawCredit(recipient)` to choose another destination; this works independently of lifecycle, including after residual recovery. A rejecting beneficiary cannot veto exercise because exercise records a credit instead of calling it. The residual beneficiary's `recover(target, value, data)` works after every terminal state without calling the handler and can recover NFT collateral, unused funds and accidental deposits, subject to the ETH reserve. The core cannot automatically revoke outside permissions; supported integrations consume or disable their grants.

The holder and residual beneficiary are independent core roles and may be the same address for a general handler. A holder has no active-account recovery power. The supported covered NFT handler narrows this: at activation it requires `right.residual() == right.issuer()`, both authenticated immutable account arguments. A buyer who surrenders or waits until expiry loses the token and cannot recover the NFT. The issuer can recover after termination, including when it surrenders an unsold or bought-back token. Surrender and expiry do not collect exercise price or allocate exercise royalty. Both payout paths debit the credit before the ETH call and revert that debit if payment fails. A failed payout does not affect the completed exercise. A beneficiary that both refuses ETH and cannot initiate withdrawal to another destination retains an uncollectible reserved credit.

This handler check does not rewrite a pending account's creation terms. A funded account with a non-issuer residual cannot activate into a covered right, but after issuer cancellation or expiry finalization its named residual beneficiary can recover the deposit. No token is minted. The issuer must check pending terms before transferring collateral into the account.

The reference covered NFT purchase handler checks issuer-only residual and `ownerOf(tokenId) == rightAccount` before activation; its activation terms fix the ERC2981 recipient and amount subject to the issuer's limit. Exercise requires exact fixed ETH payment, transfers the NFT from the account to an allowed recipient, checks `ownerOf` afterwards, then credits royalty and remaining proceeds. It never reads mutable royalty settings or trading `FeeConfig` during exercise. The reference artwork target enforces a durable reservation through its own permission rules, including after artwork transfer. The right permits one allowed modification; it does not promise the artwork's final color will persist.

`NFTSale` may escrow and resell a live right token without moving its backing. Its seller owns only that listing; `Order.close` cancels the listing and permits token recovery, leaving the right untouched. A live listing's order is the token's actual holder. `NFTBid` accepts only a specific token ID for the canonical rights collection; collection-wide bids are rejected. Normal NFT sale fee and royalty rules still govern the premium, but the rights collection advertises no ERC2981 royalty. The underlying NFT's committed royalty applies once to its exercise payment, not every premium resale. Trading order deadlines are separate from the immutable right deadline and should leave an exercise window.

`Rights.tokenURI(id)` returns Base64 JSON for an existing ownership token, with account identity, issuer, handler/code hash, config hash, activation terms, deadline policy, residual and effective liveness. Pending and burned tokens have no URI. At an exclusive deadline the token may still exist but the metadata reports expired and not live. It never calls the handler or underlying target.

## Toolchain

Solidity 0.8.30, EVM version Prague, optimizer 200 runs with via-IR (`foundry.toml`). The core uses transient storage (EIP-1153), so it needs Cancun or later; it also compiles with Solidity 0.8.28. Clone creation and address prediction use OpenZeppelin Contracts v5.7.0 `Clones`.

## Reservation authentication and token existence

`Artwork` is bound immutably to a configured Market supplied to its constructor. `reserve` checks that Market's `isRight(candidate)` before reading candidate state, and accepts only pending candidates. It does not trust a candidate's self-reported registry. Active unexpired reservations survive artwork transfers and cannot be replaced. Pending or terminal reservations can be replaced. `Artwork._live` deliberately recognizes the active reservation during exercise; `Right.isLive` returns false during the exercise lock to prevent token transfer.

`Rights` stores no historical mint flag or `everMinted` getter. Canonical account authentication, caller identity, permanent lifecycle transitions and ERC721 existence rules govern mint and burn. An expired account does not expose a separate boolean distinguishing expiry before issuance from expiry after issuance. Existing tokens, including expired tokens awaiting finalization, are inspected through ERC721 ownership; terminal history remains in events and the account state.
