You're taking over full implementation of Market as the lead engineer and technical partner.

Work in the ripe0x/market repository. Start by reading CLAUDE.md, docs/FUNCTIONAL_SPEC.md, docs/ROADMAP.md, docs/DECISIONS.md, and docs/STATUS.md. These documents define the product and starting decisions. Treat their technical claims as hypotheses until verified.

Your objective is a complete, small, usable and thoroughly tested Ethereum NFT selling product. A seller signs an order whose minimum net price declines over time. Buyers can purchase directly, and an automated matcher can settle against compatible existing OpenSea offers. The seller receives the actual net proceeds of the selected offer, after explicit fees, including any surplus over the seller's current minimum. The seller retains custody until execution.

Begin actual implementation immediately. Do not stop after producing a plan.

Use Ponytail from the official DietrichGebert/ponytail project to find the simplest safe solutions. If it is not installed, follow the official installation instructions if your environment permits it. Otherwise apply its principles directly. Prefer Seaport and existing tooling to new contracts, dependencies, infrastructure and abstractions.

Start with Phase 0. Prove on a pinned Ethereum mainnet fork that an authentic signed OpenSea item or collection offer can be matched atomically against a declining seller authorization, with correct criteria, approvals, fees and seller proceeds. Record exact evidence. Test native Seaport functionality first. If it cannot enforce the seller's minimum and surplus distribution, build only the smallest additional settlement contract necessary. Never substitute a mock for proof of a real integration.

Then complete settlement, signing, cancellation, direct purchases, permissionless matching, the automated worker, responsive frontend, order storage, tests, economic analysis, security review, documentation and dry run deployment preparation. Keep the launch product focused. No native token, CC integration, general ERC20 exchange, multichain architecture, elaborate marketplace or speculative features.

Own the work autonomously. Make normal engineering and product decisions without asking me. When an assumption fails, choose the simplest safe solution that preserves the intended seller experience. Challenge economics and security, independently review important paths, run real fork and adversarial tests, fix findings and remove unnecessary complexity.

For material decisions, write your choice, alternatives, tradeoffs, evidence and reversibility into docs/DECISIONS.md and maintain its Owner Review section for me to read later. Do not block the project waiting for my input. If a missing external credential or service blocks one task, record the exact blocker and continue every independent task. Never invent passing tests or claim that an integration works when it has not been executed.

Make small local commits. Keep docs/FUNCTIONAL_SPEC.md, docs/ROADMAP.md and docs/STATUS.md aligned with the implemented system. At meaningful milestones give concise reports of what actually works, tests passed, key risks and decisions for my eventual review.

You may research, code, test, run read only RPC queries, simulate on mainnet forks and prepare deployment artifacts. Do not deploy to mainnet, transact with real assets, spend funds, launch publicly, or push remote commits without my explicit authorization.

Start now with Phase 0 and continue through all phases. Your responsibility is a working, reviewable, deployment ready system, not a set of recommendations or an unfinished scaffold.
