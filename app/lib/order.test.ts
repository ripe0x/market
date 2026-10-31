import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeAbiParameters } from "viem";
import { askAt, bidPriceAt, builtinPrice, buyLimit, buyerPrice, fixedPrice, listData, sellData, type Bid, type Listing, type Price } from "./order";

const addr = "0x00000000000000000000000000000000000000a1";
const curve = (start: bigint, end: bigint): Price => ({ start, end, startTime: 1000, endTime: 1000 + 86400, strategy: "0x0000000000000000000000000000000000000000", data: `0x${"0".repeat(64)}` });

test("built-in price interpolates linearly and holds at the ends", () => {
  const p = curve(2n * 10n ** 18n, 10n ** 18n);
  assert.equal(builtinPrice(p, 999n, false), 2n * 10n ** 18n); // before start holds start
  assert.equal(builtinPrice(p, 1000n + 86400n + 1n, false), 10n ** 18n); // after end holds end
  assert.equal(builtinPrice(p, 1000n + 43200n, false), 15n * 10n ** 17n); // halfway
  // A listing rounds up, a bid rounds down, so neither flatters its owner.
  const odd = curve(3n, 0n);
  odd.endTime = odd.startTime + 3;
  assert.equal(builtinPrice(odd, BigInt(odd.startTime) + 1n, false), 2n);
  assert.equal(builtinPrice(odd, BigInt(odd.startTime) + 1n, true), 2n);
});

test("ask never falls below the floor; strategy prices read null", () => {
  const l: Listing = { seller: addr, nft: addr, tokenId: 1n, currency: addr, recipient: addr, floor: 15n * 10n ** 17n, expiry: 0, price: curve(2n * 10n ** 18n, 10n ** 18n) };
  assert.equal(askAt(l, 1000n + 86400n), 15n * 10n ** 17n); // end 1.0 clamped up to floor 1.5
  l.price = { ...l.price, strategy: "0x00000000000000000000000000000000000000ff" };
  assert.equal(askAt(l, 1000n), null);
});

test("bid price is clamped to maxPrice", () => {
  const b = { maxPrice: 10n ** 18n, price: curve(3n * 10n ** 18n, 3n * 10n ** 18n) } as Bid;
  assert.equal(bidPriceAt(b, 2000n), 10n ** 18n);
});

test("buyerPrice grosses the ask up past the protocol fee", () => {
  for (const ask of [1n, 10n ** 18n, 123456789012345678n]) {
    const p = buyerPrice(ask);
    assert.ok(p - (p * 20n) / 10_000n >= ask, "proceeds cover the ask");
  }
});

test("buyLimit adds headroom only when the price can rise", () => {
  const l: Listing = { seller: addr, nft: addr, tokenId: 1n, currency: addr, recipient: addr, floor: 0n, expiry: 0, price: curve(2n, 1n) };
  assert.equal(buyLimit(l, 1000n), 1000n); // falling
  l.price = fixedPrice(5n);
  assert.equal(buyLimit(l, 1000n), 1000n); // fixed
  l.price = curve(1n, 2n);
  assert.equal(buyLimit(l, 1000n), 1010n); // rising
  assert.equal(buyLimit(l, 1001n), 1012n); // headroom rounds up
  l.price = { ...curve(2n, 1n), strategy: "0x00000000000000000000000000000000000000ff" };
  assert.equal(buyLimit(l, 1000n), 1010n); // external strategy
});

test("listData and sellData encode the structs Market decodes back", () => {
  const price = fixedPrice(10n ** 18n);
  const l: Listing = { seller: addr, nft: addr, tokenId: 7n, currency: addr, recipient: addr, floor: 10n ** 18n, expiry: 123, price };
  const d = listData(l);
  assert.equal(d.slice(0, 4), "0x00");
  const [decoded] = decodeAbiParameters(
    [{ type: "tuple", components: [{ name: "seller", type: "address" }, { name: "nft", type: "address" }, { name: "tokenId", type: "uint256" }, { name: "currency", type: "address" }, { name: "recipient", type: "address" }, { name: "floor", type: "uint128" }, { name: "expiry", type: "uint40" }, { name: "price", type: "tuple", components: [{ name: "start", type: "uint128" }, { name: "end", type: "uint128" }, { name: "startTime", type: "uint40" }, { name: "endTime", type: "uint40" }, { name: "strategy", type: "address" }, { name: "data", type: "bytes32" }] }] }],
    `0x${d.slice(4)}`,
  );
  assert.equal((decoded as any).tokenId, 7n);
  assert.equal((decoded as any).price.start, 10n ** 18n);

  const b: Bid = { buyer: addr, recipient: addr, nft: addr, minTokenId: 0n, maxTokenId: 5n, currency: addr, budget: 10n ** 18n, maxPrice: 10n ** 18n, quantity: 2, expiry: 99, price };
  assert.equal(sellData(b, 3n, 10n ** 17n, addr).slice(0, 4), "0x01");
});
