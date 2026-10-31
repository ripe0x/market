// Keeper: indexes Market events, then settles live listings two ways:
//   (a) native  — matchBid into the best live Market bid that clears the ask
//   (b) OpenSea — fillOffer with the best signed OpenSea offer for the NFT
// It submits only when the executor fee covers gas x PROFIT_MARGIN, one tx at a
// time, and never holds an NFT or user funds. Restart safe: the chain is the truth.
import { readFileSync } from "node:fs";
import { createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { MARKET, WETH, marketAbi, type Bid } from "../lib/order";
import * as os from "../lib/opensea";
import {
  allListingRows,
  bidRowsByCollection,
  client,
  db,
  liveBids,
  liveListings,
  meta,
  rpcUrl,
  setMeta,
  sync,
  type LiveListing,
} from "../lib/server";
import { normalizeFulfillment, parseOrder, released, replacementFees, type Order, type Resolver } from "./match";

const INTERVAL_MS = Number(process.env.KEEPER_INTERVAL_MS ?? 15_000);
const PROFIT_MARGIN = Number(process.env.PROFIT_MARGIN ?? 1.25); // executor fee must cover gas cost x this
const STUCK_SECONDS = Number(process.env.STUCK_SECONDS ?? 180);
const DEV_OFFERS_FILE = process.env.DEV_OFFERS_FILE; // local fork only: raw OpenSea fulfillment shapes instead of the API

const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), event, ...data }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

const key = process.env.KEEPER_PRIVATE_KEY as Hex | undefined;
const local = /127\.0\.0\.1|localhost/.test(rpcUrl);
// Local fork only: an anvil-unlocked address signs through the node, so no key is handled.
const unlocked = local ? (process.env.KEEPER_UNLOCKED_ADDRESS as Hex | undefined) : undefined;
const account = key ? privateKeyToAccount(key) : unlocked ? { address: unlocked, type: "json-rpc" as const } : undefined;
// matchBid and fillOffer calldata works for any caller, so public-mempool submission
// hands the executor fee to whoever copies it. Off a local fork, a private endpoint
// (e.g. Flashbots Protect) is required.
const submitUrl = process.env.SUBMIT_RPC_URL ?? (local ? rpcUrl : undefined);
const wallet = account && submitUrl ? createWalletClient({ account, chain: mainnet, transport: http(submitUrl) }) : undefined;
const offersEnabled = Boolean(os.apiKey || DEV_OFFERS_FILE);
export const matching = Boolean(wallet);

type Fees = { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint; baseFeePerGas: bigint };

async function currentFees(): Promise<Fees> {
  const [block, fees] = await Promise.all([client.getBlock(), client.estimateFeesPerGas()]);
  return { ...fees, baseFeePerGas: block.baseFeePerGas ?? 0n };
}

/** Submit a call and record it as the single in-flight attempt. */
async function submit(kind: string, ref: string, call: any, fees: Fees, gas: bigint): Promise<Hex> {
  const nonce = await client.getTransactionCount({ address: account!.address, blockTag: "pending" });
  const tx = await wallet!.writeContract({ ...call, account, gas: (gas * 12n) / 10n, nonce, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
  const detail = JSON.stringify({ maxFee: fees.maxFeePerGas.toString(), tip: fees.maxPriorityFeePerGas.toString() });
  db().prepare("insert into attempts values (?,?,?,?,?,?,?)").run(tx, kind, ref, nonce, "pending", detail, Date.now());
  return tx;
}

const profitable = (executorFee: bigint, gas: bigint, fees: Fees) => {
  const cost = gas * (fees.baseFeePerGas + fees.maxPriorityFeePerGas);
  return { ok: Number(executorFee) >= Number(cost) * PROFIT_MARGIN, cost };
};

/** Best live Market bid that clears the listing's ask, sold via matchBid. */
async function tryMatchBid(l: LiveListing): Promise<Hex | null> {
  const listing = l.listing;
  const bids = (await liveBids(bidRowsByCollection(listing.nft)))
    .filter((b) => b.state === "active" && b.bid.currency.toLowerCase() === listing.currency.toLowerCase() && listing.tokenId >= b.bid.minTokenId && listing.tokenId <= b.bid.maxTokenId);

  let best: { id: number; bid: Bid; executorFee: bigint } | null = null;
  for (const b of bids) {
    try {
      const q = await client.readContract({ address: MARKET, abi: marketAbi, functionName: "quoteMatch", args: [listing, BigInt(l.id), b.bid, BigInt(b.id)] });
      if (!best || q.executorFee > best.executorFee) best = { id: b.id, bid: b.bid, executorFee: q.executorFee };
    } catch {
      // below ask, ineligible or not live; skip
    }
  }
  if (!best) return null;

  const call = { address: MARKET, abi: marketAbi, functionName: "matchBid", args: [listing, BigInt(l.id), best.bid, BigInt(best.id)] } as const;
  try {
    const fees = await currentFees();
    const gas = await client.estimateContractGas({ ...call, account: account! });
    const { ok, cost } = profitable(best.executorFee, gas, fees);
    if (!ok) {
      log("skip", { route: "match", listing: l.id, bid: best.id, reason: "unprofitable", executorFee: best.executorFee, gasCost: cost });
      return null;
    }
    const tx = await submit("match", `${l.id}:${best.id}`, call, fees, gas);
    log("submitted", { route: "match", tx, listing: l.id, bid: best.id, executorFee: best.executorFee, gas });
    return tx;
  } catch (e: any) {
    log("simulation_failed", { route: "match", listing: l.id, bid: best.id, error: e?.shortMessage ?? String(e) });
    return null;
  }
}

type Candidate = { ref: string; order: Order; resolvers: Resolver[] };

const slugs = new Map<string, string>();
/** OpenSea offers for this listing's NFT, as normalized fillOffer arguments. */
async function offerCandidates(l: LiveListing): Promise<Candidate[]> {
  const nft = l.listing.nft;
  const tokenId = l.listing.tokenId.toString();
  if (DEV_OFFERS_FILE) {
    const entries = JSON.parse(readFileSync(DEV_OFFERS_FILE, "utf8")) as { nft: string; tokenId: string; input: any }[];
    return entries
      .filter((e) => e.nft.toLowerCase() === nft.toLowerCase() && e.tokenId === tokenId)
      .map((e) => ({ ref: `dev`, ...normalizeFulfillment(e.input, MARKET) }));
  }
  if (!os.apiKey) return [];
  if (!slugs.has(nft)) slugs.set(nft, await os.collectionSlug(nft));
  const best = await os.bestOffer(slugs.get(nft)!, tokenId);
  if (!best || !os.supported(best, nft)) return [];
  const input = await os.fulfillmentData(best, MARKET, nft, tokenId);
  return [{ ref: best.order_hash, ...normalizeFulfillment(input, MARKET) }];
}

/** Sell the listing into the best OpenSea offer via fillOffer. */
async function tryFillOffer(l: LiveListing): Promise<Hex | null> {
  if (!offersEnabled || l.listing.currency.toLowerCase() !== WETH.toLowerCase()) return null;
  const now = (await client.getBlock()).timestamp;
  const candidates = await offerCandidates(l);
  // Prefer the offer that releases the most WETH.
  candidates.sort((a, b) => Number((released(b.order, now) ?? 0n) - (released(a.order, now) ?? 0n)));
  for (const c of candidates) {
    const call = { address: MARKET, abi: marketAbi, functionName: "fillOffer", args: [l.listing, BigInt(l.id), c.order, c.resolvers] } as const;
    try {
      const { result: q } = await client.simulateContract({ ...call, account: account! });
      const fees = await currentFees();
      const gas = await client.estimateContractGas({ ...call, account: account! });
      const { ok, cost } = profitable(q.executorFee, gas, fees);
      if (!ok) {
        log("skip", { route: "offer", listing: l.id, offer: c.ref, reason: "unprofitable", executorFee: q.executorFee, gasCost: cost });
        continue;
      }
      const tx = await submit("fill", `${l.id}:${c.ref}`, call, fees, gas);
      log("submitted", { route: "offer", tx, listing: l.id, offer: c.ref, price: q.price, executorFee: q.executorFee, gas });
      return tx;
    } catch (e: any) {
      log("simulation_failed", { route: "offer", listing: l.id, offer: c.ref, error: e?.shortMessage ?? String(e) });
    }
  }
  return null;
}

/** Resolve the in-flight attempt. A stuck one is replaced by a zero-value self transfer at the same nonce (D022). */
async function settlePending(): Promise<boolean> {
  const p = db().prepare("select * from attempts where status = 'pending'").get() as any;
  if (!p) return false;
  const receipt = await client.getTransactionReceipt({ hash: p.tx }).catch(() => null);
  if (receipt) {
    const status = receipt.status === "success" ? "confirmed" : "reverted";
    db().prepare("update attempts set status = ? where tx = ?").run(status, p.tx);
    log(status, { tx: p.tx, ref: p.ref, gasUsed: receipt.gasUsed });
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
    const { maxFee, tip } = replacementFees(fees, JSON.parse(p.detail ?? "{}"));
    const cancel = await wallet!.sendTransaction({ account, to: account!.address, value: 0n, nonce: p.nonce, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip });
    db().prepare("update attempts set created_at = ?, detail = ? where tx = ?").run(Date.now(), JSON.stringify({ maxFee: maxFee.toString(), tip: tip.toString(), cancel }), p.tx);
    log("cancel_sent", { tx: p.tx, cancel, maxFee, tip });
  }
  return true;
}

export async function round() {
  setMeta("keeper_seen", Date.now().toString());
  setMeta("matching", matching ? "on" : "off");
  await sync();
  if (!matching) return;
  if (await settlePending()) return;
  const listings = (await liveListings(allListingRows())).filter((l) => l.state === "active");
  for (const l of listings) {
    if (await tryMatchBid(l)) return; // one in-flight transaction at a time
    if (await tryFillOffer(l)) return;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  log("start", { market: MARKET, keeper: account?.address, matching, offers: offersEnabled ? (DEV_OFFERS_FILE ? "dev file" : "opensea") : "off" });
  if (!matching) log("matching_off", { reason: !account ? "no KEEPER_PRIVATE_KEY" : "no SUBMIT_RPC_URL (private relay required off a local fork)" });
  let stop = false;
  for (const s of ["SIGINT", "SIGTERM"]) process.on(s, () => ((stop = true), log("stopping")));
  while (!stop) {
    await round().catch((e) => log("round_failed", { error: e?.shortMessage ?? String(e) }));
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}
