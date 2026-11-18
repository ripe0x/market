# Focused improvements verification, 2026-11-18

Compiled production source: `cf7f48d8fae716740c59f882dcc2761497c2a63b`. Functional commit `9d7f43dda544149f93db65fe3570031bc32365c5` and separate comment-only commit `cf7f48d8fae716740c59f882dcc2761497c2a63b`. All 13 comment-only Solidity diffs have identical executable tokens; see the adjacent JSON. Later tests/documentation do not change compiled production source.

## Computed identities

These are undeployed Sepolia candidates. The local rehearsal deployed these identities only on isolated Anvil chain 31337. Public start block remains null. Historical public deployment records are preserved.

| Contract | Candidate address | Runtime hash |
| --- | --- | --- |
| market | `0x5796242872BCAA3Fb0e16a4388c70f2e80aB966c` | `0x196e944e7bab0dfbbdd9cf026f0e2e6c6c98afdbbdcf1316bad2fb675eaca98d` |
| orderImplementation | `0xaCbCDc61A784784a6290cFD03B4bE69276D25DE2` | `0xce409f7c150873fa8810707a9319bed03f25fe55fb4ec3fa095bf1a578134185` |
| rightImplementation | `0x6fBf0eB3B39e5841c5a42B78419585d079413C27` | `0x3b964c615ccfa1c00c11569c78bba5ba2f8ec763499f8a23291048f810dfb334` |
| rights | `0x342589F108327aF8809D02F52304852BF6C76382` | `0xa5942dc705cca2f8e3d7d7c3e5d02b05b25faa9667db39056c18e294a5839330` |
| feeConfig | `0x89Af00fB84a9352408B8249e9cb8438533751783` | `0x50b9332c4cd984701e1319eda5dcf20c3f3efc190d4a554e374406f7d44b3087` |
| nftSale | `0x14EBFFd2Df1BF321dD782fE41D1c436805A6b7ad` | `0x85e7b201e340fcbc2a53c4a1f140ca2e4cc48df1a9bad60189e7c96eb2fa33a2` |
| nftBid | `0xB2A1649B4DFD9f02cdc8bFEdeAa45a33F8b5C8e5` | `0x79ff6455a4a270e4392093d808c4f6e1e0a71ac3e7b798663113a4bbcbecdb9b` |
| coveredNFTPurchase | `0xE0eF13aD270d514580D01cEd6f5716A3D7B8B569` | `0x299029f3f473c2436f80c6b85f32fbd571e00fd73631eea1e7cee3c30a0633e3` |
| fillVerifier | `0x84042d827d30DB1eF9cE21477ebb6c83CDB04430` | `0xc877185589b7d2b31bed7924a42db249f341b2e814e14385bb89e3ad258efaec` |

## Commands and observed results

Toolchain: Foundry 1.8.1, solc 0.8.30, Prague, via IR, optimizer 200; repository fixed remappings.

- `forge test --match-path 'test/{RightsImprovements,RightsEconomics,RightExamples,PaintAction,Fee}.t.sol' -vv`: 54 passed.
- `forge test --match-path test/RightsGas.t.sol --isolate -vv`: 2 passed. Covered activation 232,109 to 209,694 gas, saving 22,415. Create 127,135 unchanged; exercise 201,501 to 199,250; expiry 52,195 to 49,966; nft recovery 72,939 and royalty release 71,728 unchanged. Before/after use identical compiler/profile; these are isolated local gas units, not public gas prices.
- `CANDIDATE_RUN=1 forge test --no-match-path 'test/fork/*' --summary`: 245 passed, including the deterministic multi-lifecycle driver scenario.
- `CANDIDATE_RUN=1 MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co SEPOLIA_RPC_URL=https://sepolia.gateway.tenderly.co forge test --match-path 'test/fork/*' --summary`: initial 22 passed, 1 failed. The historical FillVerifier/current source bytecode equality assertion became invalid when comments changed metadata. Pinning the historical hash and asserting its distinction from the current candidate repairs that expectation; the affected Sepolia suite rerun passes 7/7. Mainnet NFT 14/14 and covered-right 2/2 passed in the initial run.
- `CANDIDATE_RUN=1 FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-path 'test/{Invariant,RightsInvariant}.t.sol' -vv`: both suites passed, each 1,000 runs and 128,000 driver calls, zero unexpected reverts. Deterministic multi-lifecycle scenario also passed. Deep run completed in 204.32 seconds wall time; order campaign 37.37 seconds. Skipped calls and transition counters remain separately reported by the rights driver.
- `forge build --sizes`: passed. Rights runtime/init 7,951/8,838 bytes (previous 8,092/8,979, both down 141); Market runtime/init 2,325/19,971; Right 6,118/6,333; Artwork 5,158/6,038.
- `forge fmt --check src handlers periphery examples test/RightsImprovements.t.sol test/RightsEconomics.t.sol test/Fee.t.sol test/RightExamples.t.sol test/PaintAction.t.sol test/Gas.t.sol script/Lifecycle.s.sol script/RightsLifecycle.s.sol`: passed. Unscoped `forge fmt --check` reports pre-existing formatting differences in unrelated test/script files; those are preserved rather than reformatted.
- `slither . --skip-clean --exclude-dependencies --filter-paths 'lib/|test/|script/' --json /tmp/market_improvements_slither.json`: exit 255, JSON success true, 30 contracts, 101 detectors, 25 results. Reviewed categories: intentional timestamp boundaries, authorized account calls and credit payout low-level calls, transient account locks with events after interactions, factory stranded/forced ETH, explicit assembly and caller-selected generic recovery targets. No new actionable issue identified in this focused pass. Static analysis is not an audit.

## Economic scorecard

| Scenario | Premium seller | Trading fee | Exercise proceeds credit | Royalty credit | Collateral |
| --- | --- | --- | --- | --- | --- |
| 1 eth premium, zero strike | 0.99 eth | 0.01 eth | 0 | 0 | holder after exercise |
| 1 eth premium, one wei strike | 0.99 eth | 0.01 eth | 1 wei | 0 | holder after exercise |
| Zero premium, 1 eth strike | 0 | 0 | 0.95 eth | 0.05 eth | holder after exercise |
| Surrender/expiry | premium stays spent | no new fee | no new credit | no new royalty | immutable issuer for activated covered right |
| Canceled invalid pending setup | no minted claim | 0 | 0 | 0 | actual committed core residual |

These owner-approved allocations deliberately do not enforce a charge on total economic consideration. Assets remain isolated per right; ETH credit reserves survive termination and arbitrary residual recovery. No new running-cost recipient or ratcheting economic parameter is introduced. Gas-price spikes affect transaction payer costs, not the allocation formula; public gas/wallet behavior remains outside local evidence.

## Signed local evidence

Client `packages/protocol/evidence/rights-local.json` records 56 actual signed local transactions: 55 successes and one deliberately reverted atomic issuance, total gas 13,178,598. Nonzero gas prices are recorded per receipt. It reconciles 0.2/0.3 eth premiums (0.198/0.297 seller, 0.005 total fee), 1 eth exact exercise (0.95/0.05 credit and actual beneficiary receipts), unchanged backing through resales, burn, listing expiry/live return, right expiry/close-only/finalization, manual-config collateral recovery after burn, pending cancellation and genuine account atomic rollback. The supplied config prevents historical lookup during manual recovery; browser tests separately exercise failed discovery services. No public transaction occurred.

## Limits

Local test and AI source-review evidence is bounded, not an independent audit. Real wallet extension behavior, public deployment, public walkthrough, production indexer migration/cutover, transaction inclusion timing and current public gas-market behavior remain unverified and unauthorized here. A refusing beneficiary that cannot authorize redirection still has an uncollectible reserved credit; someone must pay gas for releases and expiry finalization.

Things that do not make sense: no new unresolved economic policy issue. The explicitly approved zero-strike and split-consideration outcomes remain possible.
