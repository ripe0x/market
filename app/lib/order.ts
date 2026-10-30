import { parseAbi, type Address, type Hex } from "viem";

// Canonical Ethereum mainnet dependencies. A local fork shares them.
export const SEAPORT: Address = "0x0000000000000068F116a894984e2DB1123eB395";
export const WETH: Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
export const OS_CONDUIT_KEY: Hex = "0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000";
export const OS_CONDUIT: Address = "0x1E0049783F008A0085193E00003D00cd54003c71";
export const MARKET = (process.env.NEXT_PUBLIC_MARKET_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address;
export const CHAIN_ID = 1;

export const EXECUTOR_FEE_BPS = 30n;
export const PROTOCOL_FEE_BPS = 20n;
const BPS = 10_000n;

export type OfferItem = { itemType: number; token: Address; identifierOrCriteria: bigint; startAmount: bigint; endAmount: bigint };
export type ConsiderationItem = OfferItem & { recipient: Address };
export type Components = {
  offerer: Address;
  zone: Address;
  offer: OfferItem[];
  consideration: ConsiderationItem[];
  orderType: number;
  startTime: bigint;
  endTime: bigint;
  zoneHash: Hex;
  salt: bigint;
  conduitKey: Hex;
  counter: bigint;
};

export const seaportDomain = { name: "Seaport", version: "1.6", chainId: CHAIN_ID, verifyingContract: SEAPORT } as const;

export const orderTypes = {
  OrderComponents: [
    { name: "offerer", type: "address" },
    { name: "zone", type: "address" },
    { name: "offer", type: "OfferItem[]" },
    { name: "consideration", type: "ConsiderationItem[]" },
    { name: "orderType", type: "uint8" },
    { name: "startTime", type: "uint256" },
    { name: "endTime", type: "uint256" },
    { name: "zoneHash", type: "bytes32" },
    { name: "salt", type: "uint256" },
    { name: "conduitKey", type: "bytes32" },
    { name: "counter", type: "uint256" },
  ],
  OfferItem: [
    { name: "itemType", type: "uint8" },
    { name: "token", type: "address" },
    { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" },
    { name: "endAmount", type: "uint256" },
  ],
  ConsiderationItem: [
    { name: "itemType", type: "uint8" },
    { name: "token", type: "address" },
    { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" },
    { name: "endAmount", type: "uint256" },
    { name: "recipient", type: "address" },
  ],
} as const;

const ERC721 = 2;
const ERC20 = 1;
const FULL_RESTRICTED = 2;

/** The only listing shape Market accepts. */
export function buildListing(p: {
  seller: Address;
  nft: Address;
  tokenId: bigint;
  start: bigint;
  floor: bigint;
  startTime: bigint;
  endTime: bigint;
  counter: bigint;
  salt: bigint;
}): Components {
  return {
    offerer: p.seller,
    zone: MARKET,
    offer: [{ itemType: ERC721, token: p.nft, identifierOrCriteria: p.tokenId, startAmount: 1n, endAmount: 1n }],
    consideration: [
      { itemType: ERC20, token: WETH, identifierOrCriteria: 0n, startAmount: p.start, endAmount: p.floor, recipient: p.seller },
    ],
    orderType: FULL_RESTRICTED,
    startTime: p.startTime,
    endTime: p.endTime,
    zoneHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
    salt: p.salt,
    conduitKey: OS_CONDUIT_KEY,
    counter: p.counter,
  };
}

/** Returns a reason the listing is not one Market will fill, or null. */
export function listingProblem(c: Components): string | null {
  const o = c.offer[0];
  const k = c.consideration[0];
  if (c.zone.toLowerCase() !== MARKET.toLowerCase()) return "wrong zone";
  if (c.orderType !== FULL_RESTRICTED) return "wrong order type";
  if (c.conduitKey.toLowerCase() !== OS_CONDUIT_KEY) return "wrong conduit";
  if (c.offer.length !== 1 || o.itemType !== ERC721 || o.startAmount !== 1n || o.endAmount !== 1n) return "offer must be one ERC721";
  if (c.consideration.length !== 1 || k.itemType !== ERC20 || k.token.toLowerCase() !== WETH.toLowerCase()) return "price must be WETH";
  if (k.recipient.toLowerCase() !== c.offerer.toLowerCase()) return "proceeds must go to the seller";
  if (k.startAmount === 0n) return "start price must be above zero";
  if (k.endAmount > k.startAmount) return "floor above start";
  if (c.endTime <= c.startTime) return "ends before it starts";
  return null;
}

/** Seller amount at `now` (seconds), exactly as Seaport and Market compute it. Null outside [start, end). */
export function priceAt(c: Components, now: bigint): bigint | null {
  if (now < c.startTime || now >= c.endTime) return null;
  const { startAmount: s, endAmount: e } = c.consideration[0];
  if (s === e) return e;
  const duration = c.endTime - c.startTime;
  const elapsed = now - c.startTime;
  const total = s * (duration - elapsed) + e * elapsed;
  return total === 0n ? 0n : (total - 1n) / duration + 1n;
}

/** What a direct buyer sends: seller amount plus the protocol fee. */
export const buyerTotal = (price: bigint) => price + (price * PROTOCOL_FEE_BPS) / BPS;

/** Split of WETH an offer releases to the seller side (seller amount plus surplus). */
export function matchSplit(released: bigint) {
  const executorFee = (released * EXECUTOR_FEE_BPS) / BPS;
  const protocolFee = (released * PROTOCOL_FEE_BPS) / BPS;
  return { executorFee, protocolFee, seller: released - executorFee - protocolFee };
}

/** Smallest released amount that still pays the seller `price` after fees. */
export function minReleasedFor(price: bigint): bigint {
  let r = (price * BPS) / (BPS - EXECUTOR_FEE_BPS - PROTOCOL_FEE_BPS);
  while (matchSplit(r).seller < price) r++;
  return r;
}

export function toParameters(c: Components) {
  return {
    offerer: c.offerer,
    zone: c.zone,
    offer: c.offer,
    consideration: c.consideration,
    orderType: c.orderType,
    startTime: c.startTime,
    endTime: c.endTime,
    zoneHash: c.zoneHash,
    salt: c.salt,
    conduitKey: c.conduitKey,
    totalOriginalConsiderationItems: BigInt(c.consideration.length),
  };
}

export const toAdvancedOrder = (c: Components, signature: Hex) => ({
  parameters: toParameters(c),
  numerator: 1n,
  denominator: 1n,
  signature,
  extraData: "0x" as Hex,
});

// JSON storage keeps bigints as decimal strings.
export const toJson = (c: Components) => JSON.stringify(c, (_, v) => (typeof v === "bigint" ? v.toString() : v));
export function fromJson(s: string): Components {
  const c = JSON.parse(s);
  const items = (xs: any[]) =>
    xs.map((x) => ({ ...x, identifierOrCriteria: BigInt(x.identifierOrCriteria), startAmount: BigInt(x.startAmount), endAmount: BigInt(x.endAmount) }));
  return { ...c, offer: items(c.offer), consideration: items(c.consideration), startTime: BigInt(c.startTime), endTime: BigInt(c.endTime), salt: BigInt(c.salt), counter: BigInt(c.counter) };
}

const structs = [
  "struct OfferItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; }",
  "struct ConsiderationItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; address recipient; }",
  "struct OrderParameters { address offerer; address zone; OfferItem[] offer; ConsiderationItem[] consideration; uint8 orderType; uint256 startTime; uint256 endTime; bytes32 zoneHash; uint256 salt; bytes32 conduitKey; uint256 totalOriginalConsiderationItems; }",
  "struct OrderComponents { address offerer; address zone; OfferItem[] offer; ConsiderationItem[] consideration; uint8 orderType; uint256 startTime; uint256 endTime; bytes32 zoneHash; uint256 salt; bytes32 conduitKey; uint256 counter; }",
  "struct AdvancedOrder { OrderParameters parameters; uint120 numerator; uint120 denominator; bytes signature; bytes extraData; }",
  "struct CriteriaResolver { uint256 orderIndex; uint8 side; uint256 index; uint256 identifier; bytes32[] criteriaProof; }",
  "struct FulfillmentComponent { uint256 orderIndex; uint256 itemIndex; }",
  "struct Fulfillment { FulfillmentComponent[] offerComponents; FulfillmentComponent[] considerationComponents; }",
] as const;

export const seaportAbi = parseAbi([
  ...structs,
  "function getOrderHash(OrderComponents order) view returns (bytes32)",
  "function getOrderStatus(bytes32 orderHash) view returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize)",
  "function getCounter(address offerer) view returns (uint256)",
  "function cancel(OrderComponents[] orders) returns (bool)",
  "event OrderFulfilled(bytes32 orderHash, address indexed offerer, address indexed zone, address recipient, (uint8 itemType, address token, uint256 identifier, uint256 amount)[] offer, (uint8 itemType, address token, uint256 identifier, uint256 amount, address recipient)[] consideration)",
]);

export const marketAbi = parseAbi([
  ...structs,
  "function buy(AdvancedOrder listing) payable",
  "function matchOffer(AdvancedOrder listing, AdvancedOrder offer, CriteriaResolver[] criteriaResolvers, Fulfillment[] fulfillments)",
  "function currentPrice(OrderParameters p) view returns (uint256)",
  "event Sale(address indexed seller, address indexed buyer, address indexed nft, uint256 tokenId, uint256 sellerProceeds, uint256 executorFee, uint256 protocolFee)",
  "error Locked()",
  "error NotListing()",
  "error NotWethOffer()",
  "error InsufficientPayment()",
  "error NftNotDelivered()",
  "error RefundFailed()",
]);

export const erc721Abi = parseAbi([
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner, address operator) view returns (bool)",
  "function setApprovalForAll(address operator, bool approved)",
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function name() view returns (string)",
]);
