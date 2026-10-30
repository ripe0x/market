import type { Address, Hex } from "viem";
import { WETH, toAdvancedOrder, type Components } from "../lib/order";

export type Item = { itemType: number; token: Address; identifierOrCriteria: bigint; startAmount: bigint; endAmount: bigint; recipient?: Address };
export type Bid = {
  parameters: {
    offerer: Address;
    zone: Address;
    offer: Item[];
    consideration: (Item & { recipient: Address })[];
    orderType: number;
    startTime: bigint;
    endTime: bigint;
    zoneHash: Hex;
    salt: bigint;
    conduitKey: Hex;
    totalOriginalConsiderationItems: bigint;
  };
  numerator: bigint;
  denominator: bigint;
  signature: Hex;
  extraData: Hex;
};

const big = (x: unknown) => BigInt(x as string);
const item = (x: any): Item => ({
  itemType: Number(x.itemType),
  token: x.token,
  identifierOrCriteria: big(x.identifierOrCriteria),
  startAmount: big(x.startAmount),
  endAmount: big(x.endAmount),
  ...(x.recipient ? { recipient: x.recipient } : {}),
});

/** OpenSea JSON (decimal strings) to typed AdvancedOrder. */
export function parseBid(o: any, units = 1n): Bid {
  const p = o.parameters;
  // A multi-unit collection offer is filled one unit at a time.
  const quantity = big(p.consideration[0].startAmount);
  return {
    parameters: {
      offerer: p.offerer,
      zone: p.zone,
      offer: p.offer.map(item),
      consideration: p.consideration.map(item) as Bid["parameters"]["consideration"],
      orderType: Number(p.orderType),
      startTime: big(p.startTime),
      endTime: big(p.endTime),
      zoneHash: p.zoneHash,
      salt: big(p.salt),
      conduitKey: p.conduitKey,
      totalOriginalConsiderationItems: big(p.totalOriginalConsiderationItems),
    },
    numerator: o.numerator != null ? big(o.numerator) : units,
    denominator: o.denominator != null ? big(o.denominator) : quantity,
    signature: o.signature ?? "0x",
    extraData: o.extraData ?? "0x",
  };
}

// Seaport AmountDeriver: fraction first, then linear interpolation over time.
function amount(i: Item, b: Bid, now: bigint, roundUp: boolean): bigint {
  const { numerator: n, denominator: d } = b;
  const frac = (x: bigint) => {
    if ((x * n) % d !== 0n) throw new Error("inexact fraction");
    return (x * n) / d;
  };
  const s = frac(i.startAmount);
  const e = frac(i.endAmount);
  if (s === e) return e;
  const { startTime, endTime } = b.parameters;
  const duration = endTime - startTime;
  const elapsed = now - startTime;
  const total = s * (duration - elapsed) + e * elapsed;
  if (total === 0n) return 0n;
  return roundUp ? (total - 1n) / duration + 1n : total / duration;
}

/**
 * WETH the bid releases after its own mandatory consideration, i.e. what reaches
 * the seller side (seller amount plus surplus). Null if the bid is not a single
 * WETH offer for one ERC721 with only WETH fees.
 */
export function released(b: Bid, now: bigint): bigint | null {
  const { offer, consideration } = b.parameters;
  if (offer.length !== 1 || offer[0].itemType !== 1 || offer[0].token.toLowerCase() !== WETH.toLowerCase()) return null;
  if (now < b.parameters.startTime || now >= b.parameters.endTime) return null;
  let r = amount(offer[0], b, now, false);
  for (const c of consideration.slice(1)) {
    if (c.itemType !== 1 || c.token.toLowerCase() !== WETH.toLowerCase()) return null;
    r -= amount(c, b, now, true);
  }
  return r > 0n ? r : null;
}

const fc = (orderIndex: bigint, itemIndex: bigint) => ({ orderIndex, itemIndex });
const pair = (a: [bigint, bigint], b: [bigint, bigint]) => ({ offerComponents: [fc(...a)], considerationComponents: [fc(...b)] });

/** Arguments for Market.matchOffer over orders [listing, bid]. */
export function matchArgs(listing: Components, signature: Hex, bid: Bid) {
  const tokenId = listing.offer[0].identifierOrCriteria;
  const nftWanted = bid.parameters.consideration[0];
  const fulfillments = [pair([0n, 0n], [1n, 0n]), pair([1n, 0n], [0n, 0n])];
  for (let i = 1n; i < BigInt(bid.parameters.consideration.length); i++) fulfillments.push(pair([1n, 0n], [1n, i]));
  // Collection offer (criteria 0 = any token): resolve to this token, no proof.
  const criteriaResolvers =
    nftWanted.itemType === 4 ? [{ orderIndex: 1n, side: 1, index: 0n, identifier: tokenId, criteriaProof: [] as Hex[] }] : [];
  return [toAdvancedOrder(listing, signature), bid, criteriaResolvers, fulfillments] as const;
}

/**
 * Fees for a same-nonce replacement: double today's estimate, but never less
 * than 115% of what was last sent, or nodes reject it as underpriced.
 */
export function replacementFees(now: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }, last: { maxFee?: string; tip?: string }) {
  const atLeast = (x: bigint, prev?: string) => {
    const floor = prev ? (BigInt(prev) * 115n) / 100n : 0n;
    return x > floor ? x : floor;
  };
  return { maxFee: atLeast(now.maxFeePerGas * 2n, last.maxFee), tip: atLeast(now.maxPriorityFeePerGas * 2n + 1n, last.tip) };
}
