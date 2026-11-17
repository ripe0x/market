# Market: project instructions

Market is a permissionless, execution-agnostic Ethereum protocol with two distinct objects. An `Order` is a cancelable immediate offer; its owner may close it and recover. A `Right` is a one-use, transferable entitlement backed by its own account; `Rights.ownerOf` is its holder authority, and an active right has no issuer cancellation or recovery path. Both account types use fixed implementation clones. Read `README.md`, then `docs/RIGHTS_DESIGN.md`, `docs/SPEC.md`, `docs/SECURITY.md`, `docs/DECISIONS.md` and `docs/STATUS.md`.

## Layout

- `src/` is the core: `Market.sol` (factory), `Order.sol` (cancelable order implementation plus `IOrderHandler`), `Right.sol` (backing account plus `IExerciseHandler`) and `Rights.sol` (canonical ERC721). It uses OpenZeppelin `Clones` and ERC721.
- `periphery/` holds optional contracts Market never calls: `FillVerifier.sol`.
- `handlers/` holds the trading handlers `NFTSale`, `NFTBid`, their bases and `CoveredNFTPurchase` for a fully backed NFT purchase right. Documented in `docs/NFT_TRADING.md` and `docs/HANDLERS.md`.
- `examples/` holds `PaintAction` (revocable immediate order) and `ReservedPaint` (durable right) with `Artwork`.
- `test/` holds Foundry tests; shared setup in `test/utils/`.
- `script/` holds `Deploy.s.sol` (dry run by default), historical-order `Lifecycle.s.sol`, local `RightsLifecycle.s.sol` and `rehearse.sh` (fork rehearsal).

## Rules for changes

1. Keep the core small and asset-agnostic. The owner approved the right-account and ERC721 core change in D401–D408. Further application policy belongs in a handler or external target unless a core boundary requires it; record consequential decisions in `docs/DECISIONS.md`.
2. No `delegatecall` beyond a clone's own call into its fixed implementation, and no fees, admin, registries, signature validation, changeable implementation pointers or upgrade paths in the core. `Order` and `Right` must never contain `DELEGATECALL` or `SELFDESTRUCT`.
3. Handlers follow the rules in the README: act only through `Order(msg.sender).execute`, take only from `caller` and never under an approval a filler gave the order (SECURITY.md, A1), never forward arbitrary calldata from input, key state by `msg.sender`, verify receipt by state, and offer owner maintenance of active orders only as an explicit, narrow fill. Never add an owner bypass of the active-order rule to the core.
   Exercise handlers use `IExerciseHandler` and `Right.execute` instead of `fill`; they authenticate the Market-created right and its exercise window, validate backing before activation, never ask a counterparty to approve the right account, and reserve payment credits. A right's residual beneficiary gets generic authority only after termination.
4. Every change to authority, settlement or money handling needs a focused test, including a hostile case. Fix the design rather than the test when a test exposes a problem.
5. Keep `docs/STATUS.md` accurate: what was run, the result, and what remains unverified. Never call the contracts safe or audited.
6. No mainnet deployment, funded signing, real-asset transactions or paid services without the owner's explicit approval.

## Commands

```bash
forge build
forge test --match-path test/<File>.t.sol        # per change
forge script script/RightsLifecycle.s.sol       # local simulated examples; no broadcast
CANDIDATE_RUN=1 forge test                       # whole suite, once per release candidate
forge test --match-path test/Gas.t.sol --isolate # updates snapshots/GasTest.json
forge test --match-path "test/fork/*" --isolate  # mainnet fork, updates snapshots/NFTFork.json
forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co  # simulation only
```

Tests must use `skip()` or absolute `vm.warp` values: with via-IR, `block.timestamp` may be cached within a test function, so `vm.warp(block.timestamp + n)` twice does not advance twice. Foundry clears transient storage between top-level calls in a test, so anything relying on it within one transaction (a fill, a `FillVerifier` snapshot and check) must run inside a single external call.

## Deployment

Deploy only from an up-to-date `main`. Signer: the Foundry keystore `ripe0x` (`--account ripe0x`), never a Ledger or another project's keystore. RPC: Tenderly's public gateways, `https://sepolia.gateway.tenderly.co` for Sepolia and `https://mainnet.gateway.tenderly.co` for mainnet. Follow the global chain-operations rules: dry run from the same signer, one confirmed broadcast at a time, readback after each.
