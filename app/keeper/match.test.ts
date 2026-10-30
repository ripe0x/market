import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { decodeFunctionData, type Hex } from "viem";
import { seaportAbi } from "../lib/order";
import { parseBid, released, replacementFees } from "./match";


function fixtureBid(name: string) {
  const f = JSON.parse(readFileSync(new URL(`../../test/fixtures/${name}.json`, import.meta.url), "utf8"));
  const { args } = decodeFunctionData({ abi: seaportAbi, data: f.input as Hex });
  return { bid: parseBid((args as any)[0][0]), timestamp: BigInt(f.timestamp) };
}

// Same real OpenSea bids the Foundry fork tests settle; numbers match those runs.
test("released WETH from real item offer", () => {
  const { bid, timestamp } = fixtureBid("item_offer");
  assert.equal(released(bid, timestamp), 61700000000000000n - 617000000000000n);
});

test("released WETH from real collection offer with royalty", () => {
  const { bid, timestamp } = fixtureBid("collection_offer_royalty");
  assert.equal(released(bid, timestamp), 235000000000000000n - 2350000000000000n - 11750000000000000n);
});

test("expired or non-WETH bids release nothing", () => {
  const { bid } = fixtureBid("item_offer");
  assert.equal(released(bid, bid.parameters.endTime), null);
  const usdc = structuredClone(bid);
  usdc.parameters.offer[0].token = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  assert.equal(released(usdc, bid.parameters.startTime), null);
});

test("replacement outbids the last send even after base fee drops", () => {
  const gwei = 10n ** 9n;
  // Sent at 20 gwei; base fee then fell so 2x today is only 8 gwei.
  assert.deepEqual(replacementFees({ maxFeePerGas: 4n * gwei, maxPriorityFeePerGas: gwei }, { maxFee: String(20n * gwei), tip: String(2n * gwei) }), {
    maxFee: 23n * gwei,
    tip: 23n * gwei / 10n,
  });
  // Fees rose: 2x today wins.
  assert.deepEqual(replacementFees({ maxFeePerGas: 30n * gwei, maxPriorityFeePerGas: gwei }, { maxFee: String(20n * gwei), tip: "1" }), {
    maxFee: 60n * gwei,
    tip: 2n * gwei + 1n,
  });
});
