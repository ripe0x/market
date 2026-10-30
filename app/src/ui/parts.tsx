"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { mainnet } from "wagmi/chains";
import { askAt, bidFromJson, bidPriceAt, listingFromJson, type Bid as BidTerms, type Listing as ListingTerms, type Price } from "../../lib/order";
import { short } from "./format";
import { devAccounts } from "./providers";

export type Nft = { contract: string; tokenId: string; name: string; collection: string; image: string | null };
export type ListingState = "active" | "expired" | "cancelled" | "sold" | "withdrawn";
export type BidState = "active" | "expired" | "filled" | "cancelled" | "withdrawn";

export type Listing = { id: number; listing: ListingTerms; state: ListingState; ask: string | null; now: string; nft?: Nft };
export type Bid = { id: number; bid: BidTerms; state: BidState; price: string | null; spent: string; fills: number; now: string; nft?: Nft };

/** API JSON carries bigints as strings; rebuild the typed terms. */
export const hydrateListing = (l: any): Listing => ({ ...l, listing: listingFromJson(l.listing) });
export const hydrateBid = (b: any): Bid => ({ ...b, bid: bidFromJson(b.bid) });

export async function getJson<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, init);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = String(body.error ?? `request failed (${res.status})`);
    throw new Error(msg[0].toUpperCase() + msg.slice(1) + ".");
  }
  return body;
}

export function Header() {
  const path = usePathname();
  const nav = [
    ["/", "Browse"],
    ["/bids", "Bids"],
    ["/sell", "Sell"],
    ["/me", "Yours"],
  ];
  return (
    <header className="top">
      <div className="wrap">
        <Link href="/" className="mark">
          <i aria-hidden />
          Market
        </Link>
        <nav className="nav">
          {nav.map(([href, label]) => (
            <Link key={href} href={href} aria-current={path === href ? "page" : undefined}>
              {label}
            </Link>
          ))}
          <Wallet />
        </nav>
      </div>
    </header>
  );
}

export function Wallet() {
  const { address, chainId, status } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  if (!mounted || status === "reconnecting") return <span className="btn small ghost skeleton" style={{ width: 96 }} aria-hidden />;
  if (address && chainId !== mainnet.id)
    return (
      <button className="btn small" onClick={() => switchChain({ chainId: mainnet.id })}>
        Switch to Ethereum
      </button>
    );
  if (address)
    return (
      <button className="btn small ghost num" onClick={() => disconnect()} title="Disconnect">
        {short(address)}
      </button>
    );
  const options = connectors.filter((c) => c.id !== "injected" || connectors.length === 1);
  return (
    <div style={{ position: "relative" }}>
      <button className="btn small" onClick={() => (options.length === 1 ? connect({ connector: options[0] }) : setOpen(!open))} disabled={isPending}>
        {isPending ? "Connecting" : "Connect"}
      </button>
      {open && (
        <div style={{ position: "absolute", right: 0, top: 44, background: "var(--bg)", border: "1px solid var(--rule)", minWidth: 220, zIndex: 10 }}>
          {options.map((c) => (
            <button
              key={c.uid}
              className="btn ghost small"
              style={{ width: "100%", justifyContent: "flex-start", border: 0, borderBottom: "1px solid var(--faint)" }}
              onClick={() => {
                setOpen(false);
                connect({ connector: c });
              }}
            >
              {c.type === "mock" ? `Dev ${short(devAccounts[connectors.filter((x) => x.type === "mock").indexOf(c)])}` : c.name}
            </button>
          ))}
          {!options.length && <p className="small muted" style={{ padding: 12 }}>No wallet found.</p>}
        </div>
      )}
    </div>
  );
}

export function Art({ nft, size }: { nft?: Nft; size?: "card" }) {
  const [broken, setBroken] = useState<string | null>(null);
  return (
    <div className="art">
      {nft?.image && broken !== nft.image ? (
        <img src={nft.image} alt={nft.name} referrerPolicy="no-referrer" loading={size === "card" ? "lazy" : "eager"} onError={() => setBroken(nft.image)} />
      ) : (
        <span className="glyph" aria-hidden />
      )}
    </div>
  );
}

export function useNft(contract?: string, tokenId?: string) {
  return useQuery({
    queryKey: ["nft", contract, tokenId],
    queryFn: () => getJson<Nft & { owner: string | null }>(`/api/nft?contract=${contract}&id=${tokenId}`),
    enabled: !!contract && !!tokenId,
    staleTime: 10 * 60_000,
  });
}

/** Ticks a built-in price (ask for a listing, payment for a bid) each second from the server's chain time. */
export function useLiveNow(now?: string) {
  const [t, setT] = useState(0);
  useEffect(() => {
    if (!now) return;
    const start = Date.now();
    setT(0);
    const id = setInterval(() => setT(Math.floor((Date.now() - start) / 1000)), 1000);
    return () => clearInterval(id);
  }, [now]);
  return now ? BigInt(now) + BigInt(t) : 0n;
}

export function useListingAsk(l?: Listing) {
  const now = useLiveNow(l?.now);
  if (!l) return { now: 0n, ask: null as bigint | null };
  return { now, ask: askAt(l.listing, now) };
}

const listingLabel: Record<ListingState, string> = { active: "Live", expired: "Ended", cancelled: "Cancelled", sold: "Sold", withdrawn: "Withdrawn" };
const bidLabel: Record<BidState, string> = { active: "Live", expired: "Ended", filled: "Filled", cancelled: "Cancelled", withdrawn: "Withdrawn" };
export const State = ({ state }: { state: ListingState | BidState }) => (
  <span className="pill" data-state={state}>
    {(listingLabel as any)[state] ?? (bidLabel as any)[state]}
  </span>
);

/** Price line over the order window with a marker at now. */
export function Curve({ price, now, isBid = false }: { price: Price; now: bigint; isBid?: boolean }) {
  const W = 600;
  const H = 160;
  const s = Number(price.start);
  const e = Number(price.end);
  const t0 = Number(price.startTime);
  const t1 = Number(price.endTime);
  const external = price.strategy !== "0x0000000000000000000000000000000000000000";
  const hi = Math.max(s, e, 1);
  const x = (t: number) => (t1 <= t0 ? 0 : ((Math.min(Math.max(t, t0), t1) - t0) / (t1 - t0)) * W);
  const y = (v: number) => H - (v / hi) * (H - 8) - 4;
  const at = (t: number) => {
    if (t1 <= t0 || t >= t1) return e;
    if (t <= t0) return s;
    const frac = (t - t0) / (t1 - t0);
    return s + (e - s) * frac;
  };
  const n = Number(now);
  if (external)
    return (
      <div className="small muted" style={{ padding: "20px 0" }}>
        External pricing strategy. The on-chain quote is the live figure.
      </div>
    );
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Price over time" style={{ display: "block", overflow: "visible" }}>
      <line x1={0} y1={H} x2={W} y2={H} stroke="var(--faint)" />
      <line x1={0} y1={y(s)} x2={W} y2={y(e)} stroke="var(--fg)" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      <line x1={x(n)} y1={y(at(n))} x2={x(n)} y2={H} stroke="var(--fg)" strokeDasharray="2 3" />
      <rect x={x(n) - 4} y={y(at(n)) - 4} width={8} height={8} fill="var(--fg)" />
    </svg>
  );
}

export function Footer() {
  const { data } = useQuery({ queryKey: ["status"], queryFn: () => getJson<{ matching: string; keeperSeen: number | null }>("/api/status"), refetchInterval: 60_000 });
  const live = data?.keeperSeen && Date.now() - data.keeperSeen < 5 * 60_000;
  return (
    <footer className="foot">
      <div className="wrap">
        <span>Prices in ETH. Settled in WETH.</span>
        <span>Keeper {live && data?.matching === "on" ? "on" : "off"}</span>
      </div>
    </footer>
  );
}
