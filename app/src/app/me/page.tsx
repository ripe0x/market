"use client";
import Link from "next/link";
import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { date, eth, explorer, short } from "../../ui/format";
import { State, Wallet, getJson, hydrateBid, hydrateListing } from "../../ui/parts";

const MAX = (1n << 256n) - 1n;
type Sale = { tx: string; listing_id: number | null; bid_id: number | null; nft: string; token_id: string; seller: string; buyer: string; proceeds: string; price: string; block: number };

export default function Yours() {
  const { address } = useAccount();
  const listings = useQuery({ queryKey: ["mine-listings", address], queryFn: async () => (await getJson<any[]>(`/api/listings?seller=${address}`)).map(hydrateListing), enabled: !!address, refetchInterval: 30_000 });
  const bids = useQuery({ queryKey: ["mine-bids", address], queryFn: async () => (await getJson<any[]>(`/api/bids?buyer=${address}`)).map(hydrateBid), enabled: !!address, refetchInterval: 30_000 });
  const sold = useQuery({ queryKey: ["sold", address], queryFn: () => getJson<Sale[]>(`/api/sales?seller=${address}`), enabled: !!address });
  const bought = useQuery({ queryKey: ["bought", address], queryFn: () => getJson<Sale[]>(`/api/sales?buyer=${address}`), enabled: !!address });

  if (!address)
    return (
      <>
        <div className="head"><h1>Yours</h1></div>
        <div className="empty"><p>Connect a wallet to see your activity.</p><Wallet /></div>
      </>
    );

  return (
    <>
      <div className="head"><h1>Yours</h1><Link className="btn small" href="/sell">Sell</Link></div>

      <Section title="Listings" empty="No listings yet." loading={listings.isPending} error={listings.isError} rows={listings.data}>
        <table>
          <thead><tr className="label"><th>NFT</th><th>Status</th><th>Seller receives</th><th>Floor</th><th>Ends</th></tr></thead>
          <tbody>
            {listings.data?.map((l) => (
              <tr key={l.id}>
                <td><Link href={`/l/${l.id}`} style={{ textDecoration: "underline", textUnderlineOffset: 3 }}>{l.nft?.name ?? `#${l.listing.tokenId}`}</Link></td>
                <td><State state={l.state} /></td>
                <td className="num">{l.state === "active" ? eth(l.ask) : "-"}</td>
                <td className="num">{eth(l.listing.floor)}</td>
                <td>{date(l.listing.expiry)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      <Section title="Bids" empty="No bids yet." loading={bids.isPending} error={bids.isError} rows={bids.data}>
        <table>
          <thead><tr className="label"><th>Collection</th><th>Status</th><th>Per NFT</th><th>Filled</th><th>Budget left</th></tr></thead>
          <tbody>
            {bids.data?.map((b) => {
              const whole = b.bid.minTokenId === 0n && b.bid.maxTokenId === MAX;
              const scope = whole ? "all" : b.bid.minTokenId === b.bid.maxTokenId ? `#${b.bid.minTokenId}` : `#${b.bid.minTokenId}–${b.bid.maxTokenId}`;
              return (
                <tr key={b.id}>
                  <td><Link href={`/bid/${b.id}`} style={{ textDecoration: "underline", textUnderlineOffset: 3 }}>{b.nft?.collection ?? short(b.bid.nft)} {scope}</Link></td>
                  <td><State state={b.state} /></td>
                  <td className="num">{eth(b.bid.maxPrice)}</td>
                  <td className="num">{b.fills}/{Number(b.bid.quantity)}</td>
                  <td className="num">{eth(BigInt(b.bid.budget) - BigInt(b.spent))}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Section>

      <SalesSection title="Sold" rows={sold.data} amount={(s) => s.proceeds} amountLabel="Received" />
      <SalesSection title="Bought" rows={bought.data} amount={(s) => s.price} amountLabel="Paid" />
    </>
  );
}

function Section({ title, empty, loading, error, rows, children }: { title: string; empty: string; loading: boolean; error: boolean; rows?: unknown[]; children: ReactNode }) {
  return (
    <section style={{ marginBottom: 56 }}>
      <p className="label" style={{ marginBottom: 12 }}>{title}</p>
      {loading && <div className="skeleton" style={{ height: 100 }} />}
      {error && <p className="status err" role="alert">Could not load {title.toLowerCase()}.</p>}
      {rows?.length === 0 && <p className="muted">{empty}</p>}
      {!!rows?.length && <div className="scroll">{children}</div>}
    </section>
  );
}

function SalesSection({ title, rows, amount, amountLabel }: { title: string; rows?: Sale[]; amount: (s: Sale) => string; amountLabel: string }) {
  if (!rows?.length) return null;
  return (
    <section style={{ marginBottom: 56 }}>
      <p className="label" style={{ marginBottom: 12 }}>{title}</p>
      <div className="scroll">
        <table>
          <thead><tr className="label"><th>NFT</th><th>{amountLabel}</th><th>Counterparty</th><th>Tx</th></tr></thead>
          <tbody>
            {rows.map((s) => (
              <tr key={s.tx + s.token_id}>
                <td>{s.listing_id ? <Link href={`/l/${s.listing_id}`} style={{ textDecoration: "underline", textUnderlineOffset: 3 }}>#{s.token_id}</Link> : `#${s.token_id}`}</td>
                <td className="num">{eth(amount(s))} WETH</td>
                <td className="num">{short(title === "Sold" ? s.buyer : s.seller)}</td>
                <td className="num">{explorer ? <a href={`${explorer}/tx/${s.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>{short(s.tx)}</a> : short(s.tx)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
