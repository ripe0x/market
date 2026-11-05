# Security model

**Not audited.** The tests and the AI review below are evidence about specific behaviour. They do not establish that the contracts are safe, and nothing here should be read as a release-readiness claim. An independent human audit is needed before anything holding real value depends on this code.

## Trust boundaries

| Component | Trusted by | For |
| --- | --- | --- |
| `Market`, the `Order` implementation | Everyone | The authority rules in [SPEC.md](SPEC.md). Immutable, no owner. Every order runs the one implementation, so a bug in it affects all orders at once. |
| Policy | The order's creator | Everything the order does during fills. Fillers trust it only as far as they have read it or verify their own receipt. |
| Strategy, capital source, artwork, NFT collection, token | Whoever configured or chose them | Their own behaviour. Market cannot check any of it. |
| `FillVerifier` (optional) | Fillers who choose to call it | Comparing the numbers and bytes they ask it to compare. It holds and moves nothing. |
| Filler's input | Nobody | Policies must validate it. |
| Indexers, frontends | Nobody | Optional. Everything needed to fill is in `Market.Created` and calldata. |

## Permissions

| Actor | Can | Cannot | Tests |
| --- | --- | --- | --- |
| Order owner | `execute` anything as the order outside fills; `close` | Act during a fill; change policy or config; act as any other order | `testFuzz_onlyOwnerExecutesOutsideFill`, `test_ownerCannotExecuteDuringFill`, `test_closeStopsFillsButKeepsRecovery`, `test_sameTermsDifferentOwnersAreSeparateAccounts` |
| Policy | `execute` as an order only while that order is filling | Act outside a fill; act as an order that is not filling, even one bound to the same policy; keep authority after the fill | `test_policyCannotExecuteOutsideFill`, `test_policyCannotKeepAuthority`, `test_hostilePolicyIsContainedToItsOwnOrders`, `test_sharedPolicyCannotCrossOrders` |
| Filler (anyone) | `fill` on the policy's terms | Change the config; spend another account's approval; reenter the same order | `testFuzz_fillRejectsAnyOtherConfig`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_fillCannotReenter` |
| Order itself | `close` itself | `execute` itself during a fill | `test_filledOrderCanCallOnlyItselfToClose`, `test_selfCallCannotEscalate` |
| Market | Deploy orders | Anything else; change the implementation | `test_marketHoldsNoAuthority`, `test_implementationCannotBeReplaced` |
| The implementation | Nothing | Be filled, executed, closed or initialized; receive ETH or safe token transfers | `test_implementationIsNotAnOrder` |
| `FillVerifier` | Read state with `staticcall` | Change state anywhere, hold assets, use approvals | `test_queriesCannotChangeState` |
| `CapitalPool` owner (example) | Grant, revoke, withdraw | Draw for an order | `test_poolGrantAccruesToCap`, `test_revokedGrantStopsDraws` |

## Properties

| Property | Mechanism | Tests |
| --- | --- | --- |
| One party at a time can make an order act | `execute` checks `filling ? policy : owner` | Core suite; `invariant_attackerGainsNothing` (about 1,000 attack attempts per campaign, none succeed) |
| Authority granted to one order is unusable by any other | Separate account (address, balance, storage, transient flag) per clone; policies act through `msg.sender` | `test_hostilePolicyIsContainedToItsOwnOrders`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_offersForDifferentTokensAreIsolated`, `test_storageAndBalancesAreIsolated`, `test_sharedPolicyCannotCrossOrders`, `test_approvalToSiblingIsUnusable` |
| Terms cannot change, and exist from deployment | Owner, policy, policy code hash and config hash are part of the clone's code and its CREATE2 address; there is no initializer | `test_cloneCodeIsProxyPlusTerms`, `testFuzz_addressIsDeterministic`, `test_addressCommitsToEveryField`, `test_buyerCannotRewriteTerms`, `test_sameCommitmentCannotBeCreatedTwice` |
| The code every order runs cannot change | Market's implementation pointer is immutable; the implementation has no `DELEGATECALL` or `SELFDESTRUCT` | `test_implementationCannotBeReplaced` |
| The implementation is never an order | Every entry point reverts when `address(this)` is the implementation | `test_implementationIsNotAnOrder` |
| The policy code that runs is the code committed to | Fills check the policy's code hash; delegated EOAs are refused as policies | `test_fillRefusesReplacedPolicyCode`, `test_createRejectsDelegatedAccount`, `test_delegatedAccountCannotBePolicy` |
| Atomic settlement | A fill is one call; any revert undoes it | `test_policyRevertUndoesFill`, `test_insufficientInventoryRollsBackPayment`, `test_falseReturningTokenRejected`, `test_fundingWithdrawnBeforeFillReverts`, `test_matchCrossingSaleAndBid` |
| No reentrant fill of the same order | Transient `filling` flag | `test_fillCannotReenter`, `test_payeeCannotReenter`, `test_sellerCannotReenter` |
| Recovery never depends on the policy | `close` and owner `execute` never call it | `test_ownerRecoversFromBrokenPolicy`, `test_cancelAndRecover` |
| Single use authority is consumed | Example 3 resigns its role and closes | `test_authorityIsConsumed`, `test_transferMakesOfferStale` |
| Persistent state evolves only through fills of that order | Policy state keyed by `msg.sender` | `test_sellIntoBidRecordsClearingPriceAndResets`, `invariant_bidAccounting` |
| External capital is spendable only through the policy, within limits | Pool checks `Order.filling()` and an accruing allowance | `test_poolPaysOnlyThroughAFill`, `testFuzz_payoutNeverExceedsBid` |
| Receipt is checked by state, not claims | Balance deltas, `ownerOf` before and after | `test_feeOnTransferPaymentRejected`, `test_selfPaymentRejected`, `test_selfDeliveryRejected`, `test_counterfeitSaleCannotFoolTheBid` |
| A filler can make its own fill conditional on its receipt | The filler's own batch or contract, optionally with `FillVerifier` | `test_dishonestPolicyFailsTheWalletsCheck`, `test_sellerChecksEthReceived`, `test_snapshotsAreKeyedByCaller`, `test_requireIncreaseNeedsOwnSnapshot`, `test_snapshotIsUsedUp` |
| Example 4 records only paid acquisitions | `AcquisitionBid` rejects price 0 | `test_zeroPriceSaleRejected`, `testFuzz_payoutNeverExceedsBid` |
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
| CREATE2 collision, squatting or front-running `create` | The address commits to the implementation and the full terms, including the owner, and Market always uses `msg.sender` as owner, so only the owner can deploy at an order's address, and only that exact commitment. There is no initializer to front-run. |
| Calling the implementation directly, or sending it assets | Reverts `NotAnOrder` on every entry point, including `receive` and the token hooks. |
| A clone of the implementation deployed outside Market | Works as an order with whatever terms its deployer appended, including any "owner" address; that owner really controls it. Same as anyone deploying a look-alike contract: trust only orders from `Market.Created` or `orderAddress`. |
| An EIP-7702 account delegated to the implementation | Its code is only the 23-byte designator, so its terms read as zero: `fill` reverts `WrongConfig`, `execute` reverts `Unauthorized`. Inert, apart from the account's own key. |
| Policy code replaced after creation (destroyed in its creation transaction, redeployed) | Fills revert `PolicyCodeChanged`; the owner recovers. |
| EIP-7702 account as policy | `create` reverts `DelegatedPolicy`. |
| Closing an order, expecting its outside permissions to end | They do not (D003). The owner must revoke them with `execute`; a single use policy must consume them itself, as `PaintAction` does. Market does not stop an external contract's other permission holders, such as an artist, from acting. |
| Front-running a `FillVerifier` snapshot | Snapshots are keyed by the caller and live for one transaction, so nobody else can set or overwrite yours. |
| Reusing one `FillVerifier` snapshot for two fills | Refused: `requireIncrease` uses its snapshot up, so a second check without a fresh snapshot reverts `NoSnapshot` (G1). |
| Owner fills its own order through `execute(order, fill(...))` | Allowed: the policy runs with the order as `caller`, under the policy's own rules. In Example 4 this lets an operator sell an NFT it put in the bid order into that bid, at a price the strategy allows, which is no different from selling it from another address. External grants restrict spending to the policy's rules, not to third-party initiators. |

## Residual risks

1. **Policies are trusted code.** A buggy or hostile policy can spend everything its orders hold during any fill, and anyone can start a fill. Market contains the damage to orders that chose that policy and nothing more.
2. **Mutable policies.** The code-hash pin fixes a policy's bytecode, not its behaviour. Proxies, `delegatecall` to other code, owner switches and reads of mutable contracts hand their controller every bound order's authority during fills. Market cannot detect them (D006); a reader of the policy's code can.
3. **Filler protection is the filler's job** (D009). A plain EOA filling an unknown policy can lose what it sends. Fill from a contract or batching wallet that checks the outcome, for example with `FillVerifier` (`test/Eip7702Filler.t.sol`), or fill only policies you have read. `FillVerifier` compares what you ask it to compare: `balanceOf` on an NFT collection is satisfied by any token, so check `ownerOf` for a specific one, and query the asset's contract, not the order or its policy. A delta also counts unrelated inflows during the batch.
4. **Approvals given to an order** are usable by its policy during any fill and by its owner at any time. `setApprovalForAll` to an order exposes the whole collection to that policy.
5. **Third-party contracts are trusted for their own behaviour.** A hostile NFT collection can lie in `ownerOf`; a hostile token can lie in `balanceOf`. Configs bind specific contracts; choosing them is the creator's responsibility.
6. **Blocking payees.** A configured payee that reverts on ETH blocks the example policies' fills.
7. **External capital is conditional** and can disappear between a quote and a fill.
8. **Stray assets** sent to an order belong to its owner (recoverable) or, during a fill, are reachable by its policy. Assets sent to a policy contract are stuck or stealable, since policies hold nothing by design.
9. **Return data size.** `execute` copies the callee's full return data; a hostile callee chosen by the creator or filler can make a fill expensive. It can only grief a transaction its own participant chose.
10. **CREATE2 collision gas.** Creating the same commitment twice reverts after consuming the gas given to the deployment.
11. **Toolchain.** via-IR compilation and transient storage are relatively new. The full suite runs on Solidity 0.8.30 for Prague; the core, clone and composition suites also pass on 0.8.28 for Cancun.
12. **No fork tests.** The examples use local mock tokens and NFTs. No real mainnet assets or contracts were exercised. The deploy script has been simulated against mainnet RPC only.
13. **Collection-wide bids pay for any token.** `AcquisitionBid` accepts every token of its collection at up to the current maximum, so sellers will offer the least valuable ones. A creator who cares needs a policy that narrows eligibility, for example to a token id range or an allowlist; a strategy cannot, since it never sees the token id.
14. **One implementation for every order.** A bug in `Order` is a bug in every order, with no way to patch deployed orders. This was already true of identical full contracts; clones add one shared address that cannot be destroyed or replaced.
15. **Counterfactual addresses depend on the policy's code.** `orderAddress` uses the policy's current code hash. Predicting an order for a policy that is not yet deployed gives a different address from the one `create` will use; deploy the policy first.
16. **Explorer and tooling support.** Orders appear as minimal proxies. Their terms are read through the getters or decoded from the last 104 bytes of their code, not from storage.
17. **Closing does not revoke.** A closed order still holds whatever approvals, roles and grants it was given until its owner revokes them (D003).

## Review findings

### First review

Independent AI review (a separate agent given the code and the owner's requirements, not the author's conclusions) of `src/` and `examples/` at commit `a50ff04`. Not a human audit. Proof-of-concept tests: `test/review/ReviewPoC.t.sol`, 5 tests. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| F1 | Low (design) | The commitment binds the policy's address, not its behaviour; a mutable policy can change terms after a counterparty inspects the order (`test_mutablePolicyChangesTermsAfterCommit`) | Accepted and documented: D006, residual risk 2. The code-hash pin added on 2026-11-05 does not change this: the PoC's storage switch, like a proxy upgrade, leaves the code hash unchanged. |
| F2 | Low | `TokenExchange` measured the payment leg by balance change but the delivery leg only by return value, so a fee-on-transfer `give` token delivered less than the filler paid for | Fixed: delivery is measured on the recipient and reverts `ShortDelivery` (`test_feeOnTransferDeliveryRejected`). |
| F3 | Low (docs) | `CapitalPool`'s `cap` could be read as a lifetime budget; it limits only the amount claimable at one moment | Fixed: NatSpec now says lifetime draws are limited by `rate`, time and the pool's balance. |
| F4 | Info | A collection-wide bid pays up to its current maximum for any token, including cheap ones; and a sale at price 0 reset `RisingStrategy`'s base to 0, suppressing the curve (`test_zeroPriceFillResetsStrategyBase`) | Fixed the reset: the base never restarts below `startPrice`. On 2026-11-05 price 0 fills were rejected outright (D110, `test_zeroPriceSaleRejected`); a 1 wei sale still restarts the curve at `startPrice` (`test_cheapSaleRestartsAtStartPrice`). Overpaying for cheap tokens is inherent to a collection-wide bid and is listed below as residual risk 13. |

The reviewer also confirmed, with executed tests, cross-policy isolation, reentrancy safety of `CapitalPool.draw`, and that donating ETH to a bid order cannot extract more than the pool's grant.

### Second review

Independent AI review of the clone change (commit `03c263f` against `4f2d19c`), given the owner's requirements for clones, policy immutability, filler verification and the zero-price fix, not the author's conclusions. Not a human audit. Proof-of-concept tests: `test/review/CloneReviewPoC.t.sol`, 6 tests. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| G1 | Low | `FillVerifier.requireIncrease` did not use up its snapshot, so a batch that took one snapshot and checked after each of two fills judged the second fill against the first fill's baseline and passed although nothing new arrived (`test_fillVerifierStaleSnapshotGivesFalseAssurance`) | Fixed: `requireIncrease` clears the snapshot it used, so the reuse reverts `NoSnapshot` (`test_snapshotIsUsedUp`). |
| G2 | Info | An EIP-7702 EOA delegated to the `Order` implementation is not caught by the implementation guard, since `address(this)` is the EOA | No change: its terms read as zero, so `fill` reverts `WrongConfig` and `execute` reverts `Unauthorized` (`test_eoaDelegatedToImplementationIsBrickedNotDrainable`). Listed under threats. |
| G3 | Info | ETH forced into the implementation (by `SELFDESTRUCT` elsewhere or as a block reward) is stuck | No change: unavoidable for any contract; nobody's expected funds are affected (`test_implementationCannotMoveForcedEth`). |
| G4 | Info | The code-hash pin proves only that the policy's bytecode is unchanged | Already documented (D006, residual risk 2); `MutablePolicy` in `test/review/ReviewPoC.t.sol` shows it. |
| G5 | Info | `requireIncrease` passes if the value rose for any reason (an unrelated transfer in, a rebasing token); `requireEqual` copies unbounded return data | Inherent to delta checks; documented in residual risk 3 and the README. |

The reviewer also confirmed with executed tests that a front-runner cannot occupy a predicted order address, that a policy shared by two clones cannot act on the sibling, and that a genuine 23-byte contract not starting with `0xef` is accepted as a policy.
