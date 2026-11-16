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

Approved by the owner on 2026-11-16 ("go with your recs"). P is the schedule price at the fill, R the ERC2981 royalty capped at P − F, F the fee: the rate locked to the order when `Market` created it, at most 1% of P, rounded down (D306, D307). Changing any line voids its approval: O2, O3, O4 and O9 were revised for the earlier fixed 0.5% fee (D305), and O2, O3, O4, O5 and O9 were revised again on 2026-11-16 for the settable fee and the royalty cap (D306 to D308); the owner approved the revised O2, O3, O4, O5 and O9 on 2026-11-16 ("approved").

| # | Outcome | Number |
| --- | --- | --- |
| O1 | The sale buyer pays exactly the current price, never more; any overpayment is refunded in the same transaction, and the buyer can set a maximum price. | Buyer's net spend = P. Refund = amount sent − P. |
| O2 | Sale money goes only to the seller, the royalty receiver and the fee recipient. The royalty is the collection's ERC2981 amount, capped at P − F and never above the seller's royalty cap. The order ends empty. | Seller P − F − R, receiver R, fee recipient F, order 0 ETH and 0 tokens. Example at P = 1 ETH, 5% royalty, 1% fee: seller 0.94, receiver 0.05, fee recipient 0.01. |
| O3 | A bid never spends more than it holds. Each fill pays the current price; the seller gets at least their minimum, net of royalty and fee. The bid closes after its last allowed fill. | Total spent ≤ deposited. Seller P − F − R ≥ their minimum. |
| O4 | `Market` takes nothing and has no owner or admin; it only records each order's creation time (D306). The fee terms for `NFTSale` and `NFTBid` live in a shared `FeeConfig` with a separate admin and recipient (D309): the rate starts at 1%, the admin alone can change the rate up to a 1% cap and change the recipient, and each order keeps the rate in force when it was created. The admin need not be the recipient, and both are changeable by the admin. | `Market` 0%, holds 0 ETH. NFT handlers F = the order's locked rate × P, at most 1% of P. |
| O5 | The royalty is paid up to what the fee leaves (P − F) and is never silently dropped: a collection asking more is paid that capped amount, not zero, and the fill settles. The fill still fails, and the owner can close and recover, if the lookup reverts, the receiver refuses ETH, or a nonzero royalty names no receiver. A royalty above the sale seller's cap (checked against the capped amount) also fails. | 0 fills settle with the royalty dropped to zero. A royalty above P − F is paid as P − F. |
| O6 | The owner can always recover everything, and nobody else can. Nothing is returned automatically. | 100% recoverable. Close 47,129 gas, NFT withdrawal 64,080 gas. |
| O7 | Accepted gaming: a bid open to any token pays its full price for the cheapest token; a matcher between a falling sale and a rising bid keeps the gap. | Sepolia arena: matcher kept 0.0047 of a 0.006 bid. |
| O8 | `NFTBid` moves a token only when its holder is filling. Holders choose per-token approval or approval for all (decision 7). | 0 tokens moved without the holder filling. |
| O9 | Users pay gas, and sellers the fee (at most 1%) out of the price. | Create about 117,000 gas (NFTSale 117,318, NFTBid funded 117,709; about 22,000 more than before D306 for the creation-time record). Sale fill 143,176 (fixed, no royalty) to 195,129 (falling, royalty, refund). Bid fill 146,770 (last fill, closes) to 186,861 (rising, royalty). Reading the shared `FeeConfig` adds about 5,100 per fill over the previous revision (D309). After one rate change a fill costs about 7,800 more (150,995 for the fixed sale), growing only with the logarithm of the number of changes. Mainnet cost measured at the canary. |
| O10 | Nothing restarts on its own; there is no keeper. A stuck order stays until its owner closes it. | 0 automatic actions. |

## Decisions

- 2026-11-16: owner review items 1, 3, 4, 7 and 8 resolved as recorded in [docs/DECISIONS.md](docs/DECISIONS.md#owner-review).
- 2026-11-16: the owner chose a fixed fee in `NFTSale` and `NFTBid` ("why not have the fee in the nft contracts? ... not a market protocol fee, but there is one on those things that run on it") at 0.5% (D305). R2's "protocol fees" is read as applying to the `Market` core.
- 2026-11-16: the owner raised the fee to 1% and made it updateable, capped at 1% ("set fees to 1%"; "the fee should be updateable post-deploy, but capped at 1%"), to live on the shared handler rather than each order ("the updateable fee should only be on the factory, not on the deployed contracts"), with the recipient unchanged ("keep the fee recipient as is"). The owner chose option "B": each order pays the rate in force when it was created, and `Market` records each order's creation time (D306, D307). Recording the time in `Market` is a core change under CLAUDE.md rule 2; it moves `Market`'s address, so the Sepolia `Market` must be redeployed. R2's "protocol fees" still reads as applying only to the `Market` core, which takes nothing.
- 2026-11-16: the owner capped royalties instead of letting a high one revert the fill ("having a high royalty brick it is not acceptable"; "we should just cap royalties at 99% then or 100% - our fee"). A royalty above `price − fee` is now paid as `price − fee` and the fill settles (D308). This narrows R5 and O5: "never skipped" now means the royalty is paid up to what the fee leaves, not in full when the collection asks more.
- 2026-11-16: the owner approved the revised outcomes O2, O3, O4, O5 and O9 ("approved").
- 2026-11-16: the owner made the fee recipient editable post-deploy and separate from the admin, moving the fee terms into a shared `FeeConfig` ("the fee recipient shouldn't be required to be the same as the admin."; "can the order contracts call the factory or something to get the fee recipient? so it can remain editable post-deploy?"), with fee recipient `0xD4ba7cA95f3983514DDa317C4428CDb8F59c7e72` and admin/deployer `0xCB43078C32423F5348Cab5885911C3B5faE217F9` (D309). This reverses the earlier "keep the fee recipient as is" (D307). `Market` stays ownerless and fee-free, so the terms live in `FeeConfig`, not `Market` (R2, rule 2). O4 and O9 are revised again by this change and await the owner's confirmation.
- 2026-11-16: the owner approved the revised O4 and O9 for the shared `FeeConfig` (D309) ("Confirm both").
