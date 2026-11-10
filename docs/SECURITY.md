# Security model

**Not audited.** The tests and the AI review below are evidence about specific behaviour. They do not establish that the contracts are safe, and nothing here should be read as a release-readiness claim. An independent human audit is needed before anything holding real value depends on this code.

## Trust boundaries

| Component | Trusted by | For |
| --- | --- | --- |
| `Market`, the `Order` implementation | Everyone | The authority rules in [SPEC.md](SPEC.md). Immutable, no owner. Every order runs the one implementation, so a bug in it affects all orders at once. |
| Handler | The order's creator | Everything the order does during fills. One handler may serve many orders, so a bug in it affects all of them. Fillers trust it only as far as they have read it or verify their own receipt. |
| `NFTBid` | Every holder who approves it | Moving an approved token only in a genuine fill the holder makes. One deployment holds every holder's approval, so it is shared authority, not per-order authority. |
| NFT collection, royalty receiver, artwork | Whoever configured or chose them | Their own behaviour. Market cannot check any of it. |
| `FillVerifier` (optional) | Fillers who choose to call it | Comparing the numbers and bytes they ask it to compare. It holds and moves nothing. |
| Filler's input | Nobody | Handlers must validate it. |
| Indexers, frontends | Nobody | Optional. Everything needed to fill is in `Market.Created` and calldata. |

## Permissions

| Actor | Can | Cannot | Tests |
| --- | --- | --- | --- |
| Order owner, active order | `close`, outside a fill | `execute` at any time; close during a fill; fill through the order; change handler or config; act as any other order | `testFuzz_nobodyExecutesActiveOrderOutsideFill`, `test_ownerExecutesOnlyAfterClosing`, `test_ownerCannotExecuteDuringFill`, `test_ownerCannotCloseDuringFill`, `test_ownerCannotFillThroughTheOrder`, `test_sameTermsDifferentOwnersAreSeparateAccounts`, `invariant_activeOrdersStayCommitted` |
| Order owner, closed order | `execute` anything as the order, outside fills, including spending any approval or permission others granted the order (A1) | Reopen it; fill it; draw an external grant that requires `filling`; make a handler that checks for a genuine fill act | `test_closeStopsFillsButKeepsRecovery`, `testFuzz_onlyOwnerExecutesClosedOrder`, `test_closedOrderCannotDrawFillingGatedGrant`, `test_approvalToAnOrderBelongsToItsOwner`, `test_closedOrderCannotAnnounceASale` |
| Handler | `execute` as an order only while that order is filling, including after closing it in that fill; close it through `execute` | Act outside a fill; act on a closed order after the closing fill; act as an order that is not filling, even one bound to the same handler; keep authority after the fill; call `close` directly | `test_handlerCannotExecuteOutsideFill`, `test_handlerCannotKeepAuthority`, `test_hostileHandlerIsContainedToItsOwnOrders`, `test_sharedHandlerCannotCrossOrders`, `test_hostileHandlerCannotReachUnrelatedOrders`, `test_handlerClosesOnlyThroughTheOrder`, `test_closingInsideFillHandsOverWhenFillEnds` |
| Filler (anyone) | `fill` on the handler's terms | Change the config; spend another account's approval; reenter the same order | `testFuzz_fillRejectsAnyOtherConfig`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_fillCannotReenter` |
| Order itself | `close` itself during a fill | `execute` itself | `test_filledOrderCanCallOnlyItselfToClose`, `test_selfCallCannotEscalate` |
| Market | Deploy orders | Anything else; change the implementation | `test_marketHoldsNoAuthority`, `test_implementationCannotBeReplaced` |
| The implementation | Nothing | Be filled, executed, closed or initialized; receive ETH or safe token transfers | `test_implementationIsNotAnOrder` |
| `FillVerifier` | Read state with `staticcall` | Change state anywhere, hold assets, use approvals | `test_queriesCannotChangeState` |
| `NFTBid` handler | Move a token approved to it, from the account that called `fill` on a genuine `Order` clone bound to it, during that fill, to that order's `recipient` | Move a token for a direct caller, a fake order, an order bound to another handler, or a closed order's owner; move from anyone but the filler | `test_bidderCannotStealApprovedTokens`, `test_otherOrdersCannotUseTheHandlersApproval`, `test_phishingRouterCannotSweepApprovedTokens`, `invariant_noTheft` |
| `NFTSale`, `NFTBid` events | `Sold` and `Bought` are emitted only in a genuine fill that settled | Be made to emit by a direct caller, a counterfeit order or a closed order's owner (S1) | `test_counterfeitOrderCannotAnnounceASale`, `test_closedOrderCannotAnnounceASale`, `test_directHandlerCallMovesNothing` |

## Properties

| Property | Mechanism | Tests |
| --- | --- | --- |
| At most one party at a time can make an order act: the handler during a fill, the owner of a closed order, nobody otherwise | `execute` checks `filling ? handler : closed && owner` | Core suite; `invariant_noTheft` |
| What an active order holds leaves only through fills | The owner has no `execute` until it closes the order | `test_ownerExecutesOnlyAfterClosing`, `invariant_activeOrdersStayCommitted` |
| Only the handler ends an order mid-fill, and the owner gains authority only after the fill | `close` during a fill accepts only the order itself; `execute` checks `filling` before `closed` | `test_ownerCannotCloseDuringFill`, `test_handlerClosesOnlyThroughTheOrder`, `test_closingInsideFillHandsOverWhenFillEnds` |
| Orders sharing a handler stay independent | Each is its own account; the handler is accepted only by orders that are filling; handlers key state by `msg.sender` | `test_ordersSharingAHandlerAreIndependent`, `test_nestedFillsOnOneHandler`, `test_sharedHandlerStateStaysPerOrder`, `test_hostileHandlerCannotReachUnrelatedOrders` |
| Maintenance of an active order is possible only through its handler | A handler may offer it in a fill; the core offers no bypass | `test_handlerCanAllowOwnerMaintenance` |
| Authority granted to one order is unusable by any other | Separate account (address, balance, storage, transient flag) per clone; handlers act through `msg.sender` | `test_hostileHandlerIsContainedToItsOwnOrders`, `test_approvalToOneOrderIsUnusableElsewhere`, `test_offersForDifferentTokensAreIsolated`, `test_storageAndBalancesAreIsolated`, `test_sharedHandlerCannotCrossOrders`, `test_approvalToSiblingIsUnusable` |
| Terms cannot change, and exist from deployment | Owner, handler, handler code hash and config hash are part of the clone's code and its CREATE2 address; there is no initializer | `test_cloneCodeIsProxyPlusTerms`, `testFuzz_addressIsDeterministic`, `test_addressCommitsToEveryField`, `testFuzz_fillRejectsAnyOtherConfig`, `test_sameCommitmentCannotBeCreatedTwice` |
| The code every order runs cannot change | Market's implementation pointer is immutable; the implementation has no `DELEGATECALL` or `SELFDESTRUCT` | `test_implementationCannotBeReplaced` |
| The implementation is never an order | Every entry point reverts when `address(this)` is the implementation | `test_implementationIsNotAnOrder` |
| The handler code that runs is the code committed to | Fills check the handler's code hash; delegated EOAs are refused as handlers | `test_fillRefusesReplacedHandlerCode`, `test_createRejectsDelegatedAccount`, `test_delegatedAccountCannotBeHandler` |
| Atomic settlement | A fill is one call; any revert undoes it | `test_handlerRevertUndoesFill`, `test_matchCrossingSaleAndBid`, `test_eachLimitRevertsTheWholeMatch`, `test_underfundedBidRevertsTheWholeMatch` |
| No reentrant fill of the same order | Transient `filling` flag | `test_fillCannotReenter`, `test_buyerCannotReenterOnRefund`, `test_royaltyReceiverCannotReenter`, `test_deliveryReentrancyCannotOverfillSameBid` |
| Recovery never depends on the handler | `close` and owner `execute` never call it | `test_ownerRecoversFromBrokenHandler`, `test_fillRefusesReplacedHandlerCode`, `test_cancelAndRecover`, `test_closingKeepsTheRoleUntilRevoked` |
| Single use authority is consumed | `PaintAction` resigns its role and closes | `test_authorityIsConsumed`, `test_transferMakesOfferStale` |
| Persistent state evolves only through fills of that order | Handler state keyed by `msg.sender` | `test_sharedHandlerStateStaysPerOrder`, `invariant_bidLimits` |
| A permission granted to an order can be made usable only through its handler | The granting contract checks `Order.filling()` | `test_closedOrderCannotDrawFillingGatedGrant` |
| Receipt is checked by state, not claims | `ownerOf` before and after delivery | `test_lyingCollectionCannotFakeDelivery`, `test_recipientAlreadyOwningIsRejected`, `test_counterfeitSaleCannotFoolTheBid` |
| Buyer, seller and bidder limits hold | `maxPrice`, `maxRoyaltyBps`, `minProceeds`, the schedule and the bid's balance | `test_revertWhenAboveBuyerMax`, `test_royaltyAboveSellerLimitReverts`, `test_risingBidAndSellerMinimum`, `testFuzz_settlementConserves`, `testFuzz_bidSettlementConserves`, `invariant_everyPaymentAccounted`, `invariant_bidLimits` |
| A filler can make its own fill conditional on its receipt | The filler's own batch or contract, optionally with `FillVerifier` | `test_dishonestHandlerFailsTheWalletsCheck`, `test_sellerChecksEthReceived`, `test_snapshotsAreKeyedByCaller`, `test_requireIncreaseNeedsOwnSnapshot`, `test_snapshotIsUsedUp` |
| Orders cannot sign | No EIP-1271, no fallback | `test_ordersDoNotValidateSignatures` |

## Threats considered

| Threat | Outcome |
| --- | --- |
| Third party calls `execute` or `close` | Reverts `Unauthorized`. |
| Owner reaches into a fill through a callback | Reverts: only the handler may execute while filling, and only the order itself may close. |
| Owner withdraws what an active order holds and leaves it listed | Reverts `Unauthorized`: the owner must close first, which ends the order visibly. |
| Owner keeps an order active but changes what backs it elsewhere | Not prevented: approvals from the owner's wallet, roles and grants are revocable by their grantors under their own contracts. The commitment covers only authority the order holds. |
| Handler stores the order and acts later | Reverts: not filling. |
| Handler acts on a different order | Reverts: that order is not filling, or its handler is a different contract. Two orders sharing a handler: a benign handler acts only on `msg.sender`; a hostile one already controls both orders by their creators' choice. |
| Filler supplies a different config | Reverts `WrongConfig`. |
| Payee, seller or recipient reenters the order | Reverts `Reentrant`; the reentrancy attempt fails without breaking the outer fill unless the attacker chooses to revert it. |
| Nested fills of different orders | Allowed and independent; this is how composition works. |
| Nested fills of two orders sharing a handler | Both accept the handler until their fills return, so the core cannot tell which one the handler acts for. A handler that acts only through `msg.sender` keeps them apart (`test_sharedHandlerStateStaysPerOrder`); one that takes an order address from input can be steered from the inner fill to the outer order (`test_nestedFillsOnOneHandler`). That handler is already unsafe, since anyone can start a fill of any order bound to it. |
| Self-call escalation through `execute(order, ...)` | `execute` from the order itself is rejected; `fill` from itself hits the lock; only `close` is allowed. |
| Attacker calls a handler directly, posing as an order | `NFTSale` and `NFTBid` revert `NotAFill`. A handler without that check acts on the attacker's own contract and keys state to the attacker's address; its events then describe nothing real (S1). |
| Counterfeit order claims delivery | The counterparty's own check fails; nothing settles. |
| Counterfeit collection or token | Configs fix the contract address; a different contract is not what the handler calls. |
| Order owner spends an approval a counterparty gave the order | Possible after closing (A1). The supported handlers never ask for one: `NFTSale` escrows, `NFTBid` takes approvals itself. |
| Order owner drains an external grant | Prevented when the grant checks `Order.filling()`: the owner has no `execute` while active and is never filling after closing. |
| Bid funds shrink after a quote | They cannot while the bid is active; a fill reverts `InsufficientFunds` only if the balance never covered the price. |
| Signature replay through the order | Orders validate no signatures. |
| Approval to the factory | Inert; the factory has no call path. |
| CREATE2 collision, squatting or front-running `create` | The address commits to the implementation and the full terms, including the owner, and Market always uses `msg.sender` as owner, so only the owner can deploy at an order's address, and only that exact commitment. There is no initializer to front-run. |
| Calling the implementation directly, or sending it assets | Reverts `NotAnOrder` on every entry point, including `receive` and the token hooks. |
| A clone of the implementation deployed outside Market | Works as an order with whatever terms its deployer appended, including any "owner" address; that owner really controls it. Same as anyone deploying a look-alike contract: trust only orders from `Market.Created` or `orderAddress`. |
| An EIP-7702 account delegated to the implementation | Its code is only the 23-byte designator, so its terms read as zero: `fill` reverts `WrongConfig`, `execute` reverts `Unauthorized`. Inert, apart from the account's own key. |
| Handler code replaced after creation (destroyed in its creation transaction, redeployed) | Fills revert `HandlerCodeChanged`; the owner closes and recovers. |
| EIP-7702 account as handler | `create` reverts `DelegatedHandler`. |
| Closing an order, expecting its outside permissions to end | They do not (D003). The owner must revoke them with `execute`; a single use handler must consume them itself, as `PaintAction` does. Market does not stop an external contract's other permission holders, such as an artist, from acting. |
| Front-running a `FillVerifier` snapshot | Snapshots are keyed by the caller and live for one transaction, so nobody else can set or overwrite yours. |
| Reusing one `FillVerifier` snapshot for two fills | Refused: `requireIncrease` uses its snapshot up, so a second check without a fresh snapshot reverts `NoSnapshot` (G1). |
| Owner fills its own order through `execute(order, fill(...))` | Refused: `Unauthorized` while active, `OrderClosed` after closing (`test_ownerCannotFillThroughTheOrder`). The owner can still fill from its own address like anyone, under the handler's rules. |

## Residual risks

1. **Handlers are trusted code, often shared.** A buggy or hostile handler can spend everything its orders hold during any fill, and anyone can start a fill. A bug in a handler used by hundreds of orders is a bug in all of them. Isolation limits which accounts a handler can act through (only orders bound to it, only while they are filling); it does not make a defective or hostile handler safe. Market contains the damage to orders that chose that handler and nothing more.
2. **Mutable handlers.** The code-hash pin fixes a handler's bytecode, not its behaviour. Proxies, `delegatecall` to other code, owner switches and reads of mutable contracts hand their controller every bound order's authority during fills. Market cannot detect them (D006); a reader of the handler's code can.
3. **Filler protection is the filler's job** (D009). A plain EOA filling an unknown handler can lose what it sends. Fill from a contract or batching wallet that checks the outcome, for example with `FillVerifier` (`test/Eip7702Filler.t.sol`), or fill only handlers you have read. `FillVerifier` compares what you ask it to compare: `balanceOf` on an NFT collection is satisfied by any token, so check `ownerOf` for a specific one, and query the asset's contract, not the order or its handler. A delta also counts unrelated inflows during the batch.
4. **Approvals given to an order** are usable by its handler during any fill and by its owner once it is closed. An approval from a counterparty to an order is therefore an approval to that order's owner, who can close the order and spend it before the counterparty's fill lands (finding A1). Approve an order only for your own order, or approve and fill atomically. The same holds for any role or permission granted to an order (`PaintAction`'s painter role is granted by the token's owner to its own order).
5. **Approvals given to `NFTBid` are shared authority.** One deployment holds the approvals of every holder who uses it, across collections. It moves a token only in a genuine fill whose caller is the holder, so bidders, outsiders, routers and other handlers cannot use it. But anything that can make the holder's account call `fill` (its key, a phishing signature, a wallet module or session key, an EIP-7702 delegate, a contract holder exposing arbitrary calls) can sell approved tokens at any price, and a defect in `NFTBid` would expose every approved token at once. See NFT_TRADING.md, "What an approval to NFTBid authorizes".
6. **Third-party contracts are trusted for their own behaviour.** A hostile NFT collection can lie in `ownerOf`; a hostile token can lie in `balanceOf`. Configs bind specific contracts; choosing them is the creator's responsibility.
7. **Blocking recipients.** A `proceedsTo`, royalty receiver or `PaintAction` payee that reverts on ETH blocks fills; the owner closes and recovers.
8. **Stray assets** sent to an order are reachable by its handler during fills and recoverable by its owner after closing. Assets sent to a handler contract are stuck or stealable, since handlers hold nothing by design.
9. **Return data size.** `execute` copies the callee's full return data; a hostile callee chosen by the creator or filler can make a fill expensive. It can only grief a transaction its own participant chose.
10. **CREATE2 collision gas.** Creating the same commitment twice reverts after consuming the gas given to the deployment.
11. **Toolchain.** via-IR compilation and transient storage are relatively new. The full suite runs on Solidity 0.8.30 for Prague; the core, clone and composition suites also pass on 0.8.28 for Cancun.
12. **Fork coverage is limited to the NFT handlers.** `NFTSale` and `NFTBid` are tested against real collections on a pinned mainnet fork (`test/fork/NFTFork.t.sol`). `PaintAction` uses only the local `Artwork` contract.
13. **Collection-wide bids pay for any token.** An `NFTBid` with `anyToken` accepts every token of its collection at the current price, so sellers will offer the least valuable ones. A creator who cares needs `anyToken = false` or a handler that narrows eligibility.
14. **One implementation for every order.** A bug in `Order` is a bug in every order, with no way to patch deployed orders. This was already true of identical full contracts; clones add one shared address that cannot be destroyed or replaced.
15. **Counterfactual addresses depend on the handler's code.** `orderAddress` uses the handler's current code hash. Predicting an order for a handler that is not yet deployed gives a different address from the one `create` will use; deploy the handler first.
16. **Handler events need a trusted source.** `Sold` and `Bought` describe genuine fills, but any contract can emit an event with the same signature. Read events only from the handler addresses you trust, and cross-reference `Market.Created` if only Market-created orders count: a clone of the implementation deployed without Market is a real order with real settlement (I1).
17. **Explorer and tooling support.** Orders appear as minimal proxies. Their terms are read through the getters or decoded from the last 104 bytes of their code, not from storage.
18. **Closing does not revoke.** A closed order still holds whatever approvals, roles and grants it was given until its owner revokes them (D003).
19. **An active order is a commitment of authority, not an escrow guarantee.** It may be unfunded, its handler may deliberately move assets during fills, and permissions others granted it can be revoked by them. Read the handler and the current state before relying on an order.
20. **Owners cannot service active orders.** Anything that needs the order itself to act after creation (grant or refresh an approval, accept a two-step ownership transfer, claim an airdrop, vote) is possible only through the handler during a fill, or after closing. A handler without such a path leaves those actions until the order is closed.
21. **Nested fills on a shared handler.** While two orders bound to one handler are both filling, the handler can act through either. Only the handler's discipline keeps them apart (threats above).
22. **NFT handler assumptions.** Collections are trusted to report `ownerOf` honestly; a royalty receiver that reverts blocks every fill of its collection; collections that do not report ERC2981 through ERC165 pay no royalty; collection-wide bids pay for the least valuable eligible token. See [NFT_TRADING.md](NFT_TRADING.md), "Security assumptions".

## Review findings

### Author finding A1: approvals to counterparty-owned orders

Found 2026-11-06 while building `NFTBid`, by the implementing agent. Severity for the examples: high for an EOA filler who approves and fills in separate transactions; the core behaves as specified (D003).

An order's owner can close the order at any moment and then make any call as the order. A filler who approves an order to pull payment or a token (as the removed examples `AcquisitionBid` and `TokenExchange` asked) has approved the order's owner too: the owner can watch for the approval, close the order and spend it before the fill lands. Proof: `test_approvalToAnOrderBelongsToItsOwner` in `test/NFTBid.t.sol`.

Resolution: `NFTBid` holds sellers' approvals itself and accepts calls only from genuine, filling orders bound to it (D205). On 2026-11-10 `AcquisitionBid` and `TokenExchange` were removed (D301); no supported contract asks a counterparty to approve or grant anything to an order it does not own. `PaintAction`'s painter role is granted by the token's owner to an order it owns. The core is unchanged: an owner's post-close `execute` remains unrestricted (D003, invariant 4).

### Removed examples

The first three reviews below covered examples removed on 2026-11-10 (D301): `DutchAuction`, `TokenExchange`, `AcquisitionBid`, the bid strategies and `CapitalPool`. Their findings (F2 to F4, H2, H4) and the PoCs that exercised them (`test_capitalPoolReentrancyBounded`, `test_bidDonationDoesNotOverdrawPool`, `test_zeroPriceFillResetsStrategyBase`, `test_closedOrderCannotDrawCapitalPool`) remain in history at commit `4598764`. Core regressions those PoCs carried were kept against supported code: cross-handler isolation and mutable handlers (`test/review/ReviewPoC.t.sol`), and the `filling()`-gated grant (`test_closedOrderCannotDrawFillingGatedGrant`).

### First review

Independent AI review (a separate agent given the code and the owner's requirements, not the author's conclusions) of `src/` and `examples/` at commit `a50ff04`. Not a human audit. Proof-of-concept tests: `test/review/ReviewPoC.t.sol`, 5 tests. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| F1 | Low (design) | The commitment binds the handler's address, not its behaviour; a mutable handler can change terms after a counterparty inspects the order (`test_mutableHandlerChangesTermsAfterCommit`) | Accepted and documented: D006, residual risk 2. The code-hash pin added on 2026-11-05 does not change this: the PoC's storage switch, like a proxy upgrade, leaves the code hash unchanged. |
| F2 | Low | `TokenExchange` measured the payment leg by balance change but the delivery leg only by return value, so a fee-on-transfer `give` token delivered less than the filler paid for | Fixed: delivery is measured on the recipient and reverts `ShortDelivery` (`test_feeOnTransferDeliveryRejected`). |
| F3 | Low (docs) | `CapitalPool`'s `cap` could be read as a lifetime budget; it limits only the amount claimable at one moment | Fixed: NatSpec now says lifetime draws are limited by `rate`, time and the pool's balance. |
| F4 | Info | A collection-wide bid pays up to its current maximum for any token, including cheap ones; and a sale at price 0 reset `RisingStrategy`'s base to 0, suppressing the curve (`test_zeroPriceFillResetsStrategyBase`) | Fixed the reset: the base never restarts below `startPrice`. On 2026-11-05 price 0 fills were rejected outright (D110, `test_zeroPriceSaleRejected`); a 1 wei sale still restarts the curve at `startPrice` (`test_cheapSaleRestartsAtStartPrice`). Overpaying for cheap tokens is inherent to a collection-wide bid and is listed below as residual risk 13. |

The reviewer also confirmed, with executed tests, cross-handler isolation, reentrancy safety of `CapitalPool.draw`, and that donating ETH to a bid order cannot extract more than the pool's grant.

### Second review

Independent AI review of the clone change (commit `03c263f` against `4f2d19c`), given the owner's requirements for clones, handler immutability, filler verification and the zero-price fix, not the author's conclusions. Not a human audit. Proof-of-concept tests: `test/review/CloneReviewPoC.t.sol`, 6 tests. No critical, high or medium findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| G1 | Low | `FillVerifier.requireIncrease` did not use up its snapshot, so a batch that took one snapshot and checked after each of two fills judged the second fill against the first fill's baseline and passed although nothing new arrived (`test_fillVerifierStaleSnapshotGivesFalseAssurance`) | Fixed: `requireIncrease` clears the snapshot it used, so the reuse reverts `NoSnapshot` (`test_snapshotIsUsedUp`). |
| G2 | Info | An EIP-7702 EOA delegated to the `Order` implementation is not caught by the implementation guard, since `address(this)` is the EOA | No change: its terms read as zero, so `fill` reverts `WrongConfig` and `execute` reverts `Unauthorized` (`test_eoaDelegatedToImplementationIsBrickedNotDrainable`). Listed under threats. |
| G3 | Info | ETH forced into the implementation (by `SELFDESTRUCT` elsewhere or as a block reward) is stuck | No change: unavoidable for any contract; nobody's expected funds are affected (`test_implementationCannotMoveForcedEth`). |
| G4 | Info | The code-hash pin proves only that the handler's bytecode is unchanged | Already documented (D006, residual risk 2); `MutableHandler` in `test/review/ReviewPoC.t.sol` shows it. |
| G5 | Info | `requireIncrease` passes if the value rose for any reason (an unrelated transfer in, a rebasing token); `requireEqual` copies unbounded return data | Inherent to delta checks; documented in residual risk 3 and the README. |

The reviewer also confirmed with executed tests that a front-runner cannot occupy a predicted order address, that a handler shared by two clones cannot act on the sibling, and that a genuine 23-byte contract not starting with `0xef` is accepted as a handler.

### Third review

Independent AI review of the lifecycle change (commit `dd71a9e` against `4a15d12`), given the owner's requirements for the active and closed lifecycle and for shared handlers, not the author's conclusions. Not a human audit. Proof-of-concept tests: `test/review/LifecycleReviewPoC.t.sol`, 6 tests, all confirming properties. No critical, high, medium or low findings in the core.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| H1 | Info | The owner of an active order cannot move anything it holds, even unrelated stray assets or while its handler is broken; the only lever is closing, which is permanent | By design (D003). A handler can offer a maintenance fill (`test_handlerCanAllowOwnerMaintenance`); otherwise the owner closes and recovers. Residual risk 20. |
| H2 | Info | In the fill that closes an order, `closed` and `filling` are both true, so a grant gated on `filling()` (such as `CapitalPool`) can still be drawn until that fill returns | No change: only the handler can act in that window, which is authority the order already committed to it. SPEC now states that `filling` does not imply active, for authors of such integrations. |
| H3 | Info | The implementation, and an EIP-7702 EOA delegated to it, cannot act as an order | Confirmed (`test_eoaDelegatedToImplementationIsInert`). |
| H4 | Info | `CapitalPool` pays any granted address whose `filling()` returns true, so its safety rests on granting only real orders | Unchanged, example code. `CapitalPool`'s NatSpec now says to grant only addresses from `Market.Created`. |

The reviewer confirmed with executed tests that an idle active order accepts nobody (fuzzed), that an owner's receive hook can neither close nor execute during a fill, that a handler keeps `execute` through the fill in which it closes the order and loses it afterwards, that a shared handler cannot reach a sibling that is not filling, and that a closed order's owner recovers the order's own ETH but cannot draw the pool. Not checked by the reviewer: the full suite, invariants and gas (run separately, STATUS.md), an EIP-7702 EOA delegated to a clone rather than the implementation, and third-party handlers beyond the examples.

### Fourth review

Independent AI review of the NFT handlers (`handlers/` at commit `df609b8`), given the code and the owner's requirements for NFT trading, not the author's conclusions or this document. Not a human audit. Proof-of-concept tests: `test/review/NFTReviewPoC.t.sol`, 4 tests, all pass as demonstrations. No critical, high, medium or low findings.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| N1 | Info | `NFTSale.maxRoyaltyBps` may exceed 10,000; harmless because `royaltyOf` already refuses a royalty above the price (`test_info_maxRoyaltyBpsAboveDenominatorIsHarmless`) | No change. |
| N2 | Info | A holder who approves `NFTBid` can still be phished into signing a fill naming an attacker's `proceedsTo`, one token per signed transaction; a router contract cannot sweep approved tokens because it becomes the caller itself (`test_phishingRouterCannotSweepApprovedTokens`) | Inherent to approval-based trading; documented in NFT_TRADING.md. Approve single tokens where possible. |

The reviewer also confirmed `_isOrder` against OpenZeppelin's clone template (a look-alike clone cannot spoof the caller, `test_lookAlikeCloneCannotSpoofCaller`), that reentry during delivery cannot overfill a persistent bid (`test_deliveryReentrancyCannotOverfillSameBid`), ETH conservation, that royalties are never skipped, schedule edge cases, and cancellation paths.

### Fifth review: simplification and supported release

Review of the whole system on 2026-11-10 by the implementing agent, before the supported release was cut (DECISIONS D301 to D304), followed by static analysis and an independent AI review of the result. Not a human audit.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| S1 | Low (integrity, no asset loss) | `NFTSale.onFill` did not check that its caller was a genuine order in a fill. A counterfeit contract with a no-op `execute` for ETH made the real handler emit `Sold` for a real ERC721 at 1,000 ETH with a 50 ETH royalty while no ETH moved and no royalty was paid, and a closed order's owner could do the same through `execute`. Anyone reading `Sold` as a sale record (wash prices, royalty accounting, analytics) could be misled. Confirmed by PoC against the unfixed code. | Fixed (D302): `NFTTrade._requireFill`, shared with `NFTBid`, reverts `NotAFill` unless `msg.sender` is a clone of Market's implementation, bound to this handler and filling. Regression: `test/review/SaleEventPoC.t.sol` (both tests emitted `Sold` before the fix). About 2,500 gas per sale fill. |
| S2 | Info | `PaintAction` relies on a painter role granted to the order. If someone other than the order's owner grants it, the owner can close the order and use it (A1). | Documented in its NatSpec and residual risk 4: the token's owner should grant the role only to an order it owns. |
| S3 | Info | Approvals to `NFTBid` are shared by all its bids and holders; the documentation called the handler's authority "per order" in places. | Documentation corrected (README, NFT_TRADING.md, residual risk 5). No code change: the handler already moves a token only in a fill whose caller is the holder. |

Other supported handlers checked for S1 and A1: `NFTBid` already authenticated its caller and holds approvals only for authenticated fills; `PaintAction` emits no events and holds nothing, and its effects go through the calling order, so a direct call acts only on the caller's own contract; `FillVerifier` has no authority and keys snapshots by caller. No supported contract asks a counterparty to approve or grant anything to an order the counterparty does not own.

Independent AI review of the supported contracts at commit `69f2455` (a separate agent given the code, the owner's goals and the attack classes, not the author's conclusions). Proof-of-concept tests: `test/review/IndependentReviewPoC.t.sol`, 9 tests, all refusals. No critical, high, medium or low findings. The reviewer identified the load-bearing line as the `from` of `NFTBid`'s delivery: it is always the authenticated `caller`, so neither a clone deployed without Market, a third-party fill naming someone else's token, nor a closed order's owner can use a holder's approval. Informational notes:

| # | Severity | Note | Resolution |
| --- | --- | --- | --- |
| I1 | Info | A clone of the implementation deployed without Market can be bound to a handler and emit genuine `Sold` or `Bought` for real, self-dealt settlement that `Market.Created` never announced | No change. Documented in NFT_TRADING.md and residual risk 16: cross-reference `Market.Created` to restrict to Market orders. |
| I2 | Info | `PaintAction` has no `_requireFill` | Safe: it acts only through `Order(msg.sender).execute` and emits nothing (S2 covers the painter-role grant). |
| I3 | Info | An `NFTBid` seller accepts the bidder's `recipient` from config, not input | By design; the seller is paid at least `minProceeds`. |

Static analysis: Slither 0.11.5, 101 detectors, over `src/`, `handlers/`, `periphery/` and `examples/` compiled together (solc 0.8.30, via-IR). 21 results, none actionable; triage in STATUS.md.
