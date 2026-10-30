"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { eth } from "../ui/format";
import { Art, getJson, hydrate, type Listing } from "../ui/parts";

export default function Browse() {
  const { data, isPending, error } = useQuery({
    queryKey: ["listings"],
    queryFn: async () => (await getJson<any[]>("/api/listings")).map(hydrate),
    refetchInterval: 30_000,
  });
  return (
    <>
      <div className="head">
        <h1>Listed</h1>
        <span className="label">{data ? `${data.length} live` : ""}</span>
      </div>
      {error && <p className="status err" role="alert">Could not load listings.</p>}
      {isPending && (
        <div className="grid" aria-busy>
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="card">
              <div className="art skeleton" />
              <div className="cap"><span className="skeleton" style={{ width: "60%", height: 14 }} /></div>
            </div>
          ))}
        </div>
      )}
      {data?.length === 0 && (
        <div className="empty">
          <span className="glyph" style={{ width: 48 }} aria-hidden />
          <p>Nothing listed.</p>
          <Link className="btn small" href="/sell">Sell an NFT</Link>
        </div>
      )}
      {!!data?.length && (
        <div className="grid">
          {data.map((l) => <Card key={l.hash} l={l} />)}
        </div>
      )}
    </>
  );
}

function Card({ l }: { l: Listing }) {
  return (
    <Link href={`/l/${l.hash}`} className="card">
      <Art nft={l.nft} size="card" />
      <div className="cap">
        <span>{l.nft?.name ?? `#${l.components.offer[0].identifierOrCriteria}`}</span>
        <span className="num">{l.state === "scheduled" ? "Soon" : `${eth(l.price)} ETH`}</span>
      </div>
      <div className="small muted">{l.nft?.collection}</div>
      <Track l={l} />
    </Link>
  );
}

/** How far the price has fallen toward the floor. */
function Track({ l }: { l: Listing }) {
  const { startTime: a, endTime: b } = l.components;
  const t = Number(l.now);
  const f = Math.min(1, Math.max(0, (t - Number(a)) / (Number(b) - Number(a))));
  return (
    <div style={{ height: 1, background: "var(--faint)", marginTop: 10 }} aria-hidden>
      <div style={{ height: 1, width: `${f * 100}%`, background: "var(--fg)" }} />
    </div>
  );
}
