# Market: project instructions

Market is a permissionless, execution-agnostic Ethereum protocol: one `Order` account per commitment (an ERC-1167 clone of one fixed implementation, terms in its code), bound to a policy whose code is pinned and which steers the order only during fills. Read `README.md`, then `docs/SPEC.md`, `docs/SECURITY.md`, `docs/DECISIONS.md` and `docs/STATUS.md`.

## Layout

- `src/` is the core: `Market.sol` (factory) and `Order.sol` (account implementation plus `IPolicy`). Its only dependency is OpenZeppelin `Clones`.
- `periphery/` holds optional contracts Market never calls: `FillVerifier.sol`.
- `examples/` holds application policies and their helper contracts. Examples may use OpenZeppelin.
- `test/` holds Foundry tests; shared setup in `test/utils/`.
- `script/` holds `Deploy.s.sol` (dry run by default) and `Demo.s.sol` with `demo.sh` (local anvil).

## Rules for changes

1. Keep the core small and asset-agnostic. If an application seems to need a core change, first try to express it as a policy or an external contract, and record the outcome in `docs/DECISIONS.md`.
2. No `delegatecall` beyond the clone's own call into the fixed implementation, and no fees, owner roles, registries, signature validation, initializers or upgrade paths in the core without a recorded decision and owner review. `Order` must never contain `DELEGATECALL` or `SELFDESTRUCT` (`test_implementationCannotBeReplaced`).
3. Policies follow the rules in the README: act only through `Order(msg.sender).execute`, take only from `caller`, never forward arbitrary calldata from input, key state by `msg.sender`, verify receipt by state.
4. Every change to authority, settlement or money handling needs a focused test, including a hostile case. Fix the design rather than the test when a test exposes a problem.
5. Keep `docs/STATUS.md` accurate: what was run, the result, and what remains unverified. Never call the contracts safe or audited.
6. No mainnet deployment, funded signing, real-asset transactions or paid services without the owner's explicit approval.

## Commands

```bash
forge build
forge test --match-path test/<File>.t.sol        # per change
CANDIDATE_RUN=1 forge test                       # whole suite, once per release candidate
forge test --match-path test/Gas.t.sol --isolate # updates snapshots/GasTest.json
script/demo.sh                                   # all four examples on a throwaway anvil
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co  # simulation only
```

Tests must use `skip()` or absolute `vm.warp` values: with via-IR, `block.timestamp` may be cached within a test function, so `vm.warp(block.timestamp + n)` twice does not advance twice. Foundry clears transient storage between top-level calls in a test, so anything relying on it within one transaction (a fill, a `FillVerifier` snapshot and check) must run inside a single external call.
