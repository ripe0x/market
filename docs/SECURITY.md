# Security model

**Not audited.** The tests and the AI review below are evidence about specific behaviour. They do not establish that the contracts are safe, and nothing here should be read as a release-readiness claim. An independent human audit is needed before anything holding real value depends on this code.

## Trust boundaries

| Component | Trusted by | For |
| --- | --- | --- |
| `Market`, `Order` | Everyone | The authority rules in [SPEC.md](SPEC.md). Immutable, no owner. |
| Policy | The order's creator | Everything the order does during fills. Fillers trust it only as far as they have read it or verify their own receipt. |
| Strategy, capital source, artwork, NFT collection, token | Whoever configured or chose them | Their own behaviour. Market cannot check any of it. |
| Filler's input | Nobody | Policies must validate it. |
| Indexers, frontends | Nobody | Optional. Everything needed to fill is in `Market.Created` and calldata. |

## Permissions

| Actor | Can | Cannot | Tests |
| --- | --- | --- | --- |
| Order owner | `execute` anything as the order outside fills; `close` | Act during a fill; change policy or config | `testFuzz_onlyOwnerExecutesOutsideFill`, `test_ownerCannotExecuteDuringFill`, `test_closeStopsFillsButKeepsRecovery` |
| Policy | `execute` as an order only while that order is filling | Act outside a fill; act as an order that is not bound to it; keep authority after the fill | `test_policyCannotExecuteOutsideFill`, `test_policyCannotKeepAuthority`, `test_hostilePolicyIsContainedToItsOwnOrders` |
| Filler (anyone) | `fill` on the policy's terms | Change the config; spend another account's approval; reenter the same order | `testFuzz_fillRejectsAnyOtherConfig`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_fillCannotReenter` |
| Order itself | `close` itself | `execute` itself during a fill | `test_filledOrderCanCallOnlyItselfToClose`, `test_selfCallCannotEscalate` |
| Market | Deploy orders | Anything else | `test_marketHoldsNoAuthority` |
| `CapitalPool` owner (example) | Grant, revoke, withdraw | Draw for an order | `test_poolGrantAccruesToCap`, `test_revokedGrantStopsDraws` |

## Properties

| Property | Mechanism | Tests |
| --- | --- | --- |
| One party at a time can make an order act | `execute` checks `filling ? policy : owner` | Core suite; `invariant_attackerGainsNothing` (1,000+ attack attempts per run, none succeed) |
| Authority granted to one order is unusable by any other | Separate account per order; policies act through `msg.sender` | `test_hostilePolicyIsContainedToItsOwnOrders`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_offersForDifferentTokensAreIsolated` |
| Terms cannot change | Policy and config hash immutable and part of the CREATE2 address | `test_addressCommitsToEveryField`, `test_buyerCannotRewriteTerms`, `test_sameCommitmentCannotBeCreatedTwice` |
| Atomic settlement | A fill is one call; any revert undoes it | `test_policyRevertUndoesFill`, `test_insufficientInventoryRollsBackPayment`, `test_falseReturningTokenRejected`, `test_fundingWithdrawnBeforeFillReverts`, `test_matchCrossingSaleAndBid` |
| No reentrant fill of the same order | Transient `filling` flag | `test_fillCannotReenter`, `test_payeeCannotReenter`, `test_sellerCannotReenter` |
| Recovery never depends on the policy | `close` and owner `execute` never call it | `test_ownerRecoversFromBrokenPolicy`, `test_cancelAndRecover` |
| Single use authority is consumed | Example 3 resigns its role and closes | `test_authorityIsConsumed`, `test_transferMakesOfferStale` |
| Persistent state evolves only through fills of that order | Policy state keyed by `msg.sender` | `test_sellIntoBidRecordsClearingPriceAndResets`, `invariant_bidAccounting` |
| External capital is spendable only through the policy, within limits | Pool checks `Order.filling()` and an accruing allowance | `test_poolPaysOnlyThroughAFill`, `testFuzz_payoutNeverExceedsBid` |
| Receipt is checked by state, not claims | Balance deltas, `ownerOf` before and after | `test_feeOnTransferPaymentRejected`, `test_selfPaymentRejected`, `test_selfDeliveryRejected`, `test_counterfeitSaleCannotFoolTheBid` |
| Orders cannot sign | No EIP-1271, no fallback | `test_ordersDoNotValidateSignatures` |

## Threats considered

| Threat | Outcome |
| --- | --- |
| Third party calls `execute` or `close` | Reverts `Unauthorized`. |
| Owner reaches into a fill through a callback | Reverts: only the policy may execute while filling. |
| Policy stores the order and acts later | Reverts: not filling. |
| Policy acts on a different order | Reverts: that order is not filling, or its policy is a different contract. Two orders sharing a policy: a benign policy acts only on `msg.sender`; a hostile one already controls both orders by their creators' choice. |
| Filler supplies a different config | Reverts `WrongConfig`. |
| Payee, seller or recipient reenters the order | Reverts `Reentrant`; the reentrancy attempt fails without breaking the outer fill unless the attacker chooses to revert it. |
| Nested fills of different orders | Allowed and independent; this is how composition works. |
| Self-call escalation through `execute(order, ...)` | `execute` from the order itself is rejected; `fill` from itself hits the lock; only `close` is allowed. |
| Attacker calls a policy directly, posing as an order | The policy acts on the attacker's own contract; state is keyed to the attacker's address. |
| Counterfeit order claims delivery | The counterparty's own check fails; nothing settles. |
| Counterfeit collection or token | Configs fix the contract address; a different contract is not what the policy calls. |
| Fee-on-transfer, no-return and false-returning tokens | Payment measured by balance delta; return data checked; no-return tokens accepted. |
| Order owner drains an external grant | `CapitalPool` pays only filling orders. |
| Grant revoked or pool emptied after a quote | Fill reverts; the seller keeps the NFT. |
| Signature replay through the order | Orders validate no signatures. |
| Approval to the factory | Inert; the factory has no call path. |
| CREATE2 collision or squatting | The address commits to owner, policy, config hash and salt, and Market always uses `msg.sender` as owner, so only the owner can deploy at an order's address, and only that exact commitment. |
| Owner fills its own order through `execute(order, fill(...))` | Allowed: the policy runs with the order as `caller`, under the policy's own rules. In Example 4 this lets an operator sell an NFT it put in the bid order into that bid, at a price the strategy allows, which is no different from selling it from another address. External grants restrict spending to the policy's rules, not to third-party initiators. |

## Residual risks

1. **Policies are trusted code.** A buggy or hostile policy can spend everything its orders hold during any fill, and anyone can start a fill. Market contains the damage to orders that chose that policy and nothing more.
2. **Mutable policies** (proxies, owner switches, reading mutable state) hand their controller every bound order's authority during fills. Not detectable onchain (D006).
3. **Filler protection is the filler's job** (D009). A plain EOA filling an unknown policy can lose what it sends. Fill from a contract or EIP-7702 account that checks the outcome (`test/Eip7702Filler.t.sol`), or fill only policies you have read.
4. **Approvals given to an order** are usable by its policy during any fill and by its owner at any time. `setApprovalForAll` to an order exposes the whole collection to that policy.
5. **Third-party contracts are trusted for their own behaviour.** A hostile NFT collection can lie in `ownerOf`; a hostile token can lie in `balanceOf`. Configs bind specific contracts; choosing them is the creator's responsibility.
6. **Blocking payees.** A configured payee that reverts on ETH blocks the example policies' fills.
7. **External capital is conditional** and can disappear between a quote and a fill.
8. **Stray assets** sent to an order belong to its owner (recoverable) or, during a fill, are reachable by its policy. Assets sent to a policy contract are stuck or stealable, since policies hold nothing by design.
9. **Return data size.** `execute` copies the callee's full return data; a hostile callee chosen by the creator or filler can make a fill expensive. It can only grief a transaction its own participant chose.
10. **CREATE2 collision gas.** Creating the same commitment twice reverts after consuming the gas given to the deployment.
11. **Toolchain.** via-IR compilation and transient storage are relatively new; the code has been compiled with one compiler version only (0.8.30).
12. **No fork tests.** The examples use local mock tokens and NFTs. No real mainnet assets or contracts were exercised. The deploy script has been simulated against mainnet RPC only.
13. **Collection-wide bids pay for any token.** `AcquisitionBid` accepts every token of its collection at up to the current maximum, so sellers will offer the least valuable ones. A creator who cares needs a policy that narrows eligibility, for example to a token id range or an allowlist; a strategy cannot, since it never sees the token id.

## Review findings

Independent AI review (a separate agent given the code and the owner's requirements, not the author's conclusions) of `src/` and `examples/` at commit `a50ff04`. Not a human audit. Proof-of-concept tests: `test/review/ReviewPoC.t.sol`, 5 tests. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| F1 | Low (design) | The commitment binds the policy's address, not its behaviour; a mutable policy can change terms after a counterparty inspects the order (`test_mutablePolicyChangesTermsAfterCommit`) | Accepted and documented: D006, residual risk 2. Code-hash pinning would not help, since a proxy's code hash does not change on upgrade. |
| F2 | Low | `TokenExchange` measured the payment leg by balance change but the delivery leg only by return value, so a fee-on-transfer `give` token delivered less than the filler paid for | Fixed: delivery is measured on the recipient and reverts `ShortDelivery` (`test_feeOnTransferDeliveryRejected`). |
| F3 | Low (docs) | `CapitalPool`'s `cap` could be read as a lifetime budget; it limits only the amount claimable at one moment | Fixed: NatSpec now says lifetime draws are limited by `rate`, time and the pool's balance. |
| F4 | Info | A collection-wide bid pays up to its current maximum for any token, including cheap ones; and a sale at price 0 reset `RisingStrategy`'s base to 0, suppressing the curve (`test_zeroPriceFillResetsStrategyBase`) | Fixed the reset: the base never restarts below `startPrice` (`test_zeroPriceSaleCannotSuppressBid`). Overpaying for cheap tokens is inherent to a collection-wide bid and is listed below as residual risk 13. |

The reviewer also confirmed, with executed tests, cross-policy isolation, reentrancy safety of `CapitalPool.draw`, and that donating ETH to a bid order cannot extract more than the pool's grant.
