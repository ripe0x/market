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
- 2026-11-16: the owner will not use a Safe ("i'm not using safe"). The `FeeConfig` admin stays the keystore key `0xCB43078C32423F5348Cab5885911C3B5faE217F9`; its powers and the mitigation are in SECURITY.md, residual risk 23.

## Transferable rights direction, 2026-11-17

The owner explicitly approved a new product direction and core architecture in the 2026-11-17 brief. These requirements supersede earlier order-only design decisions where they conflict. The historical order outcomes O1–O10 above remain the approved outcomes for **ordinary orders and their NFT trading handlers**. In particular, O6's owner recovery applies to a cancelable order, not to an active right; O4's statement that Market only records order creation time is historically true of that release, not the redesigned core. The right economics below are **prospective acceptance outcomes from the new brief**, not a newly signed numeric release scorecard.

| # | Owner's words | Acceptance outcome |
| --- | --- | --- |
| R11 | "Someone should be able to acquire the right to perform an onchain action, hold that right, sell it to somebody else, or eventually exercise it." | O11, O12 |
| R12 | "Acquiring or transferring the right must not execute the underlying action." | O11 |
| R13 | "While a right remains live, its original issuer cannot withdraw the backing or change the committed terms through Market. The holder can transfer the entitlement, but cannot bypass its exercise conditions to take the backing." | O12, O13 |
| R14 | "An order is a cancelable offer to exchange something or perform an immediate transaction. A right is a transferable entitlement to execute a committed operation later." | O11, O14 |
| R15 | "Token ownership must be the authoritative source of who currently holds the right." | O12 |
| R16 | "For the first version, implement one successful exercise per right." | O12 |
| R17 | "A right with a deadline must become unexercisable at that deadline even if nobody submits a finalization transaction." | O13 |
| R18 | "A beneficiary refusing eth must not veto an otherwise valid supported exercise." | O15 |
| R19 | "Do not automatically apply the underlying nft's royalty policy to every resale of a right token." | O16 |
| R20 | "Do not deploy contracts, broadcast transactions, use real assets, merge into main, or push changes without explicit authorization." | Local-only delivery |
| R21 | "Require residualBeneficiary == issuer when activating a covered nft right, using the account’s authenticated, immutable issuer"; "Keep the core’s configurable residual beneficiary." | O18, D410 |

| # | Prospective outcome | Number and asset destination |
| --- | --- | --- |
| O11 | Issue, sell, resell and exercise or expire a backed right without moving its backing during transfers. | 1 backing account per token; 0 underlying actions on acquisition or transfer. |
| O12 | Holder authority comes from the canonical token; issuer has no privileged active recovery; successful exercise consumes it. | 1 active token per right; at most 1 successful exercise; 0 live issuer withdrawals or holder bypasses. |
| O13 | Time and terminal rules apply without a keeper. | At `timestamp >= deadline`, 0 exercises and 0 live transfers; anyone may finalize. `deadline = 0` is perpetual. |
| O14 | Canceling a sale listing leaves the underlying right intact. | 1 token returned to listing owner; 0 changes to right config, activation terms or deadline. |
| O15 | Covered NFT exercise credits payment beneficiaries without requiring callbacks and reserves the liability. | If exercise price is P and committed royalty R, credit R to royalty recipient and P − R to proceeds beneficiary; terminal recovery may take only `balance − totalCredits`. Exact payment P. |
| O16 | Premium and exercise economics are separate. | Primary or resale premium L pays the ordinary trading fee F and no underlying NFT royalty; listing seller receives L − F. One exercise payment P carries one committed royalty R and no trading fee. Ordinary direct NFT sales retain historical O1–O5. |
| O17 | Reserved artwork action is target enforced, including through artwork transfer. | 1 allowed modification, 0 artwork ownership transfer, 0 owner revocations or replacements of a live reservation. No permanent color guarantee. |
| O18 | Covered NFT activation requires the immutable issuer as residual beneficiary. Buyer surrender or expiry releases collateral to that issuer; issuer surrender while holding or after buyback remains allowed. | 0 activations with non-issuer residual; buyer receives 0 NFT and pays 0 exercise ETH after surrender or expiry; issuer recovers 1 NFT. A successful 1 ETH exercise at 5% committed royalty credits 0.05 ETH royalty and 0.95 ETH proceeds. Surrender and expiry create 0 exercise royalty. |

No exact gas, premium, exercise price, royalty rate, deadline length or release cap is approved here; those depend on a particular right and the release candidate. The economic scorecard must supply concrete launch-scale examples and measured gas before a real deployment decision.

The historical O9 gas measurements do not apply to the right-enabled bytecode. D409 and [STATUS.md](docs/STATUS.md) record the current measured costs; O1–O5 payment destinations and the 1% NFT trading fee remain unchanged.
