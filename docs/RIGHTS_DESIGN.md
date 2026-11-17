# Transferable rights design (2026-11-17)

This note precedes implementation. The new object is a one-use entitlement, separate from a cancelable `Order`. Ordinary `Order.fill` and `Order.close` keep their existing meaning. Buying a right token transfers an entitlement; only `Right.exercise` performs its committed operation.

| Role | Authority |
| --- | --- |
| Issuer | Creates a pending right and supplies backing from outside its account. May cancel pending setup. Has no special power after activation. Initially receives the token. |
| Holder | `Rights.ownerOf(id)` is the sole live holder source. May transfer or surrender, and alone may initiate exercise. Transfer approval can transfer this economically valuable claim but cannot exercise it. |
| Exercise handler | Validates required backing and fixed effective terms at activation. During one authorized exercise only, it may make calls through the right account and credit payment beneficiaries. It does not control terminal recovery. |
| Residual beneficiary | Fixed at creation. After cancellation, surrender, expiry finalization, or exercise, may recover free assets and use remaining external authority, subject to reserved payment credits. |
| Listing owner | Controls a separate ordinary sale order. Closing it returns its escrowed right token; it never changes the right account. |

`Market` creates an isolated clone account with immutable issuer, handler, handler code hash, config hash, deadline and residual beneficiary. `Rights` is a canonical ERC721 deployed with Market. The token ID identifies one Market-created backing account. Only that account may mint on validated activation and burn on termination. Token transfer checks the account's active state, execution lock and deadline, and refuses transfer to its own account. No issuer or holder gets unrestricted account calls while active or during pending setup.

| State | Entry | Permitted transition | Account authority |
| --- | --- | --- | --- |
| Pending | Creation | Validate backing and activate before deadline; issuer cancels setup; anyone finalizes at deadline | No generic execution |
| Active | Activation mints token to issuer | Holder exercise or surrender; anyone finalizes at deadline | Bound handler only, during the local execution lock |
| Exercised | Successful exercise burns token | None | Residual recovery of unencumbered balance and stray assets |
| Expired | Anyone finalizes pending or active setup at or after deadline, burning a token only if one was minted | None | Same terminal recovery |
| Surrendered | Holder burns token | None | Same terminal recovery |
| Canceled | Issuer cancels pending setup | None | Same terminal recovery |

The deadline boundary is exclusive: at `block.timestamp >= deadline`, exercise, transfer and supported trading quotes fail; anyone can finalize. Deadline zero explicitly means perpetual commitment, with no issuer escape. The account lock covers exercise, token movement, surrender, expiry finalization and recovery for that account. Other accounts remain composable.

Activation calls the pinned handler's read-only validation and stores its returned terms on the account before minting. Supported NFT purchase validation checks custody, fixed price and the royalty recipient and amount; those royalty terms cannot later be recomputed. Artwork validation checks a target-enforced reservation that survives artwork transfer. A generic permissionless handler remains a trust choice, and a revocable external grant is never certified as durable.

The account tracks ETH payment credits by beneficiary and reserves their total before any further outbound ETH call, including terminal recovery. A beneficiary may withdraw its credit to a chosen recipient, so a beneficiary contract that rejects ETH at its own address can still collect through an accepting destination. Exercise requires exact payment in the supported NFT purchase handler. NFT delivery is checked by `ownerOf` after the transfer. Failed exercise reverts the entire transaction, including credits and burn. Residual recovery is handler independent and cannot spend outstanding credits. External permissions are not automatically revoked by termination; supported target logic consumes or disables them. Counterparties must not approve an account that a residual beneficiary could later control.

Roles may overlap. If the holder is also the residual beneficiary, it can surrender and then recover backing without exercising or paying; this follows the issuer's committed residual allocation, not token ownership alone. A royalty recipient contract with no callable withdrawal path leaves its credit solvent but uncollected. A perpetual pending setup has no deadline-based cleanup if its issuer disappears; it never mints a transferable token.

The existing NFT trading fee and ERC2981 sale royalty apply to right-token premiums through ordinary `NFTSale` or a specific-token `NFTBid`. The rights collection itself advertises no ERC2981 royalty, so resale premiums carry no underlying-NFT royalty. Exercise has no trading fee. The covered NFT's one exercise royalty is fixed at activation and credited on exercise. Collection-wide bids for canonical rights are refused. Escrowing a token in a sale makes that sale order its actual holder; the former holder cannot exercise it until the token is returned or sold. Trading deadlines should leave a deliberate exercise window, but a generic buyer must inspect the right's deadline and terms.
