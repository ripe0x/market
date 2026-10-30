"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { date, eth, explorer, short } from "../../ui/format";
import { State, Wallet, getJson, hydrate } from "../../ui/parts";

type Sale = { tx: string; hash: string | null; nft: string; token_id: string; buyer: string; seller_proceeds: string; executor_fee: string; protocol_fee: string; block: number };

export default function Yours() {
  const { address } = useAccount();
  const listings = useQuery({
    queryKey: ["mine", address],
    queryFn: async () => (await getJson<any[]>(`/api/listings?seller=${address}`)).map(hydrate),
    enabled: !!address,
    refetchInterval: 30_000,
  });
  const sales = useQuery({ queryKey: ["sales", address], queryFn: () => getJson<Sale[]>(`/api/sales?seller=${address}`), enabled: !!address });

  if (!address)
    return (
      <>
        <div className="head"><h1>Yours</h1></div>
        <div className="empty">
          <p>Connect a wallet to see your listings.</p>
          <Wallet />
        </div>
      </>
    );

  const open = listings.data?.filter((l) => ["active", "scheduled", "unavailable"].includes(l.state)) ?? [];
  const closed = listings.data?.filter((l) => !["active", "scheduled", "unavailable"].includes(l.state)) ?? [];
  return (
    <>
      <div className="head">
        <h1>Yours</h1>
        <Link className="btn small" href="/sell">Sell</Link>
      </div>

      <section style={{ marginBottom: 64 }}>
        <p className="label" style={{ marginBottom: 12 }}>Listings</p>
        {listings.isPending && <div className="skeleton" style={{ height: 120 }} />}
        {listings.isError && <p className="status err" role="alert">Could not load listings.</p>}
        {listings.data?.length === 0 && <p className="muted">No listings yet.</p>}
        {!!listings.data?.length && (
          <div className="scroll">
            <table>
              <thead>
                <tr className="label">
                  <th>NFT</th>
                  <th>Status</th>
                  <th>Price now</th>
                  <th>Floor</th>
                  <th>Ends</th>
                </tr>
              </thead>
              <tbody>
                {[...open, ...closed].map((l) => (
                  <tr key={l.hash}>
                    <td><Link href={`/l/${l.hash}`} style={{ textDecoration: "underline", textUnderlineOffset: 3 }}>{l.nft?.name ?? short(l.hash)}</Link></td>
                    <td><State state={l.state} /></td>
                    <td className="num">{l.state === "active" ? eth(l.price) : "-"}</td>
                    <td className="num">{eth(l.components.consideration[0].endAmount)}</td>
                    <td>{date(l.components.endTime)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section>
        <p className="label" style={{ marginBottom: 12 }}>Sales</p>
        {sales.data?.length === 0 && <p className="muted">No sales yet.</p>}
        {!!sales.data?.length && (
          <div className="scroll">
            <table>
              <thead>
                <tr className="label">
                  <th>NFT</th>
                  <th>Received</th>
                  <th>Fees</th>
                  <th>Buyer</th>
                  <th>Tx</th>
                </tr>
              </thead>
              <tbody>
                {sales.data.map((s) => (
                  <tr key={s.tx}>
                    <td>{s.hash ? <Link href={`/l/${s.hash}`} style={{ textDecoration: "underline", textUnderlineOffset: 3 }}>#{s.token_id}</Link> : `#${s.token_id}`}</td>
                    <td className="num">{eth(s.seller_proceeds)} WETH</td>
                    <td className="num">{eth(BigInt(s.executor_fee) + BigInt(s.protocol_fee), 6)}</td>
                    <td className="num">{short(s.buyer)}</td>
                    <td className="num">{explorer ? <a href={`${explorer}/tx/${s.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>{short(s.tx)}</a> : short(s.tx)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
