import { concatHex, encodeAbiParameters, parseAbi, zeroAddress, type AbiParameter, type Address, type Hex } from "viem";

// Canonical Ethereum mainnet dependencies. A local fork shares them.
export const SEAPORT: Address = "0x0000000000000068F116a894984e2DB1123eB395";
export const WETH: Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
// OpenSea's Seaport 1.6 conduit; used only to read offers back, never to list.
export const OS_CONDUIT_KEY: Hex = "0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000";
export const OS_CONDUIT: Address = "0x1E0049783F008A0085193E00003D00cd54003c71";
// OpenSea SignedZone: the only zone fillOffer accepts, enabled at deploy.
export const OS_ZONE: Address = "0x000056F7000000EcE9003ca63978907a00FFD100";
export const MARKET = (process.env.NEXT_PUBLIC_MARKET_ADDRESS ?? zeroAddress) as Address;
export const CHAIN_ID = 1;

export const PROTOCOL_FEE_BPS = 20n;
export const EXECUTOR_FEE_BPS = 30n;
export const REFERRAL_FEE_BPS = 10n;
export const BPS = 10_000n;

export const ZERO = zeroAddress;

// uint40 and uint32 map to `number` in viem's ABI types; uint128/uint256 to `bigint`.
export type Price = { start: bigint; end: bigint; startTime: number; endTime: number; strategy: Address; data: Hex };
export type Listing = {
  seller: Address;
  nft: Address;
  tokenId: bigint;
  currency: Address;
  recipient: Address;
  floor: bigint;
  expiry: number;
  price: Price;
};
export type Bid = {
  buyer: Address;
  recipient: Address;
  nft: Address;
  minTokenId: bigint;
  maxTokenId: bigint;
  currency: Address;
  budget: bigint;
  maxPrice: bigint;
  quantity: number;
  expiry: number;
  price: Price;
};
export type Quote = {
  price: bigint;
  royalty: bigint;
  royaltyRecipient: Address;
  protocolFee: bigint;
  executorFee: bigint;
  proceeds: bigint;
};

// Market structs, field order matching contracts/Market.sol exactly (viem encodes by order).
const marketStructs = [
  "struct Price { uint128 start; uint128 end; uint40 startTime; uint40 endTime; address strategy; bytes32 data; }",
  "struct Listing { address seller; address nft; uint256 tokenId; address currency; address recipient; uint128 floor; uint40 expiry; Price price; }",
  "struct Bid { address buyer; address recipient; address nft; uint256 minTokenId; uint256 maxTokenId; address currency; uint128 budget; uint128 maxPrice; uint32 quantity; uint40 expiry; Price price; }",
  "struct Quote { uint256 price; uint256 royalty; address royaltyRecipient; uint256 protocolFee; uint256 executorFee; uint256 proceeds; }",
] as const;

// Seaport structs, needed to pass an OpenSea offer to fillOffer and to decode OpenSea calldata shapes.
const seaportStructs = [
  "struct OfferItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; }",
  "struct ConsiderationItem { uint8 itemType; address token; uint256 identifierOrCriteria; uint256 startAmount; uint256 endAmount; address recipient; }",
  "struct OrderParameters { address offerer; address zone; OfferItem[] offer; ConsiderationItem[] consideration; uint8 orderType; uint256 startTime; uint256 endTime; bytes32 zoneHash; uint256 salt; bytes32 conduitKey; uint256 totalOriginalConsiderationItems; }",
  "struct AdvancedOrder { OrderParameters parameters; uint120 numerator; uint120 denominator; bytes signature; bytes extraData; }",
  "struct CriteriaResolver { uint256 orderIndex; uint8 side; uint256 index; uint256 identifier; bytes32[] criteriaProof; }",
  "struct FulfillmentComponent { uint256 orderIndex; uint256 itemIndex; }",
  "struct Fulfillment { FulfillmentComponent[] offerComponents; FulfillmentComponent[] considerationComponents; }",
] as const;

export const marketAbi = parseAbi([
  ...marketStructs,
  ...seaportStructs,
  "function lastId() view returns (uint256)",
  "function orders(uint256 id) view returns (bytes32 hash, uint128 spent, uint32 fills, bool cancelled)",
  "function owner() view returns (address)",
  "function currencies(address token) view returns (bool)",
  "function zones(address zone) view returns (bool)",
  "function buy(Listing l, uint256 id, uint256 maxPrice, address recipient, address referrer) payable returns (Quote q)",
  "function matchBid(Listing l, uint256 listingId, Bid b, uint256 bidId) returns (Quote q)",
  "function fillOffer(Listing l, uint256 listingId, AdvancedOrder offer, CriteriaResolver[] resolvers) returns (Quote q)",
  "function updateListing(Listing l, uint256 id, Listing next)",
  "function cancelListing(Listing l, uint256 id)",
  "function withdrawListing(Listing l, uint256 id, address to)",
  "function createBid(Bid b) payable returns (uint256 id)",
  "function cancelBid(Bid b, uint256 id)",
  "function withdrawBid(Bid b, uint256 id, address to)",
  "function quoteBuy(Listing l, uint256 id) view returns (Quote q)",
  "function quoteSell(Bid b, uint256 id, uint256 tokenId) view returns (Quote q)",
  "function quoteMatch(Listing l, uint256 listingId, Bid b, uint256 bidId) view returns (Quote q)",
  "function ask(Listing l, uint256 id) view returns (uint256)",
  "function hashListing(Listing l) pure returns (bytes32)",
  "function hashBid(Bid b) pure returns (bytes32)",
  "event Listed(uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, Listing listing)",
  "event ListingUpdated(uint256 indexed id, Listing listing)",
  "event BidCreated(uint256 indexed id, address indexed buyer, address indexed nft, Bid bid)",
  "event Cancelled(uint256 indexed id)",
  "event Withdrawn(uint256 indexed id, address to)",
  "event Sale(uint256 indexed listingId, uint256 indexed bidId, address indexed nft, uint256 tokenId, address seller, address buyer, address currency, Quote quote, address referrer)",
  "error NotActive()",
  "error NotEligible()",
  "error CurrencyDisabled()",
  "error PriceAboveLimit()",
  "error ProceedsBelowMinimum()",
  "error Incompatible()",
  "error InvalidTerms()",
  "error PaymentFailed()",
  "error NftNotDelivered()",
  "error Unauthorized()",
  "error StrategyFailed()",
]);

export const seaportAbi = parseAbi([
  ...seaportStructs,
  "function fulfillAdvancedOrder(AdvancedOrder advancedOrder, CriteriaResolver[] criteriaResolvers, bytes32 fulfillerConduitKey, address recipient) payable returns (bool)",
  "function matchAdvancedOrders(AdvancedOrder[] orders, CriteriaResolver[] criteriaResolvers, Fulfillment[] fulfillments, address recipient) payable returns ((((uint8 itemType, address token, uint256 identifier, uint256 amount, address recipient) item, address offerer, bytes32 conduitKey))[])",
]);

export const erc721Abi = parseAbi([
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function safeTransferFrom(address from, address to, uint256 tokenId, bytes data)",
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function name() view returns (string)",
]);

// Reuse the parsed struct definitions for raw ABI encoding of the deposit payloads.
const abiFn = (name: string) => (marketAbi.find((a) => a.type === "function" && a.name === name) as any).inputs;
const listingParam: AbiParameter = abiFn("hashListing")[0];
const bidParam: AbiParameter = abiFn("hashBid")[0];

/** safeTransferFrom data to open a listing: 0x00 ‖ abi.encode(Listing). */
export const listData = (l: Listing): Hex => concatHex(["0x00", encodeAbiParameters([listingParam], [l])]);

/** safeTransferFrom data to sell into a bid: 0x01 ‖ abi.encode(Bid, bidId, minProceeds, referrer). */
export const sellData = (b: Bid, bidId: bigint, minProceeds: bigint, referrer: Address): Hex =>
  concatHex([
    "0x01",
    encodeAbiParameters([bidParam, { type: "uint256" }, { type: "uint256" }, { type: "address" }], [b, bidId, minProceeds, referrer]),
  ]);

export const fixedPrice = (amount: bigint): Price => ({ start: amount, end: amount, startTime: 0, endTime: 0, strategy: ZERO, data: `0x${"0".repeat(64)}` });

/** Built-in linear price at `now`, exactly as Market computes it. Returns null for an external strategy (read on chain). */
export function builtinPrice(p: Price, now: bigint, isBid: boolean): bigint | null {
  if (p.strategy !== ZERO) return null;
  const startTime = BigInt(p.startTime);
  const endTime = BigInt(p.endTime);
  if (now >= endTime) return p.end;
  if (now <= startTime) return p.start;
  const duration = endTime - startTime;
  const elapsed = now - startTime;
  const total = p.start * (duration - elapsed) + p.end * elapsed;
  return isBid ? total / duration : (total + duration - 1n) / duration;
}

/** A listing's current minimum net proceeds (never below floor). Null for an external strategy. */
export function askAt(l: Listing, now: bigint): bigint | null {
  const a = builtinPrice(l.price, now, false);
  if (a === null) return null;
  return a < l.floor ? l.floor : a;
}

/** A bid's current per-NFT payment, clamped to maxPrice. Null for an external strategy. */
export function bidPriceAt(b: Bid, now: bigint): bigint | null {
  const p = builtinPrice(b.price, now, true);
  if (p === null) return null;
  return p > b.maxPrice ? b.maxPrice : p;
}

/** Preview of what a direct buyer pays for an ask, ignoring royalty (quoteBuy gives the exact figure). */
export const buyerPrice = (ask: bigint): bigint => (ask * BPS + (BPS - PROTOCOL_FEE_BPS - 1n)) / (BPS - PROTOCOL_FEE_BPS);

// JSON storage keeps bigints as decimal strings. quantity stays a bigint for ABI encoding.
const priceFromJson = (p: any): Price => ({ start: BigInt(p.start), end: BigInt(p.end), startTime: Number(p.startTime), endTime: Number(p.endTime), strategy: p.strategy, data: p.data });
export const toJson = (o: unknown) => JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v));

export function listingFromJson(s: string | object): Listing {
  const o = typeof s === "string" ? JSON.parse(s) : s;
  return { seller: o.seller, nft: o.nft, tokenId: BigInt(o.tokenId), currency: o.currency, recipient: o.recipient, floor: BigInt(o.floor), expiry: Number(o.expiry), price: priceFromJson(o.price) };
}

export function bidFromJson(s: string | object): Bid {
  const o = typeof s === "string" ? JSON.parse(s) : s;
  return {
    buyer: o.buyer,
    recipient: o.recipient,
    nft: o.nft,
    minTokenId: BigInt(o.minTokenId),
    maxTokenId: BigInt(o.maxTokenId),
    currency: o.currency,
    budget: BigInt(o.budget),
    maxPrice: BigInt(o.maxPrice),
    quantity: Number(o.quantity),
    expiry: Number(o.expiry),
    price: priceFromJson(o.price),
  };
}
