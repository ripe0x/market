import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { decodeFunctionData, type Hex } from "viem";
import { seaportAbi, WETH } from "../lib/order";
import { normalizeFulfillment, parseOrder, released, replacementFees } from "./match";

const MARKET = "0x000000000000000000000000000000000000ffff";
const BIDDER = "0x00000000000000000000000000000000000000b1";
const zeroHash = `0x${"0".repeat(64)}` as Hex;

function order(offerer: string) {
  return {
    parameters: {
      offerer,
      zone: "0x000056F7000000EcE9003ca63978907a00FFD100",
      offer: [{ itemType: 1, token: WETH, identifierOrCriteria: "0", startAmount: "1000", endAmount: "1000" }],
      consideration: [{ itemType: 4, token: "0x00000000000000000000000000000000000000c1", identifierOrCriteria: "0", startAmount: "1", endAmount: "1", recipient: offerer }],
      orderType: 2,
      startTime: "0",
      endTime: "9999999999",
      zoneHash: zeroHash,
      salt: "1",
      conduitKey: zeroHash,
      totalOriginalConsiderationItems: "1",
    },
    numerator: "1",
    denominator: "1",
    signature: "0x" as Hex,
    extraData: "0x" as Hex,
  };
}

test("normalize: fulfillAdvancedOrder shape passes the order and resolvers through", () => {
  const input = { advancedOrder: order(BIDDER), criteriaResolvers: [{ orderIndex: "0", side: 0, index: "0", identifier: "42", criteriaProof: [] }] };
  const { order: o, resolvers } = normalizeFulfillment(input, MARKET);
  assert.equal(o.parameters.offerer, BIDDER);
  assert.equal(resolvers.length, 1);
  assert.equal(resolvers[0].orderIndex, 0n);
  assert.equal(resolvers[0].identifier, 42n);
});

test("normalize: matchAdvancedOrders shape picks the non-fulfiller order and remaps resolvers", () => {
  // Two orders: the mirror OpenSea builds for the fulfiller (Market) and the real offer.
  const input = {
    orders: [order(MARKET), order(BIDDER)],
    criteriaResolvers: [
      { orderIndex: "0", side: 0, index: "0", identifier: "1", criteriaProof: [] }, // mirror, dropped
      { orderIndex: "1", side: 1, index: "0", identifier: "77", criteriaProof: [] }, // offer, kept and remapped
    ],
  };
  const { order: o, resolvers } = normalizeFulfillment(input, MARKET);
  assert.equal(o.parameters.offerer, BIDDER);
  assert.equal(resolvers.length, 1);
  assert.equal(resolvers[0].orderIndex, 0n);
  assert.equal(resolvers[0].identifier, 77n);
});

function fixtureOrder(name: string) {
  const f = JSON.parse(readFileSync(new URL(`../../test/fixtures/${name}.json`, import.meta.url), "utf8"));
  const { args } = decodeFunctionData({ abi: seaportAbi, data: f.input as Hex });
  return { input: { orders: (args as any)[0], criteriaResolvers: (args as any)[1] }, from: f.from as string, timestamp: BigInt(f.timestamp) };
}

test("released WETH matches the real OpenSea item offer", () => {
  const { input, timestamp } = fixtureOrder("item_offer");
  const { order: o } = normalizeFulfillment(input, "0x000000000000000000000000000000000000dead");
  assert.equal(released(o, timestamp), 61700000000000000n - 617000000000000n);
});

test("released WETH matches the real collection offer after royalty", () => {
  const { input, timestamp } = fixtureOrder("collection_offer_royalty");
  const { order: o } = normalizeFulfillment(input, "0x000000000000000000000000000000000000dead");
  assert.equal(released(o, timestamp), 235000000000000000n - 2350000000000000n - 11750000000000000n);
});

test("parseOrder accepts bigint or string amounts; expired offers release nothing", () => {
  const o = parseOrder(order(BIDDER));
  assert.equal(released(o, o.parameters.endTime), null);
});

test("replacement outbids the last send even after the base fee drops (D022)", () => {
  const gwei = 10n ** 9n;
  assert.deepEqual(replacementFees({ maxFeePerGas: 4n * gwei, maxPriorityFeePerGas: gwei }, { maxFee: String(20n * gwei), tip: String(2n * gwei) }), { maxFee: 23n * gwei, tip: (23n * gwei) / 10n });
  assert.deepEqual(replacementFees({ maxFeePerGas: 30n * gwei, maxPriorityFeePerGas: gwei }, { maxFee: String(20n * gwei), tip: "1" }), { maxFee: 60n * gwei, tip: 2n * gwei + 1n });
});
