# Market: Claude Code instructions

This repository defines a small, independent Ethereum NFT selling product. The product allows a holder to authorize a price that declines over time and automatically sell to a compatible existing onchain offer once the seller's conditions can be met. It is unrelated to CC and must not inherit CC's contracts or tokenomics.

Read, in order: `CLAUDE.md`, `docs/FUNCTIONAL_SPEC.md`, `docs/ROADMAP.md`, `docs/DECISIONS.md`, and `docs/STATUS.md`. Treat these documents as the current product baseline, then challenge and refine technical assumptions using evidence. Begin implementation immediately after reading. Do not end at a plan.

## Engineering mandate

1. Complete the project: contracts if needed, realistic fork integrations, matcher, frontend, tests, economic and gas analysis, operations, and deployment preparation.
2. Use Ponytail from the official `DietrichGebert/ponytail` plugin if available. If unavailable, use its central principle: understand existing code, prefer native platform features and established protocols, write the least code that works, and remove unnecessary abstractions. Do not apply shortcuts to security, accessibility, or money handling.
3. Before implementing an exchange, test whether Seaport's native dynamic orders plus standard fulfillment can do the job. Write only the smallest security boundary that real settlement constraints require.
4. Never mistake a mocked bid for a proven OpenSea integration. Reproduce supported real signed offers on a pinned Ethereum mainnet fork. Check order types, criteria, zones, approvals, royalties, net proceeds and actual calldata.
5. Protect the seller first: exact NFT and proceeds recipient, authenticated price curve, minimum net proceeds, replay and cancellation protection, atomic settlement, explicit fees, and no permission to extract other user assets.
6. Make ordinary decisions yourself. For consequential choices select a simple reversible approach, record options, rationale, evidence and implications in `docs/DECISIONS.md`, add to Owner Review, and keep working. Don't pause for repeated permission requests.
7. Revise the spec when a real constraint invalidates an assumption. Simplify the product instead of accumulating adapters and fallback layers to preserve optional ideas.
8. Test adversarially, use independent security review agents where useful, fix findings, and maintain real evidence and unresolved limitations in the repository.
9. Keep `docs/STATUS.md` accurate; make small local commits; document exact commands, tests, gas and economic assumptions, and next actions so another session can continue.
10. Research, code, simulate and prepare deployment locally. No real asset transactions, mainnet deployment, signing with a funded key, paid services, public launch, or remote push without the owner's explicit permission.

## Definition of done

A usable app and runnable keeper, reproducible mainnet fork tests of actual integrations, documented contract permissions and security properties, operations and deployment instructions, deployment scripts in dry run mode, verified economic feasibility bounds, and a precise residual risk list. Never label the system safe or audited based solely on passing unit tests.

If an API key, RPC or service blocks a test, implement all independent paths and document the exact blocker and reproduction procedure. Don't fabricate evidence or quietly replace real integration tests with mocks.

At natural milestones report concisely what is implemented, what passed, assumptions that changed, and decisions the owner may want to review.
