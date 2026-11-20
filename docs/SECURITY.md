# Security model

Experimental and unaudited. Automated tests and the author's adversarial review are not an independent audit and do not establish that the contracts are safe.

## Trust boundaries

| Party | Trusted for | Not trusted for |
| --- | --- | --- |
| Market, Order, Actions | Their fixed code. No admin, upgrade or allowlist. | Anything about an action's meaning. |
| Action implementation | Everything an order's executions and releases do with its assets, within the core's limits. Pinned by runtime code hash. | Nothing outside its own orders. Its code hash does not pin proxies, storage or dependencies. |
| Issuer | Choosing the commitments and supplying backing. | Acting as the order. Canceling a live Holder order. |
| Residual | Receiving backing and surplus after the order stops being live. | Spending credits. Acting as the order. |
| Actions token owner | Executing or surrendering a live Holder order. | Transferring after the deadline or during execution. |
| ERC721 operator of an Actions token | Moving the token (and then acting as its owner). | Executing or surrendering directly. |
| Fee admin | Setting the fee rate (at most 1%, applies to later activations) and recipient (applies to every later execution). | Changing a live order's snapshotted rate. |
| Reservation target | Enforcing its own reservations. | Market knowledge; the core never queries it. |
| Collections, royalty receivers, payees | Nothing. They may revert, reenter or lie in `ownerOf`. | |

## Core properties

1. Every order's address commits to issuer, action and its runtime code hash, admission, deadline, residual, full config and salt; all are readable after termination.
2. Provenance (`Market.isOrder`) is recorded before any callback; only Market's `createAndActivate` path can activate on the issuer's behalf, and only for the order it just created.
3. Only the bound action acts as the order, only during execute or release; releases carry no ETH. No issuer or residual call path exists.
4. Phase guard: one operation per order at a time; reentry reverts `Busy`; independent orders compose.
5. `balance >= totalCredits`; execution payments, release and surplus withdrawal spend only `freeBalance`. Credits are created only during execution and survive every terminal state.
6. Holder orders: only the token owner executes or surrenders; incomplete executions revert; the issuer cannot cancel; terminal transitions burn; tokens move only while live and never to their own order.
7. Exclusive deadline takes effect immediately without a keeper; anyone records expiry.
8. A failed action, payment, delivery or burn reverts the whole execution.

## Threats considered

- **Factory impersonation.** Actions check `Market.isOrder`; Actions mint/burn require the canonical order in the right phase and state; foreign clones of the implementation are never trusted.
- **Forged callback context.** `ActionBase` compares actor, supplied value, release recipient, config and activation terms with the calling order's readable values in the matching phase.
- **Bid approval abuse (finding U1).** An NFT approved to a bid's Order could be taken by any code running with the order's identity, for example a collection whose `receive` acts for its caller when the issuer withdraws surplus to it, or a proceeds receiver reached during execution. Fix: approvals go to `ExchangeAction`, which moves only the executing actor's named token during a validated execution and has no general call ability. Regressions: `test/BidApproval.t.sol`.
- **Royalty and fee manipulation.** The fee rate is fixed at activation within the issuer's bound; royalties are capped at `price - fee` and bounded by seller limits; covered purchases snapshot their royalty.
- **Insolvency.** Bids check free balance on every execution; credits cannot be spent by later payments.
- **Duplicate execution.** Phase guard, terminal states, bid counters updated before external effects, target-side consumption.
- **Stranded backing.** Termination never depends on cleanup; release is retryable; residual chooses recipients; Pending setups stay recoverable without rechecking activation policy.
- **Griefing reservations.** Only the residual may release a Pending reserved order's reservation; executors are single-use.

## Residual risks

- Unknown assets sent to an order, or orders bound to a broken custom action, can be unrecoverable. There is no generic rescue.
- Ending an order does not revoke roles or approvals other contracts granted to its address.
- An ETH transfer with empty calldata calls the receiver as the order.
- `ownerOf`-based delivery checks trust the collection.
- Reservation targets must enforce their own authority, expiry and consumption; a perpetual reservation to an unusable executor occupies its scope forever; target code hash checks do not freeze proxies or mutable dependencies.
- ERC721 operators of Actions tokens can take the token and execute.
- Reservation executor poisoning (finding R1, low): a reservation record is permanent per executor address, so anyone the target lets reserve (for example any Artwork token owner) can reserve first for another issuer's predicted order address, after which that address can never hold the intended reservation. No funds are lost. The `reserve` transaction itself reveals the address, so an unpredictable salt alone does not prevent it; reserve and create in one atomic transaction (wallet batching) or submit privately. Regression: `test/review/ReviewReservation.t.sol`.
- Transferring backing to a predicted address before `create` leaves it at an address no contract controls until the order is created. Prefer create, then transfer, then activate.
- Royalty is paid on execution prices only through the action that pays it; Actions token resale premiums carry no royalty.
- Fee recipient or royalty receiver refusing ETH blocks ordinary exchanges until changed; the seller can cancel and recover.

Earlier findings for the order and rights designs remain in git history (`git show 0e8832c:docs/SECURITY.md`).
