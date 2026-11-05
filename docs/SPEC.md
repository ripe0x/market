# Market specification

This is the normative description of the core in `src/`. The README explains why it is shaped this way; [SECURITY.md](SECURITY.md) lists what is enforced and how it is tested. If this document and the code disagree, the code is what runs, and the disagreement is a bug to fix.

## Terms

| Term | Meaning |
| --- | --- |
| Order | An `Order` contract. One per commitment. Its address is the order's identity. |
| Owner | The account that called `Market.create`. Immutable. |
| Policy | The `IPolicy` contract bound to the order. Immutable. |
| Config | Opaque bytes the policy interprets. The order stores only `keccak256(config)`. |
| Input | Opaque bytes supplied by the filler on each fill. Untrusted. |
| Fill | One call to `Order.fill`. The policy runs inside it. |
| Filling | The interval during which an order's `fill` is executing. Tracked in transient storage. |
| Closed | A permanent flag. A closed order accepts no fills. |

Identity, lifetime and executions are separate:

1. **Order identity** is the address, which commits to owner, policy, config hash and salt.
2. **Order lifetime** runs from deployment until the owner or the order itself calls `close`, or forever. A policy may also make further fills fail (expiry, inventory, rules) without closing.
3. **An execution** is one successful fill, identified by its transaction and the order's `Filled` log. Market keeps no fill counter; a policy that needs one keeps it, keyed by order.

## Market

```solidity
function create(IPolicy policy, bytes calldata config, bytes32 salt) external payable returns (Order);
function orderAddress(address owner, IPolicy policy, bytes32 configHash, bytes32 salt) external view returns (address);
event Created(Order indexed order, address indexed owner, IPolicy indexed policy, bytes32 salt, bytes config);
```

`create`:

1. Reverts `NoPolicyCode` if `policy` has no code.
2. Deploys `new Order{salt: salt, value: msg.value}(msg.sender, policy, keccak256(config))`. Reverts if that address already has code (the same owner, policy, config and salt were used before).
3. Emits `Created` with the full config, so the order can be rebuilt and filled from the log alone.

`orderAddress` returns `create`'s deployment address for the given values: the CREATE2 address over `type(Order).creationCode ++ abi.encode(owner, policy, configHash)`.

Market has no other state or functions. It never calls a policy or an order after deployment.

## Order

```solidity
address public immutable owner;
IPolicy public immutable policy;
bytes32 public immutable configHash;
bool public closed;
bool public transient filling;

function fill(bytes calldata config, bytes calldata input) external payable returns (bytes memory result);
function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret);
function close() external;
receive() external payable;
function onERC721Received(...) external pure returns (bytes4);
function onERC1155Received(...) external pure returns (bytes4);
function onERC1155BatchReceived(...) external pure returns (bytes4);

event Filled(address indexed caller, uint256 value);
event Closed();
```

### `fill(config, input)`

In order:

1. Revert `OrderClosed` if `closed`.
2. Revert `Reentrant` if `filling`.
3. Revert `WrongConfig` if `keccak256(config) != configHash`.
4. Set `filling = true`.
5. Call `policy.onFill(msg.sender, msg.value, config, input)` with all available gas. A revert propagates.
6. Set `filling = false`, emit `Filled(msg.sender, msg.value)` and return the policy's result.

ETH sent with `fill` is held by the order before step 5.

### `execute(target, value, data)`

1. If `filling`, revert `Unauthorized` unless `msg.sender == policy`. Otherwise revert `Unauthorized` unless `msg.sender == owner`.
2. Call `target` with `value` and `data`. If the call fails, revert with its return data. Otherwise return its return data.

There is exactly one way to make an order act, and exactly one party allowed to use it at any moment.

### `close()`

Reverts `Unauthorized` unless `msg.sender` is `owner` or the order itself. Sets `closed = true` and emits `Closed`. Idempotent. Allowed during a fill.

The self case exists so a policy can end a single use order: during a fill the policy calls `execute(order, 0, close())`.

### Receiving

`receive` accepts ETH from anyone at any time. The three token hooks return their selectors so ERC721 and ERC1155 safe transfers can deliver to an order. There is no generic fallback, deliberately: a fallback that echoes selectors would make `isValidSignature` "succeed" and let signature-based protocols treat an order as having signed anything.

## IPolicy

```solidity
function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
    external returns (bytes memory result);
```

`msg.sender` is the order. `caller` is whoever called `fill`. `value` is the ETH sent with the fill, already in the order. `config` matches the order's commitment. `input` is whatever the caller sent.

The policy may call `Order(msg.sender).execute` any number of times before returning. Revert to reject the fill.

Requirements on policies are not enforced by Market; they are listed in the README under "Rules for policy authors". The two that matter most: act only through the calling order, and take only from `caller`.

## Events for discovery

To find orders: index `Market.Created`. To follow an order: index its `Filled` and `Closed` events and whatever its policy emits. Events emitted by a policy name the order as `msg.sender`, so a fake order calling a policy directly can only produce events about itself; check that an order address came from `Market.Created` before trusting policy events about it.

## Toolchain

Solidity 0.8.30, EVM version Prague, optimizer 200 runs with via-IR (`foundry.toml`). The core uses transient storage (EIP-1153), so it needs Cancun or later.
