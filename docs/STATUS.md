# Project status

Updated: 2026-10-30

## State

Specification only. This starter package was prepared for `ripe0x/market`, which was an empty GitHub repository at discovery. No contracts, application, keeper or test harness have been implemented in this package. No claims of real integration, audited code or deployed addresses.

## Verified research, not implementation evidence

1. Seaport supports time dependent item amounts, and exposes matching and fulfillment methods including criteria based advanced matching. This does not prove our exact settlement is compatible with OpenSea's live offers.
2. OpenSea publishes collection offer discovery and an endpoint providing signatures and fulfillment data. The endpoint's output must be validated against the real order and onchain state.
3. Ponytail is an official public coding agent plugin maintained at `DietrichGebert/ponytail`; prefer installing it in Claude Code through its documented commands, or apply its simplicity principles without unnecessary extra scaffolding.

## Immediate next action

Begin Roadmap Phase 0. Run and record a genuine atomic fill on a pinned mainnet fork, including fee and seller surplus routing. Decide on native Seaport matching versus a minimal authorization wrapper only after observing the result. Implement the remainder autonomously.

## Unproven assumptions and blockers

1. Actual OpenSea order compatibility with our desired surplus distribution and seller minimum enforcement.
2. Current live offers, fulfillment payload access, RPC availability, API keys, zones, royalties and proof requirements.
3. Gas economics for small NFT sizes and permissionless executor rewards.
4. Discoverability of our signed orders through existing NFT marketplaces.

## Launch boundary

No transactions with real assets, mainnet deployment, paid services, marketing/public launch, or remote push without explicit owner authorization. Keep local commits and a reproducible handoff. Specs may evolve with genuine technical evidence.

## Milestone ledger

| Phase | State | Evidence |
| --- | --- | --- |
| 0. Seaport integration proof | Not started | None |
| 1. Settlement | Not started | None |
| 2. Matcher | Not started | None |
| 3. User interface | Not started | None |
| 4. Review and economic test | Not started | None |
| 5. Deployment readiness | Not started | None |
