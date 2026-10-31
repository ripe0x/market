"use client";
import Link from "next/link";
import { use, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import { MARKET, erc721Abi, marketAbi, sellData, type Bid as Terms } from "../../../../lib/order";
import { date, duration, eth, explorer, short } from "../../../ui/format";
import { Art, State, Wallet, getJson, hydrateBid, type Bid, type Nft } from "../../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../../ui/tx";

const MAX = (1n << 256n) - 1n;
type Fill = { tx: string; token_id: string; seller: string; proceeds: string };

export default function BidPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const q = useQuery({
    queryKey: ["bid", id],
    queryFn: async () => {
      const b = await getJson<any>(`/api/bids/${id}`);
      return { ...hydrateBid(b), sales: b.sales as Fill[] };
    },
    refetchInterval: (query) => (query.state.data && ["cancelled", "withdrawn"].includes(query.state.data.state) ? false : 8_000),
  });
  const b = q.data;
  if (q.isError) return <div className="empty"><p>Bid not found.</p><Link className="btn small" href="/bids">Bids</Link></div>;
  if (!b) return <div className="split" aria-busy><div className="art skeleton" /><div className="rows"><div className="row skeleton" style={{ height: 120 }} /></div></div>;

  const t = b.bid;
  const whole = t.minTokenId === 0n && t.maxTokenId === MAX;
  const scope = whole ? "Whole collection" : t.minTokenId === t.maxTokenId ? `Token #${t.minTokenId}` : `Tokens #${t.minTokenId}–${t.maxTokenId}`;
  const now = BigInt(b.now);
  const remaining = BigInt(t.budget) - BigInt(b.spent);
  return (
    <div className="split">
      <Art nft={b.nft} />
      <div>
        <p className="label">{b.nft?.collection}</p>
        <h2 style={{ margin: "6px 0 20px" }}>{scope}</h2>
        <State state={b.state} />

        <div style={{ margin: "28px 0 8px" }}>
          <p className="label">Pays per NFT</p>
          <p className="big num">{eth(b.price ?? t.maxPrice)}</p>
          <p className="muted small">WETH</p>
        </div>

        <div className="rows">
          <div className="row"><span className="muted">Filled</span><span className="num">{b.fills}/{Number(t.quantity)}</span></div>
          <div className="row"><span className="muted">Budget left</span><span className="num">{eth(remaining)} WETH</span></div>
          <div className="row"><span className="muted">Max per NFT</span><span className="num">{eth(t.maxPrice)} WETH</span></div>
          {b.state === "active" && <div className="row"><span className="muted">Ends in</span><span>{now < BigInt(t.expiry) ? duration(BigInt(t.expiry) - now) : date(t.expiry)}</span></div>}
          <div className="row"><span className="muted">Buyer</span><span className="num">{short(t.buyer)}</span></div>
        </div>

        <div style={{ paddingTop: 32 }}>
          <Action b={b} refetch={() => q.refetch()} />
        </div>

        {!!b.sales?.length && (
          <section style={{ marginTop: 40 }}>
            <p className="label" style={{ marginBottom: 12 }}>Fills</p>
            <div className="rows">
              {b.sales.map((s) => (
                <div className="row" key={s.tx}>
                  <span className="num">#{s.token_id} from {short(s.seller)}</span>
                  <span className="num">{eth(s.proceeds)} WETH{explorer && <> · <a href={`${explorer}/tx/${s.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>{short(s.tx)}</a></>}</span>
                </div>
              ))}
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

function Action({ b, refetch }: { b: Bid; refetch: () => void }) {
  const { address } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const cancel = useTx(refetch);
  const withdraw = useTx(refetch);
  const t = b.bid;
  const isBuyer = address?.toLowerCase() === t.buyer.toLowerCase();

  if (isBuyer)
    return (
      <div className="rows">
        <div className="row">
          <TxButton ghost small state={cancel.state} disabled={b.state === "cancelled"} onClick={() => cancel.run(() => writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "cancelBid", args: [t, BigInt(b.id)] }))}>Cancel</TxButton>
          <TxButton ghost small state={withdraw.state} onClick={() => withdraw.run(() => writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "withdrawBid", args: [t, BigInt(b.id), t.buyer] }))}>Withdraw budget</TxButton>
        </div>
        <TxStatus state={cancel.state.s === "idle" ? withdraw.state : cancel.state} />
      </div>
    );

  if (b.state !== "active") return <p className="muted">This bid is {b.state}.</p>;
  if (!address) return <div className="rows"><div className="row"><span>Connect a wallet to sell into this bid.</span><Wallet /></div></div>;
  return <SellInto b={b} refetch={refetch} />;
}

/** A holder picks an eligible owned NFT and sells it into the bid. */
function SellInto({ b, refetch }: { b: Bid; refetch: () => void }) {
  const { address } = useAccount();
  const t = b.bid;
  const owned = useQuery({ queryKey: ["owned", address], queryFn: () => getJson<Nft[]>(`/api/nfts?owner=${address}`), enabled: !!address, retry: false });
  const [manual, setManual] = useState("");
  const [picked, setPicked] = useState<string | null>(null);

  const eligible = (owned.data ?? []).filter((n) => n.contract.toLowerCase() === t.nft.toLowerCase() && BigInt(n.tokenId) >= t.minTokenId && BigInt(n.tokenId) <= t.maxTokenId);
  const tokenId = picked ?? (/^\d{1,78}$/.test(manual) ? manual : null);

  return (
    <div>
      <p className="label" style={{ marginBottom: 12 }}>Sell an NFT into this bid</p>
      {eligible.length > 0 ? (
        <div className="picker" style={{ marginBottom: 16 }}>
          {eligible.map((n) => (
            <button key={n.tokenId} aria-pressed={picked === n.tokenId} onClick={() => setPicked(n.tokenId)}>
              {n.image ? <img src={n.image} alt="" referrerPolicy="no-referrer" loading="lazy" /> : <div className="ph skeleton" />}
              <span>#{n.tokenId}</span>
            </button>
          ))}
        </div>
      ) : (
        <div className="field">
          <label className="label" htmlFor="tid">Your token id</label>
          <input id="tid" inputMode="numeric" placeholder="token id you own" value={manual} onChange={(e) => setManual(e.target.value)} autoComplete="off" />
          <span className="hint">Must be in range and owned by you.</span>
        </div>
      )}
      {tokenId && <Sell key={tokenId} b={b} tokenId={BigInt(tokenId)} refetch={refetch} />}
    </div>
  );
}

function Sell({ b, tokenId, refetch }: { b: Bid; tokenId: bigint; refetch: () => void }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const sell = useTx(refetch);
  const t = b.bid;
  const quote = useReadContract({ address: MARKET, abi: marketAbi, functionName: "quoteSell", args: [t, BigInt(b.id), tokenId], query: { refetchInterval: 8_000 } });
  const proceeds = quote.data?.proceeds ?? null;

  return (
    <div className="rows" style={{ marginTop: 8 }}>
      {quote.isError && <p className="status err" role="alert">This token cannot sell into the bid (not owned, ineligible, or budget spent).</p>}
      {proceeds !== null && <div className="row"><span className="muted">You receive</span><span className="num">{eth(proceeds)} WETH</span></div>}
      <TxButton
        state={sell.state}
        pendingLabel="Selling"
        disabled={proceeds === null}
        onClick={() =>
          sell.run(async () => {
            const q = await client!.readContract({ address: MARKET, abi: marketAbi, functionName: "quoteSell", args: [t, BigInt(b.id), tokenId] });
            return writeContractAsync({ address: t.nft, abi: erc721Abi, functionName: "safeTransferFrom", args: [address!, MARKET, tokenId, sellData(t, BigInt(b.id), q.proceeds, "0x0000000000000000000000000000000000000000")] });
          })
        }
      >
        {proceeds !== null ? `Sell #${tokenId} for ${eth(proceeds)} WETH` : "Sell"}
      </TxButton>
      <TxStatus state={sell.state} />
    </div>
  );
}
