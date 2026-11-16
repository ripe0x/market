# Owner requirements

The owner's own words, numbered and dated, each pointing at the outcome that measures it. Later decisions are appended, never rewritten. Build and audit requests point here.

## Requirements

From the owner's brief, 2026-11-10.

| # | Owner's words | Measured by |
| --- | --- | --- |
| R1 | "Finish preparing Market as a small, permissionless Ethereum protocol for trading authorized onchain executions." | O4, O10 |
| R2 | "Do not introduce a global execution lock, intent solver network, privileged registry, protocol fees, token, upgradeability, or shared custody." | O4 |
| R3 | "Do not combine NFTSale and NFTBid merely to reduce the number of contracts." | D304 |
| R4 | "Do not remove ERC2981 royalty support or the buyer and seller protections already implemented." | O1, O2, O3, O5 |
| R5 | "ERC2981 royalties, paid atomically and never silently skipped." | O2, O5 |
| R6 | "Explicit buyer expenditure and seller proceeds limits." | O1, O3 |
| R7 | "Safe cancellation and asset recovery." | O6 |
| R8 | "The shared approval authority must be described accurately." | O8 |
| R9 | "Do not treat emitted events or successful external calls as proof of an economic outcome without considering their authenticity." | O8, D302 |
| R10 | "Do not deploy to mainnet without my explicit authorization." | DEPLOYMENT.md checklist |

Deployment rules, 2026-11-10: deploy only from `main`, sign with `--account ripe0x`, use Tenderly's public gateways on every chain, never a Ledger.

## Approved outcomes

Approved by the owner on 2026-11-16 ("go with your recs"). P is the schedule price at the fill, R the ERC2981 royalty. Changing any line voids its approval.

| # | Outcome | Number |
| --- | --- | --- |
| O1 | The sale buyer pays exactly the current price, never more; any overpayment is refunded in the same transaction, and the buyer can set a maximum price. | Buyer's net spend = P. Refund = amount sent − P. |
| O2 | Sale money goes only to the seller and the royalty receiver. The royalty is the collection's ERC2981 amount, never above the seller's royalty cap. The order ends empty. | Seller P − R, receiver R, order 0 ETH and 0 tokens. |
| O3 | A bid never spends more than it holds. Each fill pays the current price; the seller gets at least their minimum, net of royalty. The bid closes after its last allowed fill. | Total spent ≤ deposited. Seller P − R ≥ their minimum. |
| O4 | The protocol takes nothing: no fee, no owner, no admin. | 0% fee. `Market` holds 0 ETH. |
| O5 | The royalty is never skipped. If it cannot be paid (failing lookup, receiver refuses ETH, above the seller's cap), the fill fails and the owner can close and recover. | 0 fills settle without the full royalty. |
| O6 | The owner can always recover everything, and nobody else can. Nothing is returned automatically. | 100% recoverable. Close 47,129 gas, NFT withdrawal 64,080 gas. |
| O7 | Accepted gaming: a bid open to any token pays its full price for the cheapest token; a matcher between a falling sale and a rising bid keeps the gap. | Sepolia arena: matcher kept 0.0047 of a 0.006 bid. |
| O8 | `NFTBid` moves a token only when its holder is filling. Holders choose per-token approval or approval for all (decision 7). | 0 tokens moved without the holder filling. |
| O9 | Users pay only gas. | Create about 95,000 gas. Sale fill 121,094 to 173,042. Bid fill 124,749 to 164,840. Mainnet cost measured at the canary. |
| O10 | Nothing restarts on its own; there is no keeper. A stuck order stays until its owner closes it. | 0 automatic actions. |

## Decisions

- 2026-11-16: owner review items 1, 3, 4, 7 and 8 resolved as recorded in [docs/DECISIONS.md](docs/DECISIONS.md#owner-review).
