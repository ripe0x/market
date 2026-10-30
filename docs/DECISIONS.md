# Decision log

Status labels: Baseline means recommended product direction for implementation. Provisional means an engineering choice to validate and improve using evidence. Deferred means intentionally out of scope. Any change must include a date, evidence and consequence. Keep the Owner Review section current while working independently.

| ID | Status | Decision | Reason and alternatives |
| --- | --- | --- | --- |
| D001 | Baseline | Independent Ethereum mainnet ERC721 product | Avoid copying CC mechanics or building an ERC20 exchange. |
| D002 | Baseline | Seller chooses linear declining minimum NET WETH proceeds with optional nonzero floor, expiry and explicit zero floor opt in | Simple user control; clear safety constraint. Alternative gross price hidden fees was rejected. |
| D003 | Baseline | Noncustodial signed authorization, onchain cancellation and atomic fulfillment | Seller keeps NFT before fill and has enforceable terms. |
| D004 | Provisional | Test standard Seaport dynamic listings and native match before any custom contract | Native protocol can reduce new attack surface. Must prove surplus routing on a real fork. |
| D005 | Baseline | Start with OpenSea item and collection bids; trait offers later if straightforward | Existing liquidity without own bid infrastructure; avoid promising universal marketplace support. |
| D006 | Provisional | 0.50 percent total fee on net available offer proceeds after mandatory external considerations, divided 0.30 percent to executor and 0.20 percent to protocol | Aligns sellers and makes independent execution possible; real gas economics may require change. |
| D007 | Baseline | Seller receives the entire net of the selected offer after mandatory external considerations and authorized fees | Don't let executor quietly capture surplus. |
| D008 | Baseline | Keeper run by protocol plus permissionless execution | Product stays usable if our worker stops; executor reward comes from disclosed fees. |
| D009 | Provisional | One small web app, one worker, minimal durable order store | Avoid premature infra; decide database and hosting after a working prototype. |
| D010 | Deferred | ERC20 swaps, cross chain, new token, full NFT marketplace and complex auctions | Distract from the validated seller problem and duplicate established systems. |
| D011 | Baseline | No authority for founder to take NFTs or seller proceeds; prefer a replaceable stateless version over upgradeable custody | Upgradeability should not create an extraction backdoor. |
| D012 | Baseline | Mainnet fork and actual signed Seaport orders required before claiming integration success | Mocks do not test real zones, signatures and consideration. |
| D013 | Baseline | Sellers may get a better price than their current minimum, but app cannot promise globally best price or guaranteed sale | Market data is incomplete and execution is competitive. |
| D014 | Provisional | Default to simple native WETH accounting; only add ETH convenience if easy and safe | Reduces settlement paths and ambiguity about token delivered. |

## Owner Review

Review these after the engineering agent has selected and implemented the simplest verified approach. The agent should record its final recommendation and alternatives without stopping to request ordinary approval.

1. D004: Was native Seaport settlement sufficient? If not, exactly what additional contract was proven necessary?
2. D006: Is a 0.50 percent fee with a 0.30/0.20 split economically viable at measured gas rates? Should the minimum supported sale amount be limited?
3. D009: Which hosting and database option was selected and why? Any recurring operating cost?
4. D014: Is WETH only sufficiently clear for the initial user experience, or does ETH convenience materially simplify it?
5. Actual audit findings, permissions and unresolved major launch blockers, if any.

## Instructions for future decisions

Each subsequent decision should state ID, date, question, options, selection, reasons, evidence or test, rollback cost, status and whether owner review is recommended. When a decision changes an existing document, update `FUNCTIONAL_SPEC.md`, `ROADMAP.md` and `STATUS.md` to match. No unapproved live deployments or expenditures.
