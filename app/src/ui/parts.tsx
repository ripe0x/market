"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { mainnet } from "wagmi/chains";
import { fromJson, priceAt, type Components } from "../../lib/order";
import { short } from "./format";
import { devAccounts } from "./providers";

export type Nft = { contract: string; tokenId: string; name: string; collection: string; image: string | null };
export type Listing = {
  hash: string;
  components: Components;
  signature: `0x${string}`;
  state: "scheduled" | "active" | "expired" | "cancelled" | "sold" | "unavailable";
  reason?: string;
  price: string | null;
  now: string;
  nft?: Nft;
};

/** API JSON carries bigints as strings. */
export const hydrate = (l: any): Listing => ({ ...l, components: fromJson(JSON.stringify(l.components)) });

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
  // Injected wallets announce themselves (EIP-6963); dev accounts appear only on a local fork.
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
    queryFn: () => getJson<Nft>(`/api/nft?contract=${contract}&id=${tokenId}`),
    enabled: !!contract && !!tokenId,
    staleTime: 10 * 60_000,
  });
}

/** Ticks the listing price every second from the server's chain time. */
export function useLivePrice(l?: Listing) {
  const [t, setT] = useState(0);
  useEffect(() => {
    if (!l) return;
    const start = Date.now();
    setT(0);
    const id = setInterval(() => setT(Math.floor((Date.now() - start) / 1000)), 1000);
    return () => clearInterval(id);
  }, [l?.now, l?.hash]);
  if (!l) return { now: 0n, price: null as bigint | null };
  const now = BigInt(l.now) + BigInt(t);
  return { now, price: priceAt(l.components, now) };
}

const stateLabel: Record<Listing["state"], string> = {
  scheduled: "Starts soon",
  active: "Live",
  expired: "Ended",
  cancelled: "Cancelled",
  sold: "Sold",
  unavailable: "Paused",
};
export const State = ({ state }: { state: Listing["state"] }) => (
  <span className="pill" data-state={state}>
    {stateLabel[state]}
  </span>
);

/** Start-to-floor line over the listing window with a marker at now. */
export function Curve({ c, now }: { c: Components; now: bigint }) {
  const W = 600;
  const H = 160;
  const s = Number(c.consideration[0].startAmount);
  const e = Number(c.consideration[0].endAmount);
  const t0 = Number(c.startTime);
  const t1 = Number(c.endTime);
  const x = (t: number) => ((Math.min(Math.max(t, t0), t1) - t0) / (t1 - t0)) * W;
  const y = (v: number) => (s === 0 ? H : H - (v / s) * (H - 8) - 4);
  const n = Number(now);
  const p = priceAt(c, now);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Price over time" style={{ display: "block", overflow: "visible" }}>
      <line x1={0} y1={H} x2={W} y2={H} stroke="var(--faint)" />
      <line x1={0} y1={y(s)} x2={W} y2={y(e)} stroke="var(--fg)" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      {p !== null && (
        <>
          <line x1={x(n)} y1={y(Number(p))} x2={x(n)} y2={H} stroke="var(--fg)" strokeDasharray="2 3" />
          <rect x={x(n) - 4} y={y(Number(p)) - 4} width={8} height={8} fill="var(--fg)" />
        </>
      )}
    </svg>
  );
}

export function Footer() {
  const { data } = useQuery({ queryKey: ["status"], queryFn: () => getJson<{ matching: string; keeperSeen: number | null }>("/api/status"), refetchInterval: 60_000 });
  const live = data?.keeperSeen && Date.now() - data.keeperSeen < 5 * 60_000;
  return (
    <footer className="foot">
      <div className="wrap">
        <span>Prices in ETH. Sellers are paid in WETH.</span>
        <span>Offer matching {live && data?.matching === "on" ? "on" : "off"}</span>
      </div>
    </footer>
  );
}
