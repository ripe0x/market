// Server-only: chain reads, the SQLite index, and the event sync shared by the API
// routes and the keeper. The chain is the source of truth; the index is a cache of
// Market events and is rebuilt from START_BLOCK. Sync is idempotent and restart safe.
import { DatabaseSync } from "node:sqlite";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { mainnet } from "viem/chains";
import { MARKET, askAt, bidFromJson, bidPriceAt, listingFromJson, marketAbi, toJson, type Bid, type Listing } from "./order";

export const rpcUrl = process.env.RPC_URL ?? "https://mainnet.gateway.tenderly.co";
// cacheTime 0: the indexer and keeper must see the latest block and receipts
// immediately, never viem's default block-number cache.
export const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl), batch: { multicall: true }, cacheTime: 0 });

const CONFIRMATIONS = BigInt(process.env.CONFIRMATIONS ?? 3);
const START_BLOCK = process.env.START_BLOCK ? BigInt(process.env.START_BLOCK) : undefined;

let _db: DatabaseSync | undefined;
export function db() {
  if (_db) return _db;
  _db = new DatabaseSync(process.env.DB_PATH ?? "market.db");
  _db.exec(`
    pragma journal_mode = wal;
    pragma busy_timeout = 5000;
    create table if not exists listings (
      id integer primary key,
      seller text not null,
      nft text not null,
      token_id text not null,
      terms text not null,
      state text not null,
      block integer not null
    );
    create index if not exists listings_seller on listings(seller);
    create table if not exists bids (
      id integer primary key,
      buyer text not null,
      nft text not null,
      min_token text not null,
      max_token text not null,
      terms text not null,
      state text not null,
      block integer not null
    );
    create index if not exists bids_buyer on bids(buyer);
    create index if not exists bids_nft on bids(nft);
    create table if not exists sales (
      tx text not null,
      log_index integer not null,
      listing_id integer,
      bid_id integer,
      nft text not null,
      token_id text not null,
      seller text not null,
      buyer text not null,
      currency text not null,
      price text not null,
      royalty text not null,
      protocol_fee text not null,
      executor_fee text not null,
      proceeds text not null,
      referrer text not null,
      block integer not null,
      primary key (tx, log_index)
    );
    create index if not exists sales_seller on sales(seller);
    create index if not exists sales_buyer on sales(buyer);
    create index if not exists sales_token on sales(nft, token_id);
    create table if not exists attempts (
      tx text primary key,
      kind text not null,
      ref text not null,
      nonce integer not null,
      status text not null,
      detail text,
      created_at integer not null
    );
    create table if not exists meta (key text primary key, value text not null);
  `);
  return _db;
}

export const meta = (key: string) => (db().prepare("select value from meta where key = ?").get(key) as { value: string } | undefined)?.value;
export const setMeta = (key: string, value: string) =>
  db().prepare("insert into meta(key, value) values(?, ?) on conflict(key) do update set value = excluded.value").run(key, value);

const EVENTS = ["Listed", "ListingUpdated", "BidCreated", "Cancelled", "Withdrawn", "Sale"] as const;

let syncing: Promise<void> | null = null;
/** Index new Market events up to head - CONFIRMATIONS. Shared by API routes and the keeper. */
export function sync(): Promise<void> {
  return (syncing ??= run().finally(() => (syncing = null)));
}

async function run() {
  const head = await client.getBlockNumber();
  const to = head - CONFIRMATIONS;
  let from = BigInt(meta("synced_block") ?? (START_BLOCK !== undefined ? START_BLOCK - 1n : to - 1n)) + 1n;
  while (from <= to) {
    const end = from + 1999n < to ? from + 1999n : to;
    const logs = (
      await Promise.all(EVENTS.map((eventName) => client.getContractEvents({ address: MARKET, abi: marketAbi, eventName, fromBlock: from, toBlock: end })))
    ).flat();
    logs.sort((a, b) => (a.blockNumber! === b.blockNumber! ? a.logIndex! - b.logIndex! : Number(a.blockNumber! - b.blockNumber!)));
    for (const l of logs) apply(l.eventName, l.args as any, l);
    setMeta("synced_block", end.toString());
    from = end + 1n;
  }
}

function apply(name: string, a: any, l: { blockNumber: bigint | null; transactionHash: Hex; logIndex: number }) {
  const block = Number(l.blockNumber ?? 0n);
  switch (name) {
    case "Listed":
      db()
        .prepare("insert or replace into listings values (?,?,?,?,?,?,?)")
        .run(Number(a.id), a.seller.toLowerCase(), a.nft.toLowerCase(), a.tokenId.toString(), toJson(a.listing), "open", block);
      break;
    case "ListingUpdated":
      db().prepare("update listings set terms = ? where id = ? and state = 'open'").run(toJson(a.listing), Number(a.id));
      break;
    case "BidCreated": {
      const b: Bid = a.bid;
      db()
        .prepare("insert or replace into bids values (?,?,?,?,?,?,?,?)")
        .run(Number(a.id), a.buyer.toLowerCase(), a.nft.toLowerCase(), b.minTokenId.toString(), b.maxTokenId.toString(), toJson(b), "open", block);
      break;
    }
    case "Cancelled":
      db().prepare("update listings set state = 'cancelled' where id = ? and state = 'open'").run(Number(a.id));
      db().prepare("update bids set state = 'cancelled' where id = ? and state = 'open'").run(Number(a.id));
      break;
    case "Withdrawn":
      db().prepare("update listings set state = 'withdrawn' where id = ? and state != 'sold'").run(Number(a.id));
      db().prepare("update bids set state = 'withdrawn' where id = ?").run(Number(a.id));
      break;
    case "Sale": {
      const q = a.quote;
      db()
        .prepare("insert or ignore into sales values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        .run(
          l.transactionHash,
          l.logIndex,
          Number(a.listingId) || null,
          Number(a.bidId) || null,
          a.nft.toLowerCase(),
          a.tokenId.toString(),
          a.seller.toLowerCase(),
          a.buyer.toLowerCase(),
          a.currency.toLowerCase(),
          q.price.toString(),
          q.royalty.toString(),
          q.protocolFee.toString(),
          q.executorFee.toString(),
          q.proceeds.toString(),
          (a.referrer as string).toLowerCase(),
          block,
        );
      if (Number(a.listingId)) db().prepare("update listings set state = 'sold' where id = ? and state = 'open'").run(Number(a.listingId));
      break;
    }
  }
}

// ---------------------------------------------------------------- read model

export type ListingRow = { id: number; seller: Address; nft: Address; token_id: string; terms: string; state: string; block: number };
export type BidRow = { id: number; buyer: Address; nft: Address; min_token: string; max_token: string; terms: string; state: string; block: number };
export type SaleRow = {
  tx: string;
  log_index: number;
  listing_id: number | null;
  bid_id: number | null;
  nft: string;
  token_id: string;
  seller: string;
  buyer: string;
  currency: string;
  price: string;
  royalty: string;
  protocol_fee: string;
  executor_fee: string;
  proceeds: string;
  referrer: string;
  block: number;
};

export type ListingState = "active" | "expired" | "cancelled" | "sold" | "withdrawn";
export type BidState = "active" | "expired" | "filled" | "cancelled" | "withdrawn";

export type LiveListing = { id: number; listing: Listing; state: ListingState; ask: string | null; now: string };
export type LiveBid = { id: number; bid: Bid; state: BidState; price: string | null; spent: string; fills: number; now: string };

function listingState(row: ListingRow, l: Listing, now: bigint): ListingState {
  if (row.state === "sold" || row.state === "cancelled" || row.state === "withdrawn") return row.state;
  return now >= BigInt(l.expiry) ? "expired" : "active";
}

function bidProgress(id: number): { spent: bigint; fills: number } {
  const rows = db().prepare("select price from sales where bid_id = ?").all(id) as { price: string }[];
  return { spent: rows.reduce((s, r) => s + BigInt(r.price), 0n), fills: rows.length };
}

function bidState(row: BidRow, b: Bid, now: bigint, spent: bigint, fills: number): BidState {
  if (row.state === "cancelled" || row.state === "withdrawn") return row.state;
  if (fills >= b.quantity || spent >= b.budget) return "filled";
  return now >= BigInt(b.expiry) ? "expired" : "active";
}

export async function liveListings(rows: ListingRow[], now?: bigint): Promise<LiveListing[]> {
  if (!rows.length) return [];
  const t = now ?? (await client.getBlock()).timestamp;
  return rows.map((r) => {
    const listing = listingFromJson(r.terms);
    const ask = askAt(listing, t);
    return { id: r.id, listing, state: listingState(r, listing, t), ask: ask?.toString() ?? null, now: t.toString() };
  });
}

export async function liveBids(rows: BidRow[], now?: bigint): Promise<LiveBid[]> {
  if (!rows.length) return [];
  const t = now ?? (await client.getBlock()).timestamp;
  return rows.map((r) => {
    const bid = bidFromJson(r.terms);
    const { spent, fills } = bidProgress(r.id);
    const price = bidPriceAt(bid, t);
    return { id: r.id, bid, state: bidState(r, bid, t, spent, fills), price: price?.toString() ?? null, spent: spent.toString(), fills, now: t.toString() };
  });
}

export const allListingRows = () => db().prepare("select * from listings order by block desc limit 500").all() as ListingRow[];
export const listingRowsBySeller = (seller: string) => db().prepare("select * from listings where seller = ? order by block desc").all(seller.toLowerCase()) as ListingRow[];
export const listingRow = (id: number) => db().prepare("select * from listings where id = ?").get(id) as ListingRow | undefined;

export const allBidRows = () => db().prepare("select * from bids order by block desc limit 500").all() as BidRow[];
export const bidRowsByBuyer = (buyer: string) => db().prepare("select * from bids where buyer = ? order by block desc").all(buyer.toLowerCase()) as BidRow[];
export const bidRowsByCollection = (nft: string) => db().prepare("select * from bids where nft = ? order by block desc").all(nft.toLowerCase()) as BidRow[];
export const bidRow = (id: number) => db().prepare("select * from bids where id = ?").get(id) as BidRow | undefined;

export { MARKET };
