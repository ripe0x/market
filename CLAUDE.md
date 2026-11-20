# Market: project instructions

Market is a permissionless, execution-agnostic Ethereum protocol in which every order is an order for an authorized contract action. `Market` creates isolated `Order` clones whose code commits issuer, action implementation and its code hash, admission, deadline, residual and full config. Every action implements `IAction` and runs through `Order.execute(input)`. Public orders are cancelable immediate offers; Holder orders are transferable commitments owned through the `Actions` ERC721 and cannot be canceled by the issuer. Read `README.md`, then `docs/SPEC.md`, `docs/ACTIONS.md`, `docs/SECURITY.md`, `docs/DECISIONS.md` and `docs/STATUS.md`.

## Layout

- `src/` is the core: `Market.sol` (factory and registry), `Order.sol` (account implementation, `IAction`, `OrderSpec` and enums) and `Actions.sol` (ERC721 of Holder orders).
- `actions/` holds the shared implementations: `ActionBase`, `ExchangeAction` (sales and bids), `FeeConfig`, `CoveredNFTPurchase`, `ReservedAction`.
- `reservations/` holds the proposed `IReservedActionTarget` and the `ReservedActionTarget` helper.
- `periphery/` holds optional contracts Market never calls: `AcquireAndExecute`, `FillVerifier`.
- `examples/` holds `Artwork`, a palette and renderer reservation target.
- `test/` holds Foundry tests; shared setup in `test/utils/`.
- `script/` holds `Deploy.s.sol` (dry run by default), `ActionsLifecycle.s.sol` (local simulated lifecycles) and `rehearse.sh` (local Anvil rehearsal).

## Rules for changes

1. Keep the core small and asset-agnostic. Application policy belongs in an action implementation or an external target. Record consequential decisions in `docs/DECISIONS.md`.
2. No `delegatecall` beyond a clone's own call into its fixed implementation, and no fees, admin, registries beyond `isOrder`, signature validation, changeable implementation pointers or upgrade paths in the core. `Order` must never contain `DELEGATECALL` or `SELFDESTRUCT`.
3. Actions act only through `Order.call` and `Order.credit` of the authenticated calling order, authenticate context with `ActionBase`, never forward arbitrary calldata from input, key state by order, verify outcomes by state, and never use an approval granted to an order. Bid NFTs are approved to `ExchangeAction`. Never give the issuer or residual a call path through the order.
4. Every change to authority, settlement or money handling needs a focused test, including a hostile case. Fix the design rather than the test when a test exposes a problem.
5. Keep `docs/STATUS.md` accurate: what was run, the result, and what remains unverified. Never call the contracts safe or audited.
6. No mainnet deployment, funded signing, real-asset transactions or paid services without the owner's explicit approval.

## Commands

```bash
forge build
forge test --match-path test/<File>.t.sol        # per change
forge script script/ActionsLifecycle.s.sol      # local simulated lifecycles; no broadcast
CANDIDATE_RUN=1 forge test                       # whole suite, once per release candidate
forge test --match-path test/Gas.t.sol --isolate # updates snapshots/GasTest.json
forge test --match-path "test/fork/*" --isolate  # mainnet fork, updates snapshots/NFTFork.json
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co  # simulation only
```

Tests must use `skip()` or absolute `vm.warp` values: with via-IR, `block.timestamp` may be cached within a test function, so `vm.warp(block.timestamp + n)` twice does not advance twice. Foundry clears transient storage between top-level calls in a test, so anything relying on it within one transaction (an execution, a `FillVerifier` snapshot and check) must run inside a single external call.

## Deployment

Deploy only from an up-to-date `main`. Signer: the Foundry keystore `ripe0x` (`--account ripe0x`), never a Ledger or another project's keystore. RPC: Tenderly's public gateways, `https://sepolia.gateway.tenderly.co` for Sepolia and `https://mainnet.gateway.tenderly.co` for mainnet. Follow the global chain-operations rules: dry run from the same signer, one confirmed broadcast at a time, readback after each.
