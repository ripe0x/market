"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, parseEventLogs, type Address } from "viem";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { MARKET, WETH, fixedPrice, marketAbi, type Bid as Terms } from "../../../lib/order";
import { eth, parseEth } from "../../ui/format";
import { Art, State, Wallet, getJson, hydrateBid, type Bid } from "../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../ui/tx";

const DAYS = [1, 3, 7, 14, 30];
const MAX = (1n << 256n) - 1n;
type Scope = "item" | "range" | "collection";

export default function Bids() {
  const { address } = useAccount();
  const list = useQuery({ queryKey: ["bids"], queryFn: async () => (await getJson<any[]>("/api/bids")).map(hydrateBid), refetchInterval: 30_000 });
  return (
    <>
      <div className="head"><h1>Bids</h1><span className="label">{list.data ? `${list.data.length} live` : ""}</span></div>
      {address ? <Create /> : <div className="rows" style={{ marginBottom: 40 }}><div className="row"><span>Connect a wallet to bid.</span><Wallet /></div></div>}

      <p className="label" style={{ margin: "16px 0 12px" }}>Live bids</p>
      {list.isPending && <div className="skeleton" style={{ height: 120 }} />}
      {list.data?.length === 0 && <p className="muted">No bids yet.</p>}
      {!!list.data?.length && (
        <div className="grid">
          {list.data.map((b) => <Card key={b.id} b={b} />)}
        </div>
      )}
    </>
  );
}

function Card({ b }: { b: Bid }) {
  const whole = b.bid.minTokenId === 0n && b.bid.maxTokenId === MAX;
  const scope = whole ? "Collection" : b.bid.minTokenId === b.bid.maxTokenId ? `#${b.bid.minTokenId}` : `#${b.bid.minTokenId}–${b.bid.maxTokenId}`;
  return (
    <Link href={`/bid/${b.id}`} className="card">
      <Art nft={b.nft} size="card" />
      <div className="cap">
        <span>{b.nft?.collection ?? "Collection"}</span>
        <span className="num">{eth(b.price ?? b.bid.maxPrice)} WETH</span>
      </div>
      <div className="small muted">{scope} · {b.fills}/{Number(b.bid.quantity)} filled</div>
    </Link>
  );
}

function Create() {
  const router = useRouter();
  const client = usePublicClient();
  const { address } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const create = useTx();
  const [contract, setContract] = useState("");
  const [scope, setScope] = useState<Scope>("collection");
  const [minId, setMinId] = useState("");
  const [maxId, setMaxId] = useState("");
  const [price, setPrice] = useState("");
  const [qty, setQty] = useState("1");
  const [days, setDays] = useState(7);

  const nft = contract.trim() as Address;
  const maxPrice = parseEth(price);
  const quantity = /^\d+$/.test(qty) ? Number(qty) : null;
  const okIds =
    scope === "collection" ? true : scope === "item" ? /^\d{1,78}$/.test(minId) : /^\d{1,78}$/.test(minId) && /^\d{1,78}$/.test(maxId) && BigInt(minId) <= BigInt(maxId);
  const budget = maxPrice !== null && quantity !== null ? maxPrice * BigInt(quantity) : null;
  const ready = isAddress(nft) && maxPrice !== null && maxPrice > 0n && quantity !== null && quantity > 0 && okIds && !!budget;

  useEffect(() => {
    if (create.state.s !== "done" || !create.state.hash) return;
    const hash = create.state.hash;
    client!.getTransactionReceipt({ hash }).then((r) => {
      const ev = parseEventLogs({ abi: marketAbi, eventName: "BidCreated", logs: r.logs })[0];
      if (ev) router.push(`/bid/${(ev.args as any).id}`);
    });
  }, [create.state]); // eslint-disable-line react-hooks/exhaustive-deps

  function bid(): Terms {
    const [min, max] = scope === "collection" ? [0n, MAX] : scope === "item" ? [BigInt(minId), BigInt(minId)] : [BigInt(minId), BigInt(maxId)];
    return { buyer: "0x0000000000000000000000000000000000000000", recipient: address!, nft, minTokenId: min, maxTokenId: max, currency: WETH, budget: budget!, maxPrice: maxPrice!, quantity: quantity!, expiry: Math.floor(Date.now() / 1000) + days * 86400, price: fixedPrice(maxPrice!) };
  }

  return (
    <section style={{ border: "1px solid var(--rule)", padding: 20, marginBottom: 40 }}>
      <p className="label" style={{ marginBottom: 12 }}>New bid</p>
      <div className="field">
        <label className="label" htmlFor="c">Collection</label>
        <input id="c" placeholder="0x…" value={contract} onChange={(e) => setContract(e.target.value)} autoComplete="off" spellCheck={false} style={{ fontSize: 16 }} />
      </div>
      <div className="field">
        <span className="label">Scope</span>
        <div className="choices">
          {(["collection", "item", "range"] as Scope[]).map((s) => (<button key={s} aria-pressed={scope === s} onClick={() => setScope(s)} style={{ textTransform: "capitalize" }}>{s}</button>))}
        </div>
      </div>
      {scope === "item" && (
        <div className="field"><label className="label" htmlFor="tid">Token id</label><input id="tid" inputMode="numeric" value={minId} onChange={(e) => setMinId(e.target.value)} autoComplete="off" /></div>
      )}
      {scope === "range" && (
        <div className="split" style={{ gap: 12 }}>
          <div className="field"><label className="label" htmlFor="min">From id</label><input id="min" inputMode="numeric" value={minId} onChange={(e) => setMinId(e.target.value)} autoComplete="off" /></div>
          <div className="field"><label className="label" htmlFor="max">To id</label><input id="max" inputMode="numeric" value={maxId} onChange={(e) => setMaxId(e.target.value)} autoComplete="off" /></div>
        </div>
      )}
      <div className="split" style={{ gap: 12 }}>
        <div className="field"><label className="label" htmlFor="mp">Max per NFT (WETH)</label><input id="mp" inputMode="decimal" placeholder="0.00" value={price} onChange={(e) => setPrice(e.target.value)} autoComplete="off" /></div>
        <div className="field"><label className="label" htmlFor="qty">Quantity</label><input id="qty" inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)} autoComplete="off" /></div>
      </div>
      <div className="field">
        <span className="label">Expires in</span>
        <div className="choices">{DAYS.map((d) => (<button key={d} aria-pressed={days === d} onClick={() => setDays(d)}>{d}d</button>))}</div>
      </div>
      <div className="rows">
        <div className="row"><span className="muted">Budget (deposited now)</span><span className="num">{budget !== null ? `${eth(budget)} ETH` : "-"}</span></div>
      </div>
      <p className="small muted" style={{ margin: "12px 0" }}>Your ETH is wrapped to WETH and held in the Market contract. Withdraw the unspent budget any time.</p>
      <TxButton
        state={create.state}
        pendingLabel="Funding"
        disabled={!ready}
        onClick={() => create.run(() => writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "createBid", args: [bid()], value: budget! }))}
      >
        Create bid
      </TxButton>
      <TxStatus state={create.state} />
    </section>
  );
}
