# Decision log

Status labels: Baseline means recommended product direction for implementation. Provisional means an engineering choice to validate and improve using evidence. Deferred means intentionally out of scope. Any change must include a date, evidence and consequence. Keep the Owner Review section current while working independently.

| ID | Status | Decision | Reason and alternatives |
| --- | --- | --- | --- |
| D001 | Baseline | Independent Ethereum mainnet ERC721 product | Avoid copying CC mechanics or building an ERC20 exchange. |
| D002 | Baseline | Seller chooses linear declining minimum NET WETH proceeds with optional nonzero floor, expiry and explicit zero floor opt in | Simple user control; clear safety constraint. Alternative gross price hidden fees was rejected. |
| D003 | Baseline | Noncustodial signed authorization, onchain cancellation and atomic fulfillment | Seller keeps NFT before fill and has enforceable terms. |
| D004 | Baseline (2026-10-30) | Native Seaport listing restricted to zone = Market; Market is the only fulfiller and splits the surplus | Native matching cannot route surplus to the seller (unspent items go to a caller-chosen recipient). Seaport skips zone checks only when the caller is the zone, so one small zone contract closes the gap. See D015. |
| D005 | Baseline | Start with OpenSea item and collection bids; trait offers later if straightforward | Existing liquidity without own bid infrastructure; avoid promising universal marketplace support. |
| D006 | Baseline (2026-10-30) | Keep 0.30% executor + 0.20% protocol on matches; 0.20% protocol on direct buys, paid by the buyer | Measured: match viable from about 0.064 WETH at 0.4 gwei, 0.48 at 3 gwei. See `ECONOMICS.md`. |
| D007 | Baseline | Seller receives the entire net of the selected offer after mandatory external considerations and authorized fees | Don't let executor quietly capture surplus. |
| D008 | Baseline | Keeper run by protocol plus permissionless execution | Product stays usable if our worker stops; executor reward comes from disclosed fees. |
| D009 | Baseline (2026-10-30) | One Next.js app plus one keeper process sharing a SQLite file through Node's built-in `node:sqlite` | Zero database dependency. Chain is the source of truth; storage holds signed orders, synced sales and the keeper's in-flight tx. Needs a host with a persistent disk. |
| D010 | Deferred | ERC20 swaps, cross chain, new token, full NFT marketplace and complex auctions | Distract from the validated seller problem and duplicate established systems. |
| D011 | Baseline | No authority for founder to take NFTs or seller proceeds; prefer a replaceable stateless version over upgradeable custody | Upgradeability should not create an extraction backdoor. |
| D012 | Baseline | Mainnet fork and actual signed Seaport orders required before claiming integration success | Mocks do not test real zones, signatures and consideration. |
| D013 | Baseline | Sellers may get a better price than their current minimum, but app cannot promise globally best price or guaranteed sale | Market data is incomplete and execution is competitive. |
| D014 | Baseline (2026-10-30) | Sellers are paid in WETH. Direct buyers pay ETH; Market wraps it. Overpayment returns as WETH | ETH payment removes a buyer approval transaction. See D017 for the refund token. |
| D015 | Baseline | Market contract: zone and sole fulfiller, no owner, no upgrade, no pause, fees as constants, one immutable protocol recipient | Options: native match only (fails surplus routing), custom EIP-712 authorization with NFT custody in our contract (new approval per seller, new signing scheme, custody during the tx, breaks for operator-restricted collections), Seaport zone (chosen). Evidence: `PHASE0_EVIDENCE.md`. Rollback: deploy a new version; old listings stay bound to the old zone until they expire or are cancelled. Owner review recommended. |
| D016 | Baseline | Price falls linearly from start to floor and the listing ends when it reaches the floor; no hold at floor | Seaport's native interpolation covers the whole order window. A hold would need either a second signed order or a custom price check that wallets would show as an opaque zone hash. Relisting is a free signature. Revisit if sellers ask for long floor holds. Owner review recommended. |
| D017 | Baseline | Direct-buy overpayment is returned as WETH, not ETH | Found on the fork: an ETH refund call into an EIP-7702 delegated buyer ran out of gas. A WETH transfer never runs buyer code, removes a reentrancy surface and a revert path. Cost: buyers may receive small WETH amounts. |
| D018 | Baseline | Listings use the OpenSea conduit key | Most sellers in established collections already approved it, so listing is usually signature-only; conduit transfers also suit operator-restricted collections. The approval is shared with OpenSea and outlives cancellation; the UI says so. Alternative: conduit key 0 (approve Seaport directly). |
| D019 | Baseline | Proceeds recipient is the seller | Simplest safe binding; the API rejects other recipients. Market itself pays surplus to whatever recipient the seller signed. |
| D020 | Baseline | Supported offers: Seaport 1.6, single WETH offer item, ERC721 item offers and criteria-0 collection offers, WETH-only fee items. Trait offers excluded | Trait offers need proofs; non-WETH items would strand value. Market enforces the WETH offer; the keeper enforces the rest. |
| D021 | Provisional | OpenSea API key is required for matching and wallet NFT lists | Keyless responses are only served for cached URLs. Without a key the app still lists, buys, cancels and reads art from tokenURI; the footer shows matching off. |
| D022 | Baseline | Keeper submits one transaction at a time; a stuck one is replaced by a zero-value self transfer at the same nonce | OpenSea zone signatures expire in minutes, so re-sending old calldata is pointless. Simple nonce handling and idempotent restarts. |
| D023 | Recommended, pending owner approval (2026-10-30) | Live offer matching needs the fulfiller to own the NFT when OpenSea signs. Recommendation: escrow, so the seller deposits the NFT into Market and every listing, fixed or declining, sells from custody | Evidence (`PHASE0_EVIDENCE.md`, escrow and venue investigation): OpenSea signed for 45 of 48 contracts that hold the NFT, including one deployed about 10 hours earlier, and refused 2 for account restrictions. A deposit is visible to OpenSea within 2 to 8 seconds. There is no meaningful noncustodial liquidity outside OpenSea: Blur needs its own server signature, and unrestricted Seaport bids and LooksRare had 0 fills in 24 hours. Options: (a) escrow for all listings, which reverses D003 and D011, makes listing a transaction, and makes Market a custody target, so the audit becomes critical; (b) direct buy only, which keeps listings noncustodial and drops automatic matching; (c) an EIP-7702 seller account, rejected as too complex. One custody model only: a fixed price is a declining listing whose start equals its floor. Residual risk: OpenSea may refuse Market's own address; only a mainnet canary can prove it. Owner review required. |

## Owner Review

Review these after the engineering agent has selected and implemented the simplest verified approach. The agent should record its final recommendation and alternatives without stopping to request ordinary approval.

1. D004/D015: Native Seaport alone cannot route surplus. Recommendation: the Market zone contract, about 150 lines, no admin. Approve the design before any independent audit is commissioned.
2. D006: 0.5% total is viable from about 0.064 WETH at today's 0.4 gwei, about 0.48 WETH at 3 gwei. Recommendation: keep it and let the keeper skip small fills; no contract minimum.
3. D009: One host, Next.js plus keeper, SQLite file. Recurring cost: host, RPC, free OpenSea key.
4. D014/D017: Buyers pay ETH, sellers receive WETH, buyer overpayment returns as WETH. Confirm the WETH refund is acceptable.
5. D016: No floor hold. Confirm, or ask for a second signed floor order.
6. D023: **Blocking.** OpenSea signs offers only for the NFT's owner. Investigation supports escrow for all listings (recommended) over direct buy only. Approve before the contract is redesigned. The final proof that OpenSea accepts Market's address needs a mainnet canary with one low-value NFT, which needs separate owner authorization.
7. Protocol fee recipient address for deployment, and who controls it.
8. Review findings and launch blockers: `SECURITY.md`.

## Instructions for future decisions

Each subsequent decision should state ID, date, question, options, selection, reasons, evidence or test, rollback cost, status and whether owner review is recommended. When a decision changes an existing document, update `FUNCTIONAL_SPEC.md`, `ROADMAP.md` and `STATUS.md` to match. No unapproved live deployments or expenditures.
