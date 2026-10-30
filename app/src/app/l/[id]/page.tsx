"use client";
import Link from "next/link";
import { use, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import { MARKET, fixedPrice, marketAbi, type Listing as Terms } from "../../../../lib/order";
import { date, duration, eth, explorer, parseEth, short } from "../../../ui/format";
import { Art, Curve, State, Wallet, getJson, hydrateListing, useListingAsk, type Listing } from "../../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../../ui/tx";

type Sale = { tx: string; buyer: string; price: string; proceeds: string; royalty: string; executor_fee: string; protocol_fee: string };

export default function ListingPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const q = useQuery({
    queryKey: ["listing", id],
    queryFn: async () => {
      const l = await getJson<any>(`/api/listings/${id}`);
      return { ...hydrateListing(l), sale: l.sale as Sale | null };
    },
    refetchInterval: (query) => {
      const d = query.state.data;
      return d && (d.state === "cancelled" || d.state === "expired" || d.state === "withdrawn" || (d.state === "sold" && d.sale)) ? false : 6_000;
    },
  });
  const l = q.data;
  const { now, ask } = useListingAsk(l);

  if (q.isError) return <div className="empty"><p>Listing not found.</p><Link className="btn small" href="/">Browse</Link></div>;
  if (!l)
    return (
      <div className="split" aria-busy>
        <div className="art skeleton" />
        <div className="rows"><div className="row skeleton" style={{ height: 120 }} /></div>
      </div>
    );

  const t = l.listing;
  const live = l.state === "active" && ask !== null;
  return (
    <div className="split">
      <Art nft={l.nft} />
      <div>
        <p className="label">{l.nft?.collection}</p>
        <h2 style={{ margin: "6px 0 20px" }}>{l.nft?.name ?? `#${t.tokenId}`}</h2>
        <State state={l.state} />

        <div style={{ margin: "28px 0 8px" }}>
          <p className="label">{l.state === "sold" ? "Sold for" : "Seller receives"}</p>
          <p className="big num" aria-live="off">{live ? eth(ask) : l.state === "sold" && l.sale ? eth(l.sale.proceeds) : eth(l.ask ?? t.floor)}</p>
          <p className="muted small">WETH</p>
        </div>

        <div style={{ padding: "20px 0" }}>
          <Curve price={t.price} now={now} />
        </div>

        <div className="rows">
          <div className="row">
            <span className="muted">Floor</span>
            <span className="num">{eth(t.floor)} WETH</span>
          </div>
          {l.state !== "sold" && l.state !== "cancelled" && l.state !== "withdrawn" && (
            <div className="row">
              <span className="muted">{now < BigInt(t.expiry) ? "Ends in" : "Ended"}</span>
              <span>{now < BigInt(t.expiry) ? duration(BigInt(t.expiry) - now) : date(t.expiry)}</span>
            </div>
          )}
          <div className="row">
            <span className="muted">Seller</span>
            <span className="num">{short(t.seller)}</span>
          </div>
        </div>

        <div style={{ paddingTop: 32 }}>
          <Action l={l} refetch={() => q.refetch()} sale={l.sale} />
        </div>
      </div>
    </div>
  );
}

function Action({ l, refetch, sale }: { l: Listing; refetch: () => void; sale: Sale | null }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const buy = useTx(refetch);
  const cancel = useTx(refetch);
  const withdraw = useTx(refetch);
  const t = l.listing;
  const isSeller = address?.toLowerCase() === t.seller.toLowerCase();

  // Exact buyer price now, including royalty (the contract's own quote).
  const quote = useReadContract({
    address: MARKET,
    abi: marketAbi,
    functionName: "quoteBuy",
    args: [t, BigInt(l.id)],
    query: { enabled: l.state === "active", refetchInterval: 6_000 },
  });

  if (l.state === "sold")
    return (
      <div className="rows">
        <div className="row">
          <span>{buy.state.s === "done" ? "Yours." : "Sold."}</span>
          {sale && explorer && <a className="small" href={`${explorer}/tx/${sale.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>{short(sale.tx)}</a>}
        </div>
        {sale && (
          <>
            <div className="row"><span className="muted">Seller received</span><span className="num">{eth(sale.proceeds)} WETH</span></div>
            {BigInt(sale.royalty) > 0n && <div className="row"><span className="muted">Royalty</span><span className="num">{eth(sale.royalty, 6)} WETH</span></div>}
            {BigInt(sale.executor_fee) > 0n && <div className="row"><span className="muted">Executor fee</span><span className="num">{eth(sale.executor_fee, 6)} WETH</span></div>}
            <div className="row"><span className="muted">Protocol fee</span><span className="num">{eth(sale.protocol_fee, 6)} WETH</span></div>
            <div className="row"><span className="muted">Buyer</span><span className="num">{short(sale.buyer)}</span></div>
          </>
        )}
      </div>
    );

  const sellerControls = isSeller && (
    <div className="rows" style={{ marginTop: 20 }}>
      {(l.state === "active" || l.state === "expired") && <UpdatePrice l={l} refetch={refetch} />}
      <div className="row">
        <TxButton ghost small state={cancel.state} disabled={l.state === "cancelled"} onClick={() => cancel.run(() => writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "cancelListing", args: [t, BigInt(l.id)] }))}>Cancel</TxButton>
        <TxButton ghost small state={withdraw.state} onClick={() => withdraw.run(() => writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "withdrawListing", args: [t, BigInt(l.id), t.seller] }))}>Withdraw NFT</TxButton>
      </div>
      <TxStatus state={cancel.state.s === "idle" ? withdraw.state : cancel.state} />
    </div>
  );

  if (l.state === "cancelled") return <><p>Cancelled. The NFT is still in escrow.</p>{isSeller && sellerControls}</>;
  if (l.state === "withdrawn") return <p>Withdrawn from escrow.</p>;
  if (l.state === "expired") return <><p>Ended without a sale. The NFT is still in escrow.</p>{isSeller && sellerControls}</>;

  // active
  if (isSeller) return <><p className="small muted">Your listing is live. Buyers pay the quote below.</p>{sellerControls}</>;
  if (!address) return <div className="rows"><div className="row"><span>Connect a wallet to buy.</span><Wallet /></div></div>;

  const price = quote.data?.price ?? null;
  return (
    <>
      {price !== null && (
        <div className="rows" style={{ marginBottom: 16 }}>
          <div className="row"><span className="muted">You pay</span><span className="num">{eth(price, 4, true)} ETH</span></div>
          {quote.data && quote.data.royalty > 0n && <div className="row"><span className="muted">Includes royalty</span><span className="num">{eth(quote.data.royalty, 6)} WETH</span></div>}
        </div>
      )}
      <TxButton
        state={buy.state}
        disabled={price === null}
        onClick={() =>
          buy.run(async () => {
            // Re-quote at the latest block; a declining price only falls before inclusion and Market refunds the difference as WETH.
            const q = await client!.readContract({ address: MARKET, abi: marketAbi, functionName: "quoteBuy", args: [t, BigInt(l.id)] });
            const call = { address: MARKET, abi: marketAbi, functionName: "buy", args: [t, BigInt(l.id), q.price, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"], value: q.price } as const;
            const gas = await client!.estimateContractGas({ ...call, account: address! });
            return writeContractAsync({ ...call, gas: gas + 40_000n });
          })
        }
      >
        {price !== null ? `Buy for ${eth(price, 4, true)} ETH` : "Buy"}
      </TxButton>
      <TxStatus state={buy.state} />
    </>
  );
}

/** Lower or change the asking price without re-listing. */
function UpdatePrice({ l, refetch }: { l: Listing; refetch: () => void }) {
  const { writeContractAsync } = useWriteContract();
  const update = useTx(refetch);
  const [open, setOpen] = useState(false);
  const [price, setPrice] = useState("");
  const t = l.listing;
  const p = parseEth(price);

  if (!open) return <div className="row"><button className="btn ghost small" onClick={() => setOpen(true)}>Change price</button></div>;
  return (
    <div className="field">
      <label className="label" htmlFor="newprice">New fixed price (WETH)</label>
      <input id="newprice" inputMode="decimal" placeholder="0.00" value={price} onChange={(e) => setPrice(e.target.value)} autoComplete="off" />
      <div className="row" style={{ marginTop: 10 }}>
        <TxButton
          small
          state={update.state}
          disabled={p === null || p === 0n}
          onClick={() =>
            update.run(() => {
              const next: Terms = { ...t, floor: p!, price: fixedPrice(p!) };
              return writeContractAsync({ address: MARKET, abi: marketAbi, functionName: "updateListing", args: [t, BigInt(l.id), next] });
            })
          }
        >
          Set price
        </TxButton>
        <button className="btn ghost small" onClick={() => setOpen(false)}>Cancel</button>
      </div>
      <TxStatus state={update.state} />
    </div>
  );
}
