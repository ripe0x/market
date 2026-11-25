# Market specification

Market is a permissionless protocol for orders over authorized contract actions. The core is three contracts: `Market`, `Order` and `Actions`. Everything an order does is defined by an action implementation that obeys `IAction`. This document specifies the core. Action implementations are in [ACTIONS.md](ACTIONS.md); the threat model is in [SECURITY.md](SECURITY.md).

## Terms

| Term | Meaning |
| --- | --- |
| Order | An isolated account (ERC-1167 clone of the fixed `Order` implementation) for one action. |
| Action | A contract implementing `IAction`, shared by many orders. |
| Issuer | The account that called `Market.create`. |
| Admission | `Public`: any account the action accepts may execute, repeatedly until the action reports completion. `Holder`: only the current owner of the order's Actions token, in one call that must complete. |
| Deadline | Exclusive. At `block.timestamp >= deadline` execution and token transfer stop. Zero never expires. |
| Residual | The beneficiary of backing and native surplus once the order is not live. Never zero. |
| Activation terms | Bytes the action returns from `validate`, stored once at activation. |
| Credit | ETH inside an order reserved for a beneficiary. |

## Market

Immutable, no admin, no fee. Deploys `Actions` and the `Order` implementation in its constructor.

- `create(OrderSpec spec, bytes32 salt) payable`: validates and deploys a Pending order issued by `msg.sender`, forwarding `msg.value`. Sets `isOrder[order] = true` before any callback can run, then emits `Created(order, issuer, action, salt, spec)`.
  - Reverts `ZeroResidual` for a zero residual, `NoActionCode` for an action without code, `DelegatedAction` for an EIP-7702 delegation designator, `Clones.CloneArgumentsTooLong` for a config too long for clone code (limit 24,430 config bytes), and the clone's `FailedDeployment` if the address is taken.
- A deadline at or before now is accepted: the order is created Pending and expired, can never activate, and its residual can `release` backing that was sent to the predicted address early. No check in `create` depends on time or chain state, so a predicted address can always receive code.
- `createAndActivate(spec, salt) payable`: `create`, then activates that order. Backing must already be at the predicted address or be the ETH sent.
- `orderAddress(issuer, spec, salt) view`: the address `create` would deploy for `issuer` while the action has its current runtime code. It does not check the deadline.
- `isOrder(account)`: true only for orders this Market created.

`OrderSpec { address action; Admission admission; uint64 deadline; address residual; bytes config; }`

The address commits to the issuer, the action and its runtime code hash, admission, deadline, residual, the full config and the salt.

## Order

### Commitments

Read from the clone's own code: `issuer()`, `action()`, `actionCodehash()`, `admission()`, `deadline()`, `residual()`, `config()`, `tokenId()` (the order's address as a uint256). The code hash pins runtime bytecode only; it does not freeze a proxy's target, mutable storage, dependencies or privileges held elsewhere.

### State

`state()` is one of Pending, Live, Completed, Canceled, Expired, Surrendered. Pending and Live are the only non-terminal states; terminal states never change.

`phase()` (transient) is Idle, Activating, Executing, Releasing or Withdrawing. Every state-changing entrypoint requires Idle, so an order never runs two operations at once. Independent orders remain composable within one transaction.

Readable context: `actor()` (caller of the current execute or release), `suppliedValue()`, `releaseRecipient()`, `activationTerms()`, `creditOf(beneficiary)`, `totalCredits()`, `freeBalance()` (`balance - totalCredits`), `isExpired()`, `isLive()` (Live, Idle and unexpired), `previewActivation()` (advisory `validate` through the real account).

### Lifecycle

| Function | Caller | Allowed from | Effect |
| --- | --- | --- | --- |
| `activate()` | issuer, or Market inside `createAndActivate` | Pending, before deadline | `validate`, store terms, Live; a Holder order mints its token to the issuer without a receiver callback |
| `execute(input) payable` | Public: anyone. Holder: token owner | Live, before deadline | `onExecute`; `complete` ends the order as Completed and burns a Holder token; a Holder order reverts `Incomplete` otherwise |
| `cancel()` | issuer | Pending (either admission) or Live Public, before deadline | Canceled |
| `surrender()` | token owner | Live Holder, before deadline | Surrendered, burns |
| `finalizeExpiry()` | anyone | Pending or Live, finite deadline reached | Expired, burns a live Holder token |
| `release(recipient, input)` | anyone; only the residual may name a recipient other than itself | Pending or terminal | `onRelease`; backing cleanup |

An ERC721 operator approved for a Holder token cannot execute or surrender directly, but can transfer the token to itself and then act as owner.

After the deadline, `cancel` and `surrender` revert `DeadlinePassed` so that expiry is recorded as expiry.

### Action authority

- `call(target, value, data)`: only the bound action, only while Executing or Releasing. Releasing calls carry no ETH. `value` never exceeds `freeBalance()`.
- `credit(beneficiary, amount)`: only the bound action, only while Executing, `amount <= freeBalance()`.

Neither the issuer nor the residual can make arbitrary calls as the order.

### Withdrawals

- `releaseCredit(beneficiary)`: anyone pays a beneficiary its whole credit.
- `withdrawCredit(recipient)`: a beneficiary sends its own credit anywhere.
- `withdrawSurplus(recipient, amount)`: the residual takes free ETH while the order is not Live.

Each debits before the transfer, runs in phase Withdrawing and reverts on failure, restoring the liability. Credits survive every terminal state. An ETH transfer with empty calldata still calls the receiver with the order as `msg.sender`.

### Receiving

`receive()` accepts ETH at any time (bid funding). `onERC721Received` accepts ERC721s. The implementation itself rejects both.

## Actions

ERC721 named "Market Actions" (`ACTION`). Token id = order address, for Holder orders only.

- `mint(to, id)`: only the order, while Activating, once.
- `burn(id)`: only the order, once its state is terminal.
- Transfers require the order to be live (Live, Idle, unexpired) and reject the order itself as recipient.
- `orderOf(id)`, `isLive(id)`.
- `tokenURI(id)`: Base64 JSON from the order's commitments and state only: issuer, action, action code hash, config hash, activation terms hash, residual, deadline and status (live, busy or expired). No action or target is called.

## IAction

```solidity
interface IAction {
    function validate(address order, bytes calldata config) external view returns (bytes memory activationTerms);
    function onExecute(address actor, uint256 suppliedValue, bytes calldata config, bytes calldata activationTerms, bytes calldata input)
        external returns (bool complete, bytes memory result);
    function onRelease(address actor, address recipient, bytes calldata config, bytes calldata activationTerms, bytes calldata input)
        external returns (bytes memory result);
}
```

Anyone can call an action directly with any arguments. An implementation must authenticate that `msg.sender` is a Market order bound to it, in the matching phase, with `actor`, `suppliedValue`, `releaseRecipient`, config and activation terms equal to the order's readable values. `actions/ActionBase.sol` does this.

## Periphery

- `AcquireAndExecute`: buys an Actions token listed through `ExchangeAction` and executes its `CoveredNFTPurchase` order in the same call. See [ACTIONS.md](ACTIONS.md).
- `FillVerifier`: transient snapshot and outcome checks a caller can use around an execution.

## Toolchain

Solidity 0.8.30, `evm_version = prague`, optimizer 200 runs, via-IR, fixed remappings (`auto_detect_remappings = false`). Remappings and metadata affect bytecode and therefore CREATE2 addresses.
