// Server-only: chain reads, storage and live listing state shared by API routes and the keeper.
import { DatabaseSync } from "node:sqlite";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { mainnet } from "viem/chains";
import { MARKET, OS_CONDUIT, SEAPORT, erc721Abi, fromJson, priceAt, seaportAbi, type Components } from "./order";

export const rpcUrl = process.env.RPC_URL ?? "https://mainnet.gateway.tenderly.co";
export const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl), batch: { multicall: true } });

let _db: DatabaseSync | undefined;
export function db() {
  if (_db) return _db;
  _db = new DatabaseSync(process.env.DB_PATH ?? "market.db");
  _db.exec(`
    pragma journal_mode = wal;
    pragma busy_timeout = 5000;
    create table if not exists listings (
      hash text primary key,
      seller text not null,
      nft text not null,
      token_id text not null,
      components text not null,
      signature text not null,
      created_at integer not null
    );
    create index if not exists listings_seller on listings(seller);
    create table if not exists sales (
      tx text not null,
      log_index integer not null,
      hash text,
      seller text not null,
      buyer text not null,
      nft text not null,
      token_id text not null,
      seller_proceeds text not null,
      executor_fee text not null,
      protocol_fee text not null,
      block integer not null,
      primary key (tx, log_index)
    );
    create table if not exists attempts (
      tx text primary key,
      listing text not null,
      offer text not null,
      nonce integer not null,
      status text not null,
      detail text,
      created_at integer not null
    );
    create table if not exists meta (key text primary key, value text not null);
  `);
  return _db;
}

export type Row = { hash: Hex; seller: Address; nft: Address; token_id: string; components: string; signature: Hex; created_at: number };

export type State = "scheduled" | "active" | "expired" | "cancelled" | "sold" | "unavailable";

export type Live = {
  hash: Hex;
  components: Components;
  signature: Hex;
  state: State;
  /** Why an otherwise open listing cannot fill right now. */
  reason?: "not owner" | "not approved";
  price: string | null;
  now: string;
};

/** Live state from chain, never from storage alone: Seaport status, ownership, approval, time. */
export async function liveState(rows: Row[]): Promise<Live[]> {
  if (!rows.length) return [];
  const block = await client.getBlock();
  const now = block.timestamp;
  return Promise.all(
    rows.map(async (r) => {
      const c = fromJson(r.components);
      const [status, owner, approved] = await Promise.all([
        client.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getOrderStatus", args: [r.hash], blockNumber: block.number }),
        client.readContract({ address: r.nft, abi: erc721Abi, functionName: "ownerOf", args: [BigInt(r.token_id)], blockNumber: block.number }).catch(() => null),
        client.readContract({ address: r.nft, abi: erc721Abi, functionName: "isApprovedForAll", args: [r.seller, OS_CONDUIT], blockNumber: block.number }),
      ]);
      const [, cancelled, filled] = status;
      let state: State;
      let reason: Live["reason"];
      if (filled > 0n) state = "sold";
      else if (cancelled) state = "cancelled";
      else if (now >= c.endTime) state = "expired";
      else if (owner?.toLowerCase() !== r.seller.toLowerCase()) [state, reason] = ["unavailable", "not owner"];
      else if (!approved) [state, reason] = ["unavailable", "not approved"];
      else state = now < c.startTime ? "scheduled" : "active";
      const price = priceAt(c, now);
      return { hash: r.hash, components: c, signature: r.signature, state, reason, price: price?.toString() ?? null, now: now.toString() };
    }),
  );
}

export const allListings = () => db().prepare("select * from listings order by created_at desc limit 500").all() as Row[];
export const listingsBySeller = (seller: string) =>
  db().prepare("select * from listings where seller = ? order by created_at desc").all(seller.toLowerCase()) as Row[];
export const listing = (hash: string) => db().prepare("select * from listings where hash = ?").get(hash.toLowerCase()) as Row | undefined;

export const meta = (key: string) => (db().prepare("select value from meta where key = ?").get(key) as { value: string } | undefined)?.value;
export const setMeta = (key: string, value: string) =>
  db().prepare("insert into meta(key, value) values(?, ?) on conflict(key) do update set value = excluded.value").run(key, value);

export { MARKET };
