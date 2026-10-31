import type { Address, Hex } from "viem";
import { WETH } from "../lib/order";

// Typed Seaport order, ready to pass to Market.fillOffer.
export type Item = { itemType: number; token: Address; identifierOrCriteria: bigint; startAmount: bigint; endAmount: bigint };
export type ConsiderationItem = Item & { recipient: Address };
export type Order = {
  parameters: {
    offerer: Address;
    zone: Address;
    offer: Item[];
    consideration: ConsiderationItem[];
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
export type Resolver = { orderIndex: bigint; side: number; index: bigint; identifier: bigint; criteriaProof: Hex[] };

const big = (x: unknown) => BigInt(x as string);
const item = (x: any): Item => ({ itemType: Number(x.itemType), token: x.token, identifierOrCriteria: big(x.identifierOrCriteria), startAmount: big(x.startAmount), endAmount: big(x.endAmount) });
const consideration = (x: any): ConsiderationItem => ({ ...item(x), recipient: x.recipient });

/** OpenSea JSON order (decimal strings) to a typed AdvancedOrder. */
export function parseOrder(o: any): Order {
  const p = o.parameters;
  return {
    parameters: {
      offerer: p.offerer,
      zone: p.zone,
      offer: p.offer.map(item),
      consideration: p.consideration.map(consideration),
      orderType: Number(p.orderType),
      startTime: big(p.startTime),
      endTime: big(p.endTime),
      zoneHash: p.zoneHash,
      salt: big(p.salt),
      conduitKey: p.conduitKey,
      totalOriginalConsiderationItems: p.totalOriginalConsiderationItems != null ? big(p.totalOriginalConsiderationItems) : BigInt(p.consideration.length),
    },
    numerator: o.numerator != null ? big(o.numerator) : 1n,
    denominator: o.denominator != null ? big(o.denominator) : 1n,
    signature: o.signature ?? "0x",
    extraData: o.extraData ?? "0x",
  };
}

const parseResolver = (r: any): Resolver => ({ orderIndex: big(r.orderIndex), side: Number(r.side), index: big(r.index), identifier: big(r.identifier), criteriaProof: (r.criteriaProof ?? []) as Hex[] });

/**
 * OpenSea's `POST /offers/fulfillment_data` returns either a `fulfillAdvancedOrder`
 * or a `matchAdvancedOrders` input_data shape. Both reduce to one signed offer order
 * and the resolvers that point at it, as `fillOffer` wants (offer is order index 0).
 *
 * - fulfillAdvancedOrder: the offer is `advancedOrder`; resolvers already index 0.
 * - matchAdvancedOrders: the offer is the order whose offerer is not the fulfiller
 *   (the other order is the mirror OpenSea builds for the NFT side); keep only the
 *   resolvers aimed at it and remap them to order index 0.
 */
export function normalizeFulfillment(input: any, fulfiller: Address): { order: Order; resolvers: Resolver[] } {
  if (input.advancedOrder) {
    return { order: parseOrder(input.advancedOrder), resolvers: (input.criteriaResolvers ?? []).map(parseResolver) };
  }
  if (Array.isArray(input.orders) && input.orders.length) {
    const orders = input.orders as any[];
    let idx = orders.findIndex((o) => o.parameters.offerer.toLowerCase() !== fulfiller.toLowerCase());
    if (idx < 0) idx = 0;
    const resolvers = (input.criteriaResolvers ?? [])
      .map(parseResolver)
      .filter((r: Resolver) => Number(r.orderIndex) === idx)
      .map((r: Resolver) => ({ ...r, orderIndex: 0n }));
    return { order: parseOrder(orders[idx]), resolvers };
  }
  throw new Error("unrecognized fulfillment_data shape");
}

// Seaport AmountDeriver: linear interpolation over time, applied per unit fraction.
function amount(i: Item, o: Order, now: bigint, roundUp: boolean): bigint {
  const frac = (x: bigint) => (x * o.numerator) / o.denominator;
  const s = frac(i.startAmount);
  const e = frac(i.endAmount);
  if (s === e) return e;
  const { startTime, endTime } = o.parameters;
  const duration = endTime - startTime;
  const elapsed = now - startTime;
  const total = s * (duration - elapsed) + e * elapsed;
  if (total === 0n) return 0n;
  return roundUp ? (total - 1n) / duration + 1n : total / duration;
}

/**
 * WETH the offer releases to Market after its own mandatory consideration (OpenSea
 * fee, royalties), i.e. the sale price Market can keep. Null if the offer is not a
 * single WETH offer with WETH-only fees, or is outside its time window.
 */
export function released(o: Order, now: bigint): bigint | null {
  const { offer, consideration: c } = o.parameters;
  if (offer.length !== 1 || offer[0].itemType !== 1 || offer[0].token.toLowerCase() !== WETH.toLowerCase()) return null;
  if (now < o.parameters.startTime || now >= o.parameters.endTime) return null;
  let r = amount(offer[0], o, now, false);
  for (const k of c.slice(1)) {
    if (k.itemType !== 1 || k.token.toLowerCase() !== WETH.toLowerCase()) return null;
    r -= amount(k, o, now, true);
  }
  return r > 0n ? r : null;
}

/**
 * Fees for a same-nonce replacement: double today's estimate, but never less than
 * 115% of what was last sent, or nodes reject it as underpriced (D022).
 */
export function replacementFees(now: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }, last: { maxFee?: string; tip?: string }) {
  const atLeast = (x: bigint, prev?: string) => {
    const floor = prev ? (BigInt(prev) * 115n) / 100n : 0n;
    return x > floor ? x : floor;
  };
  return { maxFee: atLeast(now.maxFeePerGas * 2n, last.maxFee), tip: atLeast(now.maxPriorityFeePerGas * 2n + 1n, last.tip) };
}
