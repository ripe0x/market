import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { decodeFunctionData, parseAbi, type Hex } from "viem";
import { parseBid, released } from "./match";

const matchAbi = parseAbi([
  "struct OfferItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; }",
  "struct ConsiderationItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; address recipient; }",
  "struct OrderParameters { address offerer; address zone; OfferItem[] offer; ConsiderationItem[] consideration; uint8 orderType; uint256 startTime; uint256 endTime; bytes32 zoneHash; uint256 salt; bytes32 conduitKey; uint256 totalOriginalConsiderationItems; }",
  "struct AdvancedOrder { OrderParameters parameters; uint120 numerator; uint120 denominator; bytes signature; bytes extraData; }",
  "struct CriteriaResolver { uint256 orderIndex; uint8 side; uint256 index; uint256 identifier; bytes32[] criteriaProof; }",
  "struct FulfillmentComponent { uint256 orderIndex; uint256 itemIndex; }",
  "struct Fulfillment { FulfillmentComponent[] offerComponents; FulfillmentComponent[] considerationComponents; }",
  "function matchAdvancedOrders(AdvancedOrder[] orders, CriteriaResolver[] criteriaResolvers, Fulfillment[] fulfillments, address recipient)",
]);

function fixtureBid(name: string) {
  const f = JSON.parse(readFileSync(new URL(`../../test/fixtures/${name}.json`, import.meta.url), "utf8"));
  const { args } = decodeFunctionData({ abi: matchAbi, data: f.input as Hex });
  return { bid: parseBid(args[0][0]), timestamp: BigInt(f.timestamp) };
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
