// Keeper: syncs sales from chain and sells active listings into OpenSea offers.
// Restart safe: chain is the source of truth; storage only records what was seen
// and the single in-flight transaction. Never holds an NFT or user funds.
import { readFileSync } from "node:fs";
import { createWalletClient, http, parseEventLogs, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { MARKET, marketAbi, matchSplit, minReleasedFor, seaportAbi } from "../lib/order";
import * as os from "../lib/opensea";
import { allListings, client, db, liveState, meta, rpcUrl, setMeta, type Live } from "../lib/server";
import { matchArgs, parseBid, released, type Bid } from "./match";

const INTERVAL_MS = Number(process.env.KEEPER_INTERVAL_MS ?? 15_000);
const CONFIRMATIONS = BigInt(process.env.CONFIRMATIONS ?? 3);
const PROFIT_MARGIN = Number(process.env.PROFIT_MARGIN ?? 1.25); // executor fee must cover gas cost x this
const STUCK_SECONDS = Number(process.env.STUCK_SECONDS ?? 180);
const DEV_OFFERS_FILE = process.env.DEV_OFFERS_FILE; // local fork only: signed offers instead of OpenSea

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), event, ...data }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

const key = process.env.KEEPER_PRIVATE_KEY as Hex | undefined;
const account = key ? privateKeyToAccount(key) : undefined;
// Optional private submission endpoint (for example Flashbots Protect) against front-running.
const wallet = account && createWalletClient({ account, chain: mainnet, transport: http(process.env.SUBMIT_RPC_URL ?? rpcUrl) });
export const matching = Boolean(wallet && (os.apiKey || DEV_OFFERS_FILE));

/** Market Sale events up to head - CONFIRMATIONS, joined to Seaport's order hash in the same receipt. */
export async function syncSales() {
  const head = await client.getBlockNumber();
  const to = head - CONFIRMATIONS;
  let from = BigInt(meta("synced_block") ?? process.env.START_BLOCK ?? to - 1000n) + 1n;
  while (from <= to) {
    const end = from + 1999n < to ? from + 1999n : to;
    const logs = await client.getContractEvents({ address: MARKET, abi: marketAbi, eventName: "Sale", fromBlock: from, toBlock: end });
    for (const l of logs) {
      const receipt = await client.getTransactionReceipt({ hash: l.transactionHash });
      const filled = parseEventLogs({ abi: seaportAbi, eventName: "OrderFulfilled", logs: receipt.logs }).find(
        (e) => e.args.zone.toLowerCase() === MARKET.toLowerCase(),
      );
      const a = l.args;
      db()
        .prepare("insert or ignore into sales values (?,?,?,?,?,?,?,?,?,?,?)")
        .run(
          l.transactionHash,
          l.logIndex,
          filled?.args.orderHash.toLowerCase() ?? null,
          a.seller!.toLowerCase(),
          a.buyer!.toLowerCase(),
          a.nft!.toLowerCase(),
          a.tokenId!.toString(),
          a.sellerProceeds!.toString(),
          a.executorFee!.toString(),
          a.protocolFee!.toString(),
          Number(l.blockNumber),
        );
      log("sale", { tx: l.transactionHash, hash: filled?.args.orderHash, sellerProceeds: a.sellerProceeds, executorFee: a.executorFee });
    }
    setMeta("synced_block", end.toString());
    from = end + 1n;
  }
}

type Candidate = { hash: Hex; bid: () => Promise<Bid>; headline: bigint };

const slugs = new Map<string, string>();
async function candidates(l: Live, now: bigint): Promise<Candidate[]> {
  const nft = l.components.offer[0].token;
  const tokenId = l.components.offer[0].identifierOrCriteria.toString();
  if (DEV_OFFERS_FILE) {
    const offers = JSON.parse(readFileSync(DEV_OFFERS_FILE, "utf8")) as any[];
    return offers
      .filter((o) => o.nft.toLowerCase() === nft.toLowerCase() && o.tokenId === tokenId)
      .map((o) => ({ hash: o.hash, bid: async () => parseBid(o.order), headline: released(parseBid(o.order), now) ?? 0n }));
  }
  if (!slugs.has(nft)) slugs.set(nft, await os.collectionSlug(nft));
  const best = await os.bestOffer(slugs.get(nft)!, tokenId);
  if (!best || !os.supported(best, nft)) return [];
  // Headline estimate from unsigned params; re-derived from signed data before use.
  const headline = released(parseBid({ ...best.protocol_data, signature: "0x", extraData: "0x" }), now) ?? 0n;
  return [
    {
      hash: best.order_hash,
      headline,
      bid: async () => parseBid((await os.fulfillment(best, MARKET, nft, tokenId)).order),
    },
  ];
}

/** Try to sell one listing. Returns the submitted tx hash, or null. */
export async function tryMatch(l: Live, offers = candidates): Promise<Hex | null> {
  const block = await client.getBlock();
  const now = block.timestamp;
  const price = BigInt(l.price!);
  const need = minReleasedFor(price);
  for (const c of (await offers(l, now)).sort((a, b) => (b.headline > a.headline ? 1 : -1))) {
    if (c.headline < need) {
      log("skip", { listing: l.hash, offer: c.hash, reason: "below minimum", released: c.headline, need });
      continue;
    }
    const bid = await c.bid();
    const r = released(bid, now);
    if (r === null || r < need) {
      log("skip", { listing: l.hash, offer: c.hash, reason: "signed bid below minimum", released: r, need });
      continue;
    }
    const args = matchArgs(l.components, l.signature, bid);
    try {
      const gas = await client.estimateContractGas({ address: MARKET, abi: marketAbi, functionName: "matchOffer", args, account: account! });
      const fees = await client.estimateFeesPerGas();
      // Expected cost at today's base fee; maxFeePerGas only caps it.
      const cost = gas * ((block.baseFeePerGas ?? 0n) + fees.maxPriorityFeePerGas);
      const { executorFee } = matchSplit(r);
      if (Number(executorFee) < Number(cost) * PROFIT_MARGIN) {
        log("skip", { listing: l.hash, offer: c.hash, reason: "unprofitable", executorFee, gasCost: cost, gas });
        continue;
      }
      const nonce = await client.getTransactionCount({ address: account!.address, blockTag: "pending" });
      const tx = await wallet!.writeContract({
        address: MARKET,
        abi: marketAbi,
        functionName: "matchOffer",
        args,
        gas: (gas * 12n) / 10n,
        nonce,
        maxFeePerGas: fees.maxFeePerGas,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      });
      db().prepare("insert into attempts values (?,?,?,?,?,?,?)").run(tx, l.hash, c.hash, nonce, "pending", null, Date.now());
      log("submitted", { tx, listing: l.hash, offer: c.hash, released: r, price, executorFee, gas });
      return tx;
    } catch (e: any) {
      log("simulation_failed", { listing: l.hash, offer: c.hash, error: e?.shortMessage ?? String(e) });
    }
  }
  return null;
}

/** Resolve the in-flight attempt. A stuck one is replaced by a zero-value self transfer at the same nonce. */
async function settlePending(): Promise<boolean> {
  const p = db().prepare("select * from attempts where status = 'pending'").get() as any;
  if (!p) return false;
  const receipt = await client.getTransactionReceipt({ hash: p.tx }).catch(() => null);
  if (receipt) {
    const status = receipt.status === "success" ? "confirmed" : "reverted";
    db().prepare("update attempts set status = ?, detail = ? where tx = ?").run(status, `gas ${receipt.gasUsed}`, p.tx);
    log(status, { tx: p.tx, listing: p.listing, gasUsed: receipt.gasUsed });
    return false;
  }
  const mined = await client.getTransactionCount({ address: account!.address, blockTag: "latest" });
  if (mined > p.nonce) {
    db().prepare("update attempts set status = 'replaced' where tx = ?").run(p.tx);
    log("replaced", { tx: p.tx });
    return false;
  }
  if (Date.now() - p.created_at > STUCK_SECONDS * 1000) {
    const fees = await client.estimateFeesPerGas();
    const cancel = await wallet!.sendTransaction({
      to: account!.address,
      value: 0n,
      nonce: p.nonce,
      maxFeePerGas: fees.maxFeePerGas * 2n,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas * 2n + 1n,
    });
    db().prepare("update attempts set created_at = ?, detail = ? where tx = ?").run(Date.now(), `cancel ${cancel}`, p.tx);
    log("cancel_sent", { tx: p.tx, cancel });
  }
  return true;
}

export async function round() {
  setMeta("keeper_seen", Date.now().toString());
  setMeta("matching", matching ? "on" : "off");
  await syncSales();
  if (!matching) return;
  if (await settlePending()) return;
  const live = await liveState(allListings());
  for (const l of live.filter((x) => x.state === "active")) {
    if (await tryMatch(l)) return; // one in-flight transaction at a time
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  log("start", { market: MARKET, keeper: account?.address, matching, source: DEV_OFFERS_FILE ? "dev file" : os.apiKey ? "opensea" : "none" });
  if (!matching) log("matching_off", { reason: !wallet ? "no KEEPER_PRIVATE_KEY" : "no OPENSEA_API_KEY" });
  let stop = false;
  for (const s of ["SIGINT", "SIGTERM"]) process.on(s, () => ((stop = true), log("stopping")));
  while (!stop) {
    await round().catch((e) => log("round_failed", { error: e?.shortMessage ?? String(e) }));
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}
