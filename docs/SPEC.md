# Market specification

This is the normative description of the core in `src/`. The README explains why it is shaped this way; [SECURITY.md](SECURITY.md) lists what is enforced and how it is tested. If this document and the code disagree, the code is what runs, and the disagreement is a bug to fix.

## Terms

| Term | Meaning |
| --- | --- |
| Order | An ERC-1167 clone of the `Order` implementation, deployed by `Market`. One per commitment. Its address is the order's identity. |
| Implementation | The single `Order` contract that Market deploys in its constructor. Every order runs its code; it is never an order itself. |
| Owner | The account that called `Market.create`. Fixed. |
| Policy | The `IPolicy` contract bound to the order. Fixed, together with its code hash. |
| Config | Opaque bytes the policy interprets. The order stores only `keccak256(config)`. |
| Terms | Owner, policy, policy code hash and config hash. Appended to the order's code at deployment. |
| Input | Opaque bytes supplied by the filler on each fill. Untrusted. |
| Fill | One call to `Order.fill`. The policy runs inside it. |
| Filling | The interval during which an order's `fill` is executing. Tracked in the order's transient storage. |
| Closed | A permanent flag in the order's storage. A closed order accepts no fills. |

Identity, lifetime and executions are separate:

1. **Order identity** is the address, which commits to the implementation, owner, policy, policy code hash, config hash and salt.
2. **Order lifetime** runs from deployment until the owner or the order itself calls `close`, or forever. A policy may also make further fills fail (expiry, inventory, rules) without closing.
3. **An execution** is one successful fill, identified by its transaction and the order's `Filled` log. Market keeps no fill counter or nonce. A policy that needs one, or that must reject repeated or replayed requests (for example signed vouchers), keeps its own, keyed by order.

## Market

```solidity
address public immutable implementation;
function create(IPolicy policy, bytes calldata config, bytes32 salt) external payable returns (Order);
function orderAddress(address owner, IPolicy policy, bytes32 configHash, bytes32 salt) external view returns (address);
event Created(Order indexed order, address indexed owner, IPolicy indexed policy, bytes32 salt, bytes config);
```

`implementation` is `new Order()`, created in Market's constructor. Market has no function that changes it.

`create`:

1. Reverts `NoPolicyCode` if `policy` has no code.
2. Reverts `DelegatedPolicy` if `policy`'s code is an EIP-7702 delegation designator (23 bytes beginning `0xef0100`).
3. Deploys, with CREATE2 and `salt`, an ERC-1167 clone of `implementation` whose runtime code is the 45-byte proxy followed by the 104-byte terms `abi.encodePacked(msg.sender, policy, policy.codehash, keccak256(config))`, sending it `msg.value`. Reverts if that address already has code (the same terms and salt were used before).
4. Emits `Created` with the full config, so the order can be rebuilt and filled from the log alone.

There is no initialization step. The terms exist from the moment the clone's code does.

`orderAddress` returns `create`'s deployment address for the given values while `policy` has its current code: the CREATE2 address over the clone's creation code (OpenZeppelin `Clones.predictDeterministicAddressWithImmutableArgs`). If the policy is not deployed yet, its code hash differs and so does the address.

Market has no other state or functions. It never calls a policy or an order after deployment.

## Order

```solidity
bool public closed;
bool public transient filling;
function owner() external view returns (address);
function policy() external view returns (IPolicy);
function policyCodehash() external view returns (bytes32);
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

`owner`, `policy`, `policyCodehash` and `configHash` read the order's terms from its own code with `extcodecopy(address(), 45 + offset, 32)` at offsets 0, 20, 40 and 72. Code cannot change, so neither can they.

### The implementation

Every entry point, including `receive` and the token hooks, reverts `NotAnOrder` when `address(this)` is the implementation. The implementation therefore has no terms, cannot be filled, executed or closed, and refuses ETH and safe token transfers. It contains no `DELEGATECALL` or `SELFDESTRUCT`, so nothing can replace the code orders run.

### `fill(config, input)`

In order:

1. Revert `OrderClosed` if `closed`.
2. Revert `Reentrant` if `filling`.
3. Revert `WrongConfig` if `keccak256(config) != configHash`.
4. Revert `PolicyCodeChanged` if `policy.codehash != policyCodehash`.
5. Set `filling = true`.
6. Call `policy.onFill(msg.sender, msg.value, config, input)` with all available gas. A revert propagates.
7. Set `filling = false`, emit `Filled(msg.sender, msg.value)` and return the policy's result.

ETH sent with `fill` is held by the order before step 6.

### `execute(target, value, data)`

1. If `filling`, revert `Unauthorized` unless `msg.sender == policy`. Otherwise revert `Unauthorized` unless `msg.sender == owner`.
2. Call `target` with `value` and `data`. If the call fails, revert with its return data. Otherwise return its return data.

There is exactly one way to make an order act, and exactly one party allowed to use it at any moment.

### `close()`

Reverts `Unauthorized` unless `msg.sender` is `owner` or the order itself. Sets `closed = true` and emits `Closed`. Idempotent. Allowed during a fill.

The self case exists so a policy can end a single use order: during a fill the policy calls `execute(order, 0, close())`.

Closing stops fills and nothing else. Approvals, roles and grants the order holds in other contracts stay in place until the owner revokes them with `execute`, or the policy or the other contract removes them. Closing does not make the order's former capabilities exclusive to anyone.

### Receiving

`receive` accepts ETH from anyone at any time. The three token hooks return their selectors so ERC721 and ERC1155 safe transfers can deliver to an order. There is no generic fallback, deliberately: a fallback that echoes selectors would make `isValidSignature` "succeed" and let signature-based protocols treat an order as having signed anything.

## IPolicy

```solidity
function onFill(address caller, uint256 value, bytes calldata config, bytes calldata input)
    external returns (bytes memory result);
```

`msg.sender` is the order. `caller` is whoever called `fill`. `value` is the ETH sent with the fill, already in the order. `config` matches the order's commitment. `input` is whatever the caller sent.

The policy may call `Order(msg.sender).execute` any number of times before returning. Revert to reject the fill.

Requirements on policies are not enforced by Market; they are listed in the README under "Rules for policy authors". The two that matter most: act only through the calling order, and take only from `caller`. The code-hash check fixes the policy's bytecode, not its behaviour: what a policy does may still depend on its storage and on other contracts it calls.

## Events for discovery

To find orders: index `Market.Created`. To follow an order: index its `Filled` and `Closed` events and whatever its policy emits. Events emitted by a policy name the order as `msg.sender`, so a fake order calling a policy directly can only produce events about itself. Anyone can deploy a clone of the implementation outside Market with arbitrary terms; check that an order address came from `Market.Created` (or equals `orderAddress` for its terms) before trusting it or policy events about it.

## Periphery: FillVerifier

[`periphery/FillVerifier.sol`](../periphery/FillVerifier.sol) is optional. Market and Order never call it.

```solidity
function snapshot(address target, bytes calldata query) external;
function requireIncrease(address target, bytes calldata query, uint256 minimum) external;
function requireEqual(address target, bytes calldata query, bytes calldata expected) external view;
function ethBalance(address account) external view returns (uint256);
```

`snapshot` staticcalls `target` with `query`, requires exactly 32 bytes back, and stores the value in transient storage under `keccak256(abi.encode(msg.sender, target, query))`. `requireIncrease` reverts `NoSnapshot` unless the caller took that snapshot earlier in the same transaction and has not used it yet, and `TooLittle` unless the value is now at least `minimum` higher. It uses the snapshot up, so each check needs its own snapshot. `requireEqual` reverts `Mismatch` unless the staticcall returns exactly `expected`. A failed or malformed query reverts `QueryFailed`. The contract holds nothing, has no owner and makes no state-changing calls.

## Toolchain

Solidity 0.8.30, EVM version Prague, optimizer 200 runs with via-IR (`foundry.toml`). The core uses transient storage (EIP-1153), so it needs Cancun or later; it also compiles with Solidity 0.8.28. Clone creation and address prediction use OpenZeppelin Contracts v5.7.0 `Clones`.
