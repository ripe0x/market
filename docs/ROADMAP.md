# Roadmap

Execute the phases in order except for independent work that can proceed while external dependencies are blocked. Each phase ends only with code, tests, records and a status update. A plan alone is not a deliverable.

## Phase 0: real integration and architecture decision

1. Configure Foundry and a pinned Ethereum mainnet fork.
2. Find an active real signed OpenSea item offer and collection offer with actual calldata and authentication; record reproducible identifiers and environment prerequisites.
3. Demonstrate execution with a seller controlled NFT, dynamic declining price, correct WETH proceeds, real Seaport fees and royalties, and no ability to capture unallocated surplus.
4. Test standard Seaport matching before designing custom settlement. Try a minimal wrapper only if necessary. Verify cancellation and the true constraints of noncustodial approvals.
5. Produce `docs/PHASE0_EVIDENCE.md`: successful transactions, exact assertions and gas, limitations and chosen architecture. If unavailable, document exact blockers and fallback investigation without declaring the gate passed.

Acceptance: real integration executable on a fork, accurate seller net accounting and a justified smallest architecture. If the exact proposed route is impossible, revise the scope and document the evidence before proceeding.

## Phase 1: settlement

1. Implement only the required seller signing, pricing, cancellation and atomic settlement code.
2. Implement direct buy if not natively covered by the chosen Seaport path.
3. Bind all authorization terms, compute seller proceeds correctly, distribute any external offer surplus, and prevent residual custody.
4. Fuzz pricing and authorization; adversarially test reentrancy, replay, expiration, double fills, signatures, royalties, restricted bids, and conflicting transactions.
5. Record deployed canonical dependencies and a reproducible dry run deploy script.

Acceptance: all invariants and fork tests pass; no unbounded admin authority over listed NFTs or seller funds.

## Phase 2: offer discovery and keeper

1. Implement a small TypeScript matcher for supported OpenSea bids, minimal signed order storage and event sync.
2. Fetch, validate, score, simulate and submit only eligible and profitable fills.
3. Handle rate limits, stale or canceled orders, idempotent restarts, replaced transactions and reorgs.
4. Permit anyone to execute, with fee/reward payouts enforced in settlement.
5. Measure execution gas and fee viability at multiple NFT prices and gas conditions; adjust provisional settings with recorded evidence.

Acceptance: real order fixture replays and a fork keeper integration prove a complete fill; failure modes do not lose seller funds.

## Phase 3: usable product

1. Responsive wallet based create listing flow with clear seller net minimum, schedule, expiry, fee preview and warning for zero floor.
2. Simple public browse and listing detail with direct buy.
3. Seller list of active and completed sales, order validity and onchain cancellation.
4. Human readable pending, reverted, expired, canceled and sold states; no false promise of guaranteed sale or highest market bid.
5. Functional end to end tests for the actual user flows and permission prompts.

Acceptance: a new user can complete a local fork sale end to end without CLI steps.

## Phase 4: reliability, independent review and simplification

1. Run unit, invariants, fuzz, full fork and UI end to end suites from clean checkout.
2. Have an independent reviewer examine exact settlement code and keeper risk; address actionable findings and record unresolved risks.
3. Run Ponytail review to remove unnecessary code, dependencies and abstractions while keeping all security tests.
4. Publish a factual gas and economic report, check service recovery, logs, order expiration and confirmation handling.
5. Update operational and security documentation with precise dependencies and installation commands.

Acceptance: reproducible green tests and review reports; known risks and out of scope cases explicitly documented.

## Phase 5: launch preparation, no launch

1. Produce a minimal deployment runbook, address verification checklist, config template, emergency pause/disable guidance where applicable, key management guidance and dry run deploy artifacts.
2. Provide exact commands for development, test, mainnet fork replay, web build, keeper start, shutdown and backup.
3. Complete `docs/STATUS.md` with work completed, outstanding blockers, risk classification, owner review decisions and deployment readiness.

Acceptance: deployable artifacts are prepared and tested, but nothing has been deployed, funded, made public or pushed to remote without explicit owner permission.
