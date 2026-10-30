import assert from "node:assert/strict";
import { test } from "node:test";
import { buildListing, buyerTotal, listingProblem, matchSplit, minReleasedFor, priceAt, MARKET } from "./order";

const base = {
  seller: "0x00000000000000000000000000000000000000a1",
  nft: "0x00000000000000000000000000000000000000b2",
  tokenId: 7n,
  start: 2n * 10n ** 18n,
  floor: 10n ** 18n,
  startTime: 1000n,
  endTime: 1000n + 864000n,
  counter: 0n,
  salt: 1n,
} as const;

test("price declines linearly, rounds up, and is null outside the window", () => {
  const c = buildListing(base);
  assert.equal(priceAt(c, 999n), null);
  assert.equal(priceAt(c, 1000n), base.start);
  assert.equal(priceAt(c, 1000n + 432000n), 15n * 10n ** 17n);
  assert.equal(priceAt(c, base.endTime), null);
  // 1 wei over 3 seconds rounds up, never below the exact value
  const odd = buildListing({ ...base, start: 1n, floor: 0n, startTime: 0n, endTime: 3n });
  assert.deepEqual([0n, 1n, 2n].map((t) => priceAt(odd, t)), [1n, 1n, 1n]);
});

test("price never increases", () => {
  const c = buildListing({ ...base, start: 3n * 10n ** 18n + 7n, floor: 10n ** 18n - 3n, endTime: base.startTime + 604813n });
  let last = priceAt(c, c.startTime)!;
  for (let t = c.startTime; t < c.endTime; t += 997n) {
    const p = priceAt(c, t)!;
    assert.ok(p <= last);
    last = p;
  }
});

test("fees", () => {
  assert.equal(buyerTotal(10n ** 18n), 10n ** 18n + 2n * 10n ** 15n);
  const s = matchSplit(2n * 10n ** 18n);
  assert.deepEqual(s, { executorFee: 6n * 10n ** 15n, protocolFee: 4n * 10n ** 15n, seller: 199n * 10n ** 16n });
  for (const p of [1n, 999n, 10n ** 18n, 123456789012345678n]) {
    const r = minReleasedFor(p);
    assert.ok(matchSplit(r).seller >= p);
    assert.ok(matchSplit(r - 1n).seller < p);
  }
});

test("listing shape checks", () => {
  const c = buildListing(base);
  assert.equal(c.zone, MARKET);
  assert.equal(listingProblem(c), null);
  assert.equal(listingProblem({ ...c, orderType: 0 }), "wrong order type");
  assert.equal(listingProblem(buildListing({ ...base, start: 0n, floor: 0n })), "start price must be above zero");
  assert.equal(listingProblem(buildListing({ ...base, floor: base.start + 1n })), "floor above start");
  const other = { ...c, consideration: [{ ...c.consideration[0], recipient: "0x00000000000000000000000000000000000000c3" as const }] };
  assert.equal(listingProblem(other), "proceeds must go to the seller");
});
