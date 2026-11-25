# Status

## Mainnet readiness, 2026-11-25

Protocol PRs #17 and #18 merged to `main` (merge commit `c671b3c`); client PRs #7 and #8 merged to client `main` (`eddca79`). Production bytecode unchanged from `45492b9`.

| Check at `main` | Command | Result |
| --- | --- | --- |
| Read-only mainnet dry run | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co --sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9` | Exit 0. Same nine addresses as the candidate table. Estimated 14,341,828 gas, about 0.0165 ETH at a 0.57 gwei base fee. No signer, no broadcast. |
| Mainnet-fork rehearsal | `script/rehearse.sh https://mainnet.gateway.tenderly.co` | Exit 0 at fork block 26,493,718: `Deploy.run()` and `examples()` from Anvil's unlocked account, then the lifecycle simulation. Acquire payer spent exactly 6 ETH (1 premium + 5 exercise price; 1 ETH excess refunded). |

Environment finding: the first fork rehearsal failed `exact spend`. The lifecycle script's actors were `vm.addr(1..9)`, whose private keys are public; on mainnet all nine carry an EIP-7702 delegation (`0xef0100` + `8a67b5…`) that forwards received ETH, so the correct 1 ETH refund was swept. The script now derives actors from unheld keys and requires each to have no code. No fork test uses small-key actors. This is the documented behavior that an ETH transfer calls the receiver's code, not a protocol defect.

### Sepolia deployment, 2026-11-25

Owner ran `Deploy.run()` from `main` with `--account ripe0x` (signer `0xCB43078C32423F5348Cab5885911C3B5faE217F9`). All nine addresses match the candidate table. Seven transactions, all status 1, blocks 12,211,383 to 12,211,389, 69,373,499 gas, 0.0386 Sepolia ETH. Market tx `0x68fd0350a526476ec45453f7daf29d9ff375c943096ae2a149656538ff1fa0e6` (27,540,377 gas). Not submitted to Etherscan or Sourcify.

Readback from chain: runtime sizes Market 2,047, Order implementation 7,409, Actions 7,803, FeeConfig 924, ExchangeAction 10,155, CoveredNFTPurchase 5,131, ReservedAction 4,329, AcquireAndExecute 4,468, FillVerifier 1,058 bytes. `Market.implementation()` and `actions()`, `Actions.market()`, the implementation's `market()` and `actions()`, each action's `market()`, `ExchangeAction.fees()` and `actions()`, and `AcquireAndExecute.market()`, `actions()`, `exchange()`, `covered()` all point at the table addresses. `FeeConfig` admin `0xCB43…17F9`, recipient `0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72`, `feeBps` 100.

Gas finding: Sepolia now prices state creation far above mainnet. Node estimates: Market deployment 27,979,862 gas on Sepolia versus 3,986,414 on mainnet; an empty contract 214,117 versus 54,469; about 1,557 versus 200 gas per byte of deployed code. Forge simulates with local rules, so the first broadcast (tx `0x55dab960bb0c8744bd95d73d7b1ab482d3e11b475fb0da2e614426ecf3eb0d6f`, gas limit 5,735,671) reverted, created nothing and cost 0.000052 ETH; the rerun used `-g 900`. The node does not expose `eth_config`, so the fork name is unconfirmed. If mainnet adopts this pricing, each order (one new clone) costs several hundred thousand more gas and the 14,341,828-gas mainnet estimate no longer holds; re-estimate with the mainnet node before deploying.

### Listing recovery at every step, 2026-11-25

`forge test --match-path test/ListingRecovery.t.sol`: 12 passed. The client lists in three transactions (create, deposit, activate). Stopping after any of them, the residual (the seller) recovers the NFT with `release`: in Pending with or without `cancel`, before or after the deadline, after a rejected activation, and after a deposit into an already canceled order. A Live listing past its deadline needs `finalizeExpiry` (anyone) before `release`. Strangers cannot release. The two-transaction alternative (deposit to the predicted address, then `createAndActivate`) strands the NFT permanently if the deadline passes first, because `create` rejects an expired spec and the address can never get code; it is also lost if the exact spec or salt is lost. Rejected.

Still not done: owner approval of [RELEASE.md](RELEASE.md) outcomes, independent external audit, Sepolia real-transaction lifecycle with indexer, web and a real wallet, mainnet deployment and canary.

## Unified action candidate, 2026-11-19

**Experimental, unaudited, undeployed.** Production source frozen at `45492b9aa6f7bdfe232a5f174fe5f76d59d414c7` (branch `claude/unified-actions`, based on PR #17 head `0e8832c`). Later commits on the branch change only documentation. Design: [SPEC](SPEC.md), [ACTIONS](ACTIONS.md), decisions D501–D511.

| Check at `45492b9` | Command | Result |
| --- | --- | --- |
| Whole suite incl. mainnet fork | `CANDIDATE_RUN=1 forge test --summary` | exit 0; 202 passed, 0 failed, 0 skipped in 18 suites. Includes 5 mainnet fork tests at block 26,450,000 via `https://mainnet.gateway.tenderly.co` (BAYC and Opepen sales, Azuki and Chimpers bids, Opepen covered purchase) and the default-profile invariant run. |
| Deep invariant | `FOUNDRY_PROFILE=invariant CANDIDATE_RUN=1 forge test --match-path test/Invariant.t.sol` | exit 0; 1,000 runs × 128 calls, `fail_on_revert = true`, 0 reverts, 0 discards, 90.8 s. 21 handler actions each called about 355–425 times in the default run with 0 reverts; expected rejections are asserted with exact selectors inside `probeReject`. The deterministic trace reaches all 28 transition types. Exact model: per-order balance and credits, per-beneficiary credits, token existence and owner, global ETH conservation, every tracked NFT owner. |
| Local rehearsal | `script/rehearse.sh` | exit 0; plain local Anvil 31337 with disposable unlocked key; Deploy, Artwork example and full lifecycle. Receipts include sale fee 0.1, royalty 0.5, refund 1; Actions resale premium 2, fee 0.02; covered royalty credit 0.4; AcquireAndExecute premium 1 + execution 5 with refund 1; both recovery paths returned the NFT. |
| Sizes | `forge build --sizes --skip test --skip script` | Runtime bytes: Order 7,409, Market 2,047 (initcode 18,568), Actions 7,803, ExchangeAction 10,155, CoveredNFTPurchase 5,131, ReservedAction 4,329, AcquireAndExecute 4,468, Artwork 5,968, FeeConfig 924. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | create+activate sale 302,308; sale execute 168,764; bid create 219,066; bid execute 162,167; covered issue 155,974; covered execute 167,515; credit withdrawal 37,308. Solc 0.8.30, via-IR, optimizer 200, prague. |
| Static analysis | `slither . --exclude-dependencies --filter-paths 'lib/|test/|script/'` (0.11.5, at `abd057a`, production code then differing only by the royalty cap and the phase-check order) | 27 results: reentrancy reports on paths guarded by the phase lock, timestamp comparisons for the exclusive deadline, assembly, low-level calls, and Market's payable creation. No actionable finding. |
| Independent review | Separate reviewer, owner requirements and audit standard, no prior findings | No critical or high finding. Low R1 reservation executor poisoning (documented, regression in `test/review/`). Not an audit. |

Findings and regressions: bid approval attacks through an Order approval (native withdrawal and active proceeds receiver) in `test/BidApproval.t.sol`; reservation poisoning in `test/review/ReviewReservation.t.sol`.

Replaced coverage: the order, rights, handler and PaintAction suites were removed with their contracts. Their properties (factory determinism, code pin, credits, recovery, NFT trading money terms, royalty cap, rights transfer rules, hostile receivers, composition) are re-covered by `Core`, `ActionsToken`, `Credits`, `Exchange`, `Covered`, `Reserved`, `Acquire` and the invariant. Not reproduced: the legacy Sepolia live fork checks. The FillVerifier suite was restored after the whole-suite run: `forge test --match-path test/FillVerifier.t.sol`, 10 passed.

Remaining unverified: real wallet extensions; any public chain; a funded rehearsal or canary; an independent audit. ERC721 operators of Actions tokens can take the token and execute; see [SECURITY](SECURITY.md).

## Focused contract and client improvements, 2026-11-18

Production source is frozen at `cf7f48d8fae716740c59f882dcc2761497c2a63b`: functional `9d7f43d` authenticates Artwork against its immutable configured Market and removes redundant mint history; separate `cf7f48d` changes only production comments. The client pins complete revision `c211808cf3dd6ed36f41e92d885e6f866a4b9436`, including the fork-test repair, and regenerates ABIs and candidate manifests. The production files are unchanged from cf7f48d. This supersedes the preceding metadata candidate identity, not historical public deployments.

Fresh local suite: 245 passed. Order and rights deep invariant campaigns: each 1,000 runs × 128 calls with fail-on-revert true, zero driver reverts; the deterministic multi-lifecycle scenario passes. Focused regressions: 54 passed. Read-only forks: 14 NFT, 2 covered and 7 Sepolia tests passed, with the historical FillVerifier hash assertion repaired for intentional source metadata changes. Covered activation saves 22,415 isolated gas (232,109 → 209,694). Runtime/initcode Rights 7,951/8,838 bytes.

The signed client rehearsal records 56 local transactions, including a genuinely reverted atomic issuance and both expiry cleanup paths, with exact premium, exercise credit and payout reconciliation. New computed Market is `0x5796242872BCAA3Fb0e16a4388c70f2e80aB966c`; **no rights-enabled public deployment exists or is authorized**. Detailed commands, retained initial failures, code hashes, economic scorecard and limits are in [the verification record](verification/2026-11-18-improvements.md). Remaining client browser verification is tracked in the client status.

## Covered nft client milestone, 2026-11-17

The transferable-rights implementation was merged to `main` at `f70294aa45a435f20a0c8bb9721bd698fc0a4423` (PR #16). The `codex/covered-rights-client` branch adds canonical onchain metadata at source `91b22d39b58e35285eede0120a65ef4e6392959f` (D412–D413); the client began at `b4ee89ed591265964413fec58bc2dd1aca658b68` and records its exact final protocol pin in the client deployment manifests. The 2026-11-16 Sepolia order-only deployment remains a separate verified legacy release. **No rights-enabled public deployment or broadcast is authorized or recorded.**

| Check at metadata source `91b22d3` | Result and boundary |
| --- | --- |
| Solidity local candidate | `CANDIDATE_RUN=1 forge test --no-match-path 'test/fork/*' --summary`: 223 passed in 27 suites, 0 failed or skipped. Both invariant suites ran 128 × 64 calls with zero driver reverts. See `/tmp/market_metadata_candidate_local.log` for the captured run; this is local test evidence, not a public-chain transaction. |
| Pinned fork candidate | `MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co SEPOLIA_RPC_URL=https://sepolia.gateway.tenderly.co forge test --match-path 'test/fork/*' --summary`: 23 passed (14 NFT, 2 rights, 7 legacy Sepolia), 0 failed. Forked historical chain state, not the undeployed rights candidate on public Sepolia. See `/tmp/market_metadata_candidate_forks.log`. |
| Metadata and size | Focused `forge test --match-path test/RightsMetadata.t.sol -vv`: 5 passed, including exclusive expiry before finalization, perpetual rights, absent token URI, exact uint256 deadline and execution callback status. Rights runtime/initcode 8,092/8,979 bytes; Market initcode 20,112 bytes. Direct CREATE gas is 4,284,302 for Market and 1,894,047 for Rights, increases of 740,012 and 739,151 over `f70294a` (D413). Deployment addresses change. |
| Client local signed rehearsal | `pnpm --filter @market/protocol rehearse:rights` executed 47 signed transactions against isolated Anvil chain 31337: 46 successful and one deliberately reverted atomic issuance. The evidence file is in the client at `packages/protocol/evidence/rights-local.json`, recording its exact protocol commit (the metadata bytecode is unchanged from `91b22d3`). It records right sale at 0.2 ETH, resale at 0.3 ETH, 1 ETH exercise, 0.05/0.95 ETH royalty/proceeds credits and release, listing cancellation, surrender, expiry, pending cancellation, atomic issue, and failure rollback. Gas prices in the receipts are nonzero; this is not a public broadcast. |

Slither 0.11.5 ran on the metadata candidate with `slither . --skip-clean --exclude-dependencies --filter-paths 'lib/|test/|script/' --json /tmp/market_metadata_slither_final.json`: exit 255 because detectors reported 25 results; JSON success was true. The 24 previous detector results are unchanged; the added `Rights.tokenURI` timestamp comparison intentionally mirrors the exclusive expiry boundary. This triage found no new actionable issue and is not an independent audit.

Client package tests are reported separately by the client release record. Client browser evidence is recorded in the client release status and is not implied by the contract or local RPC results.


## Merged rights baseline evidence

The following results were collected for the `codex/transferable-rights` candidate based on `79120eb`, then merged through PR #16 at `f70294a`. They describe that earlier build. The metadata build above changes bytecode and addresses. Earlier Sepolia records below remain historical evidence for the order-only release.

### Transferable-rights baseline (merged at `f70294a`)

The redesign adds isolated `Right` accounts, canonical `Rights` ERC721 ownership, activation validation, fixed exercise terms, terminal recovery and per-account ETH payment credits. `CoveredNFTPurchase` and `ReservedPaint` are the two reference handlers. Existing orders, immediate PaintAction, and the direct NFT trading policy remain. **Experimental and unaudited.** No production compatibility claim is made for the new addresses.

| Check | Exact command and result | Limit |
| --- | --- | --- |
| Formatting and compilation | `forge fmt --check` on changed Solidity files and `forge build --sizes --skip test --skip script`: exit 0. Runtime bytes: Market 2,325, Order 2,133, Right 6,118, Rights 4,673, CoveredNFTPurchase 3,610, NFTSale 3,778, NFTBid 4,056, ReservedPaint 2,318, Artwork 5,155. | All below the 24,576-byte runtime limit; Market initcode 16,693 bytes. |
| Local suite | `CANDIDATE_RUN=1 forge test --no-match-path 'test/fork/*' --summary`: exit 0, 218 passed, 0 failed across 25 suites, including passive payout, hostile payout callbacks, atomic issuance and the deterministic multi-account driver scenario. The rights driver then gained an additional atomic-issuance action and more metric labels; its affected campaign is recorded below. | Fork suites ran separately through public Tenderly RPC. |
| Mainnet fork | `MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co SEPOLIA_RPC_URL=https://sepolia.gateway.tenderly.co forge test --match-path 'test/fork/*' --isolate --summary`: exit 0, 16 mainnet tests including 2 new covered-right tests for BAYC and Opepen at block 26,357,000. | Pinned historical collections; fork actors are impersonated. |
| Historical Sepolia fork | Same combined fork command: 7 passed at block 12,150,234, including the legacy arena and the explicit old/new bytecode distinction. | These deployed contracts have no native rights. |
| Previous rights invariant evidence (3e868bc) | The original 1,000 × 128 campaign made 128,000 driver calls, but created only one right per run. Most later calls could skip after that right terminated. | Call count did not measure meaningful transitions; the replacement multi-account campaign below supersedes this coverage claim. |
| Local demonstrations | `forge script script/RightsLifecycle.s.sol:RightsLifecycle --sig 'run()'`: exit 0; covered right sold, resold, exercised, and separately expired and recovered; artwork right sold, resold and exercised after artwork transfer. | Script uses local cheatcodes, not real signed transactions. |
| Deployment simulations | Local `forge script script/Deploy.s.sol:Deploy --sig 'run()'`: exit 0, 7,817,821 simulated gas; `examples()`: exit 0, 1,007,584 simulated gas. Read-only `forge script script/Deploy.s.sol:Deploy --sig 'run()' --rpc-url https://mainnet.gateway.tenderly.co`: exit 0, 10,236,025 estimated gas on a mainnet simulation. | No signer or broadcast. Addresses and estimates reflect the permissionless credit-release build; they are not a real-transaction rehearsal. |
| Static analysis | `slither . --skip-clean --exclude-dependencies --filter-paths 'lib/|test/|script/' --json /tmp/market_credit_slither.json`: Slither 0.11.5, 101 detectors over 29 contracts, 24 reported results. Exit 255 for findings; JSON reports success. Same detector categories, triaged below. | Detector output is not an audit. |
| Rights gas | `forge test --match-path 'test/*Gas.t.sol' --isolate --summary`: 8 tests passed; `snapshots/RightsGasTest.json` and `snapshots/GasTest.json`. | Local Prague / solc 0.8.30 / via-IR / 200 optimizer runs; gas price and basefee are not modeled. |

### Rights invariant model after PR review

The replacement driver keeps up to 32 separate account records, never reusing terminal records. Separate create/deposit/activate actions exercise pending setup; an atomic issue action also supplies fresh active claims throughout the run. A bounded eligible-state scan interleaves transfers, sale escrow/fill/cancel, exercise, surrender, finite expiry, accidental ETH deposits, recovery, payout and issuer bypass attempts. Every record remains subject to NFT custody/delivery, actual live token ownership, pending/terminal token absence, ETH solvency and per-beneficiary credit reconciliation. Sale premiums are independently checked at 0.2 ETH = 0.198 ETH seller + 0.002 ETH fee; exercise at 1 ETH = 0.95 ETH proceeds + 0.05 ETH royalty.

Successful action counters and skipped calls are separate. Forge exposes `afterInvariant` logs for the final run only; they are not campaign aggregates. Creation/activation counters include constructor setup (two created, one backed active and one backed pending). The combined finalization counter includes both pending and active states; the deterministic scenario independently reaches active expiry. Saturation at 32 accounts is counted as a skip. This harness does not exercise an escrow order's token directly; the token is sold or returned before exercise, or expires in escrow.

The accepted rights campaign ran `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-path test/RightsInvariant.t.sol --fuzz-seed 0x17 -vv`: exit 0, 1,000 runs, 128,000 driver calls, zero driver reverts, plus the deterministic driver test. The unchanged order campaign also passed 1,000 × 128 calls with zero driver reverts at seed `0x17` in the earlier combined `test/*Invariant.t.sol` run.

Final rights run only (128 calls, including 50 skipped calls; constructor setup counts are included below):

| Successful operation | Count | Successful operation | Count |
| --- | ---: | --- | ---: |
| Created / collateral deposited / activated | 19 / 10 / 8 | Direct transfers / listings / sales | 5 / 3 / 2 |
| Exercise / surrender | 5 / 1 | Pending-or-active finalizations / pending cancels | 3 / 9 |
| NFT / free ETH recoveries | 4 / 3 | Credit payouts / bypass attempts | 8 / 10 |
| ETH deposits | 7 | Listing cancellations / stale closes | 0 / 1 |

This final sample did not reach live listing cancellation, and its combined finalizations do not establish a separate active-expiry count. The deterministic driver test reaches both paths and asserts no skipped actions. The 32-account cap was not reached in this sample; all 50 skips lacked a suitable state. No aggregate transition count across the 1,000 runs is claimed.

The model uses one honest local NFT, fixed prices/royalties/fees, funded external actors and zero gas price. Counters describe reached contract paths, not production demand, user profit, arbitrary targets, or adversarial recipient coverage. Dedicated payout and composition tests cover hostile callbacks. An initial broad build also saw a partially written driver and failed compilation; that transient failure is not a candidate result. The first complete replacement run had 282 unintended driver reverts because `vm.prank` was consumed by a `tokenId()` argument evaluation; IDs were moved before impersonation and zero-revert checks then passed. The first deep replacement sample still reached few activations, so a fresh-backed-issue action was added before accepting the strengthened campaign.

### Economic flow scorecard

These are acceptance examples from executed local paths, not owner-approved launch limits. Each right has its own custody and credit balance. The direct NFT sale policy remains the historical O1–O5; right-token premiums use that trading layer, while exercise does not.

| Regime | Input and destination | State after the round trip |
| --- | --- | --- |
| Primary sale and resale | One NFT stays in its backing account through 0.2 ETH and 0.3 ETH right-token premiums. At 1% trading fee, sellers receive 0.198 and 0.297 ETH; fee recipient receives 0.002 and 0.003 ETH. | Final holder pays 1 ETH to exercise. With royalty fixed at activation at 5%, the account credits 0.05 ETH to royalty recipient and 0.95 ETH to issuer's proceeds beneficiary, delivers the NFT and burns the token. Withdrawal takes both credits to zero; residual gets no part of the exercise payment. |
| No buyer, then expiry | One NFT, zero premiums and zero exercise payment. Listing cancellation returns only the token; at the right deadline anyone burns it by finalizing. | The immutable issuer, required as residual for the covered NFT handler, recovers the one NFT. No exercise credit or trading fee arises. An abandoned finite Pending setup can also be finalized by anyone at its deadline and recovered by its configured residual beneficiary. |
| Maximum configured royalty | One NFT, 1 ETH exercise payment, ERC2981 at the issuer's 100% limit. | Royalty credit 1 ETH, issuer proceeds credit 0; residual cannot recover the reserved ETH. |
| Passive accepting beneficiary | One NFT, 1 ETH exercise payment, accepting royalty receiver has no outbound call function. | Third-party release pays 0.05 ETH to the recorded royalty receiver, 0 ETH to caller; 0.95 ETH stays reserved for proceeds. No recipient call occurs during exercise. |
| Refusing royalty beneficiary | One NFT, 1 ETH exercise payment, royalty receiver rejects ETH. | Exercise succeeds with 0.05 ETH royalty and 0.95 ETH proceeds credits. If that contract has no callable withdrawal path, its 0.05 ETH stays reserved and uncollected; the residual cannot take it. |
| Buyer surrender or expiry | One covered NFT right sold or transferred to a buyer; 1 ETH exercise price and 5% committed royalty. A paid surrender test uses a 0.2 ETH premium and 1% trading fee. | Buyer loses the token and gets 0 NFT; issuer recovers 1 NFT. The paid buyer's 0.2 ETH premium is sunk: seller received 0.198 ETH and fee recipient 0.002 ETH. Exercise payment and royalty are both 0 because no exercise occurred. Activation rejects a buyer named as residual. |
| Invalid Pending setup | Issuer creates and deposits one NFT in a Pending account configured with buyer as residual. | Activation rejects. No token or buyer claim is minted. At the deadline anyone finalizes; the configured buyer residual can recover the one NFT with 0 exercise payment. This is a setup loss chosen by the issuer before any transferable entitlement exists. The reference flow checks residual and issuer before deposit; the atomic wallet example reverts the entire invalid setup. |
| Issuer cancellation or buyback | Issuer still holds the token, or buys it back through an ordinary premium sale, then surrenders. | Issuer recovers 1 NFT with 0 exercise payment and 0 exercise royalty. A 0.2 ETH buyback premium pays 0.198 ETH to its listing seller and 0.002 ETH trading fee. |
| Failed delivery | A hostile NFT moves then lies about delivery. | The whole transaction reverts: NFT remains backing, holder retains token and 1 ETH, credits remain zero. |

At the measured local gas units, create plus activate is 359,249 gas paid by the issuer, transfer 71,282 by the holder, premium sale 190,782 by the buyer, exercise 201,511 by the holder, expiry finalization 52,200 by its caller, and NFT recovery 72,939 by the issuer. At a **hypothetical** 1 gwei gas price those costs are 0.000359249, 0.000071282, 0.000190782, 0.000201511, 0.000052200 and 0.000072939 ETH respectively; at 100 gwei they are 100 times higher. A third-party royalty release measured 71,728 gas (0.000071728 ETH at hypothetical 1 gwei, 0.0071728 ETH at 100 gwei), borne by the caller. No test modeled inclusion prices or participant margin. Setup plus activation is 35.9% of a 0.1 ETH primary premium at 100 gwei, so real trading economics require live gas and premium data before launch.

Slither triage: `arbitrary-send-eth` on `Right._call` and `Order.execute` reflects the explicitly authorized handler or terminal recovery call; the right checks `balance - totalCredits`. `locked-ether` on Market reflects value forwarded to an isolated account; a perpetual right can intentionally hold funds indefinitely. `reentrancy-no-eth` on `Right.exercise` and `Order.fill` is bounded by local transient locks; the rights tests reenter transfer, surrender, recovery and exercise and check credit solvency. `reentrancy-events` concerns log order after external calls; state and payout assertions use contract state. Timestamp findings are the explicit deadline policy, tested at the exact boundary. Assembly and low-level calls are the clone argument reader, revert bubbling and authorized ETH transfers. No reported detector established an actionable bypass in the tested supported paths.

Independent read-only AI review of `1283ef5` found four issues. Expired pending setup could strand backing; the core now permits anyone to finalize it at the deadline. The owner resolved the covered NFT dual-role case by requiring issuer-only residual recovery at activation, without changing the generic core. Tests cover buyer surrender, expiry, issuer cancellation and buyback. Ordinary trading handlers intentionally accept exact `Order` clones outside Market (existing test and [NFT_TRADING.md](NFT_TRADING.md)); indexers must check `Market.Created` provenance. At that revision, a passive royalty contract with no outbound function still had a solvent but uncollectible credit; D411 supersedes that payout limitation for accepting receivers. This AI review is not a full or independent human security audit.

A follow-up read-only review of `32d071f` found no active covered-right bypass. It identified the invalid Pending setup destination and the missing sunk premium in the surrender scorecard; both are now tested and disclosed. The handler check remains at activation as the owner specified, and the core's configurable residual rule remains unchanged.

Independent read-only review of `4da3b54` traced the two payout paths, callback reentry, residual reserves and checked issuance; no actionable bypass was found. Review of `402c5c8` verified the multi-account ledger and identified the combined pending/active finalization label, now made explicit. These reviews did not independently rerun the full campaigns.

**Things that don't make sense:** A receiver that both refuses ETH and cannot authorize another destination still cannot collect; a perpetual pending setup with an absent issuer has no deadline cleanup; the no-demand expiry finalizer needs someone willing to pay gas. Issuer-only residual recovery is an address rule and does not track who controls an issuer contract. These require deployment policy or new participant-right decisions if they must be eliminated.

Remaining before a real deployment: independent human security and economic review, live gas and user-margin checks, a real-transaction rehearsal of the redesigned deployment and both rights lifecycles, a current-block fork check, a canary plan and explicit owner authority for any broadcast. The existing `script/rehearse.sh` covers the historical order lifecycle only. No arbitrary handler or external NFT/target is certified by these tests.

## Historical order-only state and evidence

Experimental. The core was merged to `main` on 2026-11-06 (PR #2). PR #3 added the NFT trading handlers and, after a simplification review on 2026-11-10, cut the repository down to the supported release (DECISIONS D301 to D304). PR #4 adds the deployment scripts and developer documentation. **Not audited. Not deployed to mainnet.** No mainnet transaction or paid service has been used.

**Sepolia:** the current release is deployed and verified (2026-11-16): `Market` `0x7c91…1FD4`, `FeeConfig` `0x9A18…06fF` (admin `0xCB43…17F9`, recipient `0xD4ba…7e72`, 1%), `NFTSale` `0xfEf3…a2c8`, `NFTBid` `0x8dbB…017E`, read back after deployment and exercised on a fork pinned after it (`test/fork/SepoliaLive.t.sol`, 7 tests). The admin is the deployer keystore key, by the owner's decision not to use a Safe (residual risk 23). The arena reran onchain against these contracts on 2026-11-16 (all 17 attacks refused, every payout and the 1% fees reconciled to the wei); the lifecycle below ran against the superseded 2026-11-10 contracts and was not rerun. Otherwise the supported release and the PaintAction example are deployed and verified on Sepolia (2026-11-10, from `main` at `865829a`, signer `ripe0x` = `0xCB43…17F9`), and the full lifecycle ran with real transactions: a fixed sale with royalty, a falling sale cancelled and recovered, a persistent rising bid filled twice, topped up, cancelled and recovered, and a PaintAction repaint. On 2026-11-10 and 11 an arena (`script/Arena.s.sol`) traded between separate seller, bidder, holder and royalty contracts, matched a falling sale into a rising bid through an independent matcher, and ran 17 attacks against the live contracts; all were refused and every ETH flow reconciled. Every transaction was dry-run first and read back after. An earlier candidate deployed on 2026-11-06 left `Market`, the implementation and `FillVerifier` (reused) and seven obsolete contracts. Record: [DEPLOYMENT.md](DEPLOYMENT.md#deployment-record).

| Contract | Kind | State |
| --- | --- | --- |
| `Market`, `Order` (`src/`) | Core | `Order` unchanged since PR #2. `Market` records each order's creation time (`createdAt`, D306, 2026-11-16), a recorded core change; this moved `Market`'s address; the new `Market` is deployed on Sepolia (2026-11-16) |
| `NFTSale`, `NFTBid`, `NFTTrade`, `HandlerBase`, `FeeConfig` (`handlers/`) | Supported NFT trading | Unit, fuzz, invariant, composition and mainnet fork tested. Both handlers authenticate their caller (S1, D302) and read the shared `FeeConfig` (D309) for a fee set per order at creation, up to 1%, settable within that cap by a `FeeConfig` admin that also sets a changeable recipient (D305, D307, D309, 2026-11-16); royalty capped at price less fee (D308). Deployed on Sepolia 2026-11-16 |
| `FillVerifier` (`periphery/`) | Optional periphery | Unchanged |
| `PaintAction`, `Artwork` (`examples/`) | Example, not supported for value | Unit tested; pays one payee (D303) |
| `DutchAuction`, `TokenExchange`, `AcquisitionBid`, strategies, `CapitalPool`, demo script | Removed (D301) | History at commit `4598764` |

## Evidence

Candidate: production code at commit `33a5c6d` (the next commit adds two `NFTBid` tests and this file). Toolchain: forge 1.8.1 (`982849d`), solc 0.8.30, EVM Prague, via-IR, 200 optimizer runs. Run 2026-11-10.

| Check | Command | Result |
| --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | Exit 0. 167 passed, 0 failed, 19 suites, including the 14 mainnet fork tests. Fuzz 1,000 runs each. `test/NFTBid.t.sol` then 18 passed with the two added tests. |
| Invariants | `test/Invariant.t.sol` in the full suite | 6 invariants, 128 runs x 64 calls, 0 reverts. About 930 attacker calls and 914 owner attempts on active orders per campaign, none succeeded. |
| Deep invariants | `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-path test/Invariant.t.sol` | All 6 hold, 128,000 calls, 0 reverts. |
| Mainnet fork | `forge test --match-path "test/fork/*"` | 14 passed at block 26,357,000 (BAYC, Azuki, Moonbirds, Opepen, Chimpers, ENS, CryptoPunks); gas in `snapshots/NFTFork.json`. |
| Gas | `forge test --match-path test/Gas.t.sol --isolate` | `snapshots/GasTest.json`, table below. |
| Coverage | `CANDIDATE_RUN=1 forge coverage --ir-minimum --report summary --no-match-coverage 'test\|script\|lib' --no-match-path "test/fork/*"` | 90.1% lines (181/201), 90.5% statements, 90.7% branches (39/43), 100% functions over `src/`, `handlers/`, `periphery/`, `examples/`. Uncovered lines are mostly inline assembly, which `--ir-minimum` does not attribute. Approximate. |
| Sizes | `forge build --sizes` | Runtime bytes: `Order` 2,133, `Market` 1,359 (1,277 before the creation-time record, D306), `FeeConfig` 1,902 (new, D309), `NFTSale` 3,520, `NFTBid` 3,718 (smaller than the 4,345 and 4,613 of D307/D308 now the fee logic lives in `FeeConfig`), `FillVerifier` 1,058, `PaintAction` 1,168, `Artwork` 3,813. Each order clone 149. |
| Compiler and EVM | `forge build --use 0.8.28 --evm-version cancun src handlers periphery examples` | Compiles. |
| Static analysis | Slither 0.11.5, 101 detectors, `src/`, `handlers/`, `periphery/`, `examples/` compiled together | 21 results, none actionable. Triage below. |
| Independent review | AI agent on `69f2455` | Nothing above informational; 9 PoC tests, all refusals (SECURITY.md, fifth review). |
| Deployment gas | `forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co` (simulation) | Supported release 3,682,037 gas, against 6,704,108 for the previous script's eleven contracts (45% less). `examples()`: 424,083. |
| Mainnet fork rehearsal | `script/rehearse.sh https://mainnet.gateway.tenderly.co` | Chain 1 forked at block 26,386,482: Deploy, examples, Lifecycle (fixed sale with royalty, falling sale cancelled and recovered, persistent bid filled twice and topped up, PaintAction) and recover all succeed. |
| Sepolia fork rehearsal | `script/rehearse.sh` | Chain 11155111 forked at block 12,106,569: same, all succeed; `Market` and `FillVerifier` skipped as already deployed. |
| Sepolia deployment | `script/Deploy.s.sol`, `examples()`, `script/Lifecycle.s.sol`, `recover` from `main` | All 29 transactions succeeded; post-state read back (DEPLOYMENT.md). Contracts verified on Etherscan and Sourcify. |
| Sepolia arena | `script/Arena.s.sol` `setup`, `attack`, `settle`, `cleanup` from `main` at `9d0ebe9` | 29 transactions succeeded; 17 attacks refused with the intended errors; payouts sum to the 0.012 ETH the bid paid; all balances end at 0 (DEPLOYMENT.md, Arena). |
| Sepolia live fork | `forge test --match-path test/fork/SepoliaLive.t.sol` at `cd0d369` | 6 passed at block 12,107,304 against the handlers deployed before the fee. Removed with the fee change (their code no longer matches the source); to be rewritten against the redeployed handlers. |
| Fee (D305), superseded by the row below | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `review/*`, and `test/fork/NFTFork.t.sol --isolate` | Evidence for the earlier fixed 0.5% fee (commit `9739154`). All passed on 2026-11-16. `Fee.t.sol` 9 tests: exact split at 1 ETH with 5% royalty (seller 0.945, royalty 0.05, fee 0.005), seller minimum net of fee, royalty above 99.5% refused, refusing fee recipient blocks fills but not recovery, fee recipient cannot reenter, prices under 200 wei pay no fee. The split, the royalty-above-price behaviour and the 200 wei threshold have since changed (D307, D308); see the row below. |
| Settable fee and royalty cap (D306 to D308) | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `Core`, `Clone`, `PaintAction`, `FillVerifier`, `NewOrderType`, `review/*`, `test/fork/NFTFork.t.sol --isolate`, and `test/Gas.t.sol --isolate` | All pass on 2026-11-16 at commit `0a3064a` (binary-search lookup; fee, invariant, sale, bid, gas and fork files rerun after it). Per file: Fee 15, NFTSale 24, NFTBid 18, Compose 6, SharedHandler 5, Invariant (with `setFee` in the fuzz driver: 128 runs, 8,192 calls, 810 `setFee` calls, 0 reverts), Eip7702Filler 4, Core 32, Clone 10, PaintAction 11, FillVerifier 10, NewOrderType 1, `review/*` all pass, mainnet fork 14 (`--isolate`), Gas 6 (`--isolate`). Example split at 1 ETH, 5% royalty, 1% fee: buyer 1, royalty 0.05, fee 0.01, seller 0.94; at 100% royalty: royalty 0.99, fee 0.01, seller 0. Prices under 100 wei pay no fee. Independent AI review of `a867d55` (not an audit): no money or authority defect; its unbounded-scan note was fixed by `0a3064a`, and its doc notes by this revision. **The whole suite (`CANDIDATE_RUN=1 forge test`) was not run at this commit.** |
| Shared `FeeConfig` (D309) | `forge test --match-path` each of `test/Fee.t.sol`, `NFTSale`, `NFTBid`, `Compose`, `SharedHandler`, `Invariant`, `Eip7702Filler`, `Core`, `Clone`, `PaintAction`, `FillVerifier`, `NewOrderType`, `review/*`, `test/fork/NFTFork.t.sol --isolate`, and `test/Gas.t.sol --isolate` | All pass on 2026-11-16 at commit `fc179ad` (fee terms moved to `FeeConfig` with a separate admin and changeable recipient in `bb635b5`; two-step admin handoff in `efeafeb`). Per file: Fee 19 (adds admin-only setters, a recipient change applying to old orders, two-step admin handoff and a withdrawn offer, a refusing recipient being replaceable, and owner recovery while the recipient refuses), NFTSale 24, NFTBid 18, Compose 6, SharedHandler 5, Invariant (fuzz driver now calls `setFee` 736 times and `setRecipient` 691 times; fees checked against the sum of both recipients), Eip7702Filler 4, Core 32, Clone 10, PaintAction 11, FillVerifier 10, NewOrderType 1, `review/*` all pass, mainnet fork 14 (`--isolate`), Gas 6 (`--isolate`). Independent AI review of `bb635b5` (not an audit): no money or authority defect; its one-step-handoff note was fixed in `efeafeb`, and its EOA-admin note is the owner's call (SECURITY.md, 23). **The whole suite (`CANDIDATE_RUN=1 forge test`) was not run at this commit.** |
| Sepolia fee release (2026-11-16) | Broadcast by the owner (`script/Deploy.s.sol`, `ripe0x`); readback with `cast`; `forge test --match-path test/fork/SepoliaLive.t.sol` (fork pinned at block 12,150,234) | 4 transactions succeeded; addresses, sizes and `FeeConfig` settings read back as planned; verified on Etherscan and Sourcify (DEPLOYMENT.md). Live fork: 7 of 7 pass: bytecode matches this build, fee terms, the admin's rate cut binding only later orders and a recipient change binding every fill (1 ETH sales: 0.01 and 0.005 to the new recipient), the arena end to end (every wei returned except 0.000133333333333332 ETH of fees, exactly 1% of its three trades), a royalty receiver refused re-entry, an EIP-7702 wallet buying with `FillVerifier` (seller 0.094, royalty 0.005, fee 0.001), and 64 fuzzed sales conserving ETH. The arena then ran onchain against these contracts (id 2, 31 transactions, all 17 attacks refused, fees 0.000133133333333333 ETH to the recipient, every arena balance 0; DEPLOYMENT.md). The lifecycle script was not rerun |
| Remappings | `forge script script/Deploy.s.sol` with and without OpenZeppelin's nested submodules | Same addresses after `auto_detect_remappings = false` (PR #6); before, a recursive checkout compiled to different addresses. |
| Idempotence | `Deploy.s.sol` broadcast twice to a local mainnet fork | Second run: "No transactions to broadcast". |
| S1 regression | `forge test --match-path test/review/SaleEventPoC.t.sol` | 2 passed; both emitted a false `Sold` before the fix. |

Slither triage. `arbitrary-send-eth` (`Order.execute`): authorized by the lifecycle rules. `arbitrary-send-erc20` (`NFTBid._transfer`): `from` is the authenticated filler. `locked-ether` (`Market`): `create` forwards its ETH into the new order. `reentrancy-no-eth`, `reentrancy-events` (`Order.fill`, both handlers): reentry into the same order is refused by `filling`; events after calls only affect log order. `timestamp`: price schedules are time based by design. `missing-zero-check` (`execute` target): the caller's choice. `assembly`, `low-level-calls`: reviewed (`_arg`, `_isOrder`, `execute`'s revert bubbling, `FillVerifier`'s transient storage).

### Gas

Whole-transaction gas, isolated runs, local mocks (`snapshots/GasTest.json`). Real collections: [NFT_TRADING.md](NFT_TRADING.md#gas).

| Operation | Gas |
| --- | --- |
| Create: NFTSale order | 117,318 |
| Create: NFTBid order, funded | 117,709 |
| Fill: NFTSale, fixed price, no royalty, exact payment | 143,176 |
| Fill: NFTSale, fixed price, no royalty, after one rate change | 150,995 |
| Fill: NFTSale, falling price, royalty, refund | 195,129 |
| Fill: NFTBid, rising collection bid, royalty | 186,861 |
| Fill: NFTBid, last fill closes | 146,770 |
| Fill: PaintAction, paint + resign + close | 109,600 |
| Owner closes | 47,129 |
| Owner withdraws an NFT after closing | 64,080 |

The fill authentication added to `NFTSale` (S1) costs about 2,500 gas per sale fill on the fork. The fee (D305, D307) adds about 12,000 per fill when the recipient already exists, 25,000 more if it does not; moving the fee terms into the shared `FeeConfig` (D309) adds about 5,100 more per fill than the per-handler rate of the previous revision (an external call and its cold storage reads). Recording the creation time (D306) adds about 22,200 to each create (one cold `SSTORE`). Once the rate has been changed, each fill looks up its order's creation time and searches the rate history by binary search: the fixed sale costs 150,995 after one rate change against 143,176 before any.

## Historical release limitations

1. No human audit. AI reviews and Slither only (SECURITY.md).
2. Fork tests impersonate holders; real wallet software and EIP-7702 delegates other than the one Opepen holder's were not exercised.
3. Gas figures are local and fork measurements; real costs depend on calldata, warm or cold accounts and gas price.
4. The full suite ran only on solc 0.8.30 for Prague; 0.8.28 for Cancun was compiled, not tested.
5. Sepolia runs used contracts controlled by one signer and test collections; no third-party wallets, independent fillers or real collections on a public chain.

The historical list above does not establish readiness for the right-enabled candidate. Its remaining checks are listed in the current candidate section at the top of this page.
