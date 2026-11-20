# Market

Market is a permissionless Ethereum protocol in which every order is an order for an authorized contract action. Ordinary NFT sales and bids, transferable actions and reserved artwork operations all use the same account implementation, the same `IAction` interface and the same lifecycle, executed through `Order.execute(input)`.

The core (`Market`, `Order`, `Actions`) has no owner, fee, allowlist or upgrade path. The shared `ExchangeAction` charges a trading fee of at most 1%, fixed per order at activation. Covered purchase and reserved action executions carry no trading fee.

> **Status: experimental, unaudited, undeployed candidate.** Tests and automated reviews are evidence about tested behaviour, not a safety claim ([STATUS](docs/STATUS.md), [SECURITY](docs/SECURITY.md)). The verified 2026-11-16 Sepolia addresses run the earlier order-only code ([DEPLOYMENT](docs/DEPLOYMENT.md)); nothing in this design is deployed.

## How it works

1. **Create.** `Market.create(spec, salt)` deploys an isolated `Order` clone whose address commits to the issuer, the action implementation and its runtime code hash, admission, deadline, residual beneficiary and full config. The config stays readable from the order's code forever.
2. **Back and activate.** Backing is put in place first (an escrowed NFT, ETH, or a target's reservation for the order's address). `activate()` asks the action to `validate` it, stores the activation terms and goes Live. A Holder order mints an `Actions` ERC721 (token id = order address) to the issuer.
3. **Execute.** `execute(input)` runs the action's `onExecute`. Public orders accept any executor and repeat until the action reports completion; the issuer may cancel. Holder orders accept only the token owner, must complete in one call, cannot be canceled by the issuer, and can be transferred or surrendered.
4. **End and clean up.** Each order ends Completed, Canceled, Expired (anyone, at the exclusive deadline) or Surrendered. `release` cleans up backing, `withdrawSurplus` returns free ETH to the residual, and credited payees withdraw their credits. Cleanup is separate from termination and retryable.

| Implementation | Admission | What it does |
| --- | --- | --- |
| `ExchangeAction` | Public | ERC721 sale (escrowed) or bid (funded, replenishable, up to N tokens) for ETH with price schedules, ERC2981 royalty and a snapshotted fee |
| `CoveredNFTPurchase` | Holder | Transferable right to buy one escrowed NFT at a fixed price; royalty snapshotted at activation; proceeds credited |
| `ReservedAction` | Either | Executes one operation a target has reserved for the order (proposed `IReservedActionTarget`) |
| `AcquireAndExecute` (periphery) | | Buys a listed Actions token and executes its covered purchase atomically |

Details: [core specification](docs/SPEC.md), [actions and integration guide](docs/ACTIONS.md), [security model](docs/SECURITY.md), [decisions](docs/DECISIONS.md).

## Usage

Requires [Foundry](https://getfoundry.sh). Dependencies are pinned submodules: forge-std and OpenZeppelin Contracts v5.7.0.

```bash
git submodule update --init
```

```bash
forge build
```

```bash
forge test --no-match-path "test/fork/*"
```

```bash
FOUNDRY_PROFILE=invariant forge test --match-path test/Invariant.t.sol
```

```bash
forge test --match-path "test/fork/*" --isolate
```

```bash
script/rehearse.sh
```

Fork tests use `https://mainnet.gateway.tenderly.co`. `script/Deploy.s.sol` deploys through the standard CREATE2 deployer and only simulates without `--broadcast`. `script/rehearse.sh` deploys and runs `script/ActionsLifecycle.s.sol` on a throwaway local Anvil.

## Repository

```
src/           Market, Order (with IAction), Actions: the core
actions/       ActionBase, ExchangeAction, FeeConfig, CoveredNFTPurchase, ReservedAction
reservations/  IReservedActionTarget and the ReservedActionTarget helper
periphery/     AcquireAndExecute, FillVerifier
examples/      Artwork (palette and renderer reservations)
test/          unit, regression, invariant and gas tests; test/fork: mainnet fork
script/        Deploy.s.sol, ActionsLifecycle.s.sol, rehearse.sh
docs/          SPEC, ACTIONS, SECURITY, DECISIONS, DEPLOYMENT, STATUS
```

## License

MIT, see [LICENSE](LICENSE).
