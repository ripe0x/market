"use client";
import Link from "next/link";
import { use } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useBalance, usePublicClient, useWriteContract } from "wagmi";
import { MARKET, SEAPORT, buyerTotal, marketAbi, seaportAbi, toAdvancedOrder, toParameters } from "../../../../lib/order";
import { date, duration, eth, explorer, short } from "../../../ui/format";
import { Art, Curve, State, Wallet, getJson, hydrate, useLivePrice, type Listing } from "../../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../../ui/tx";

type Sale = { tx: string; buyer: string; seller_proceeds: string; executor_fee: string; protocol_fee: string };

export default function ListingPage({ params }: { params: Promise<{ hash: string }> }) {
  const { hash } = use(params);
  const q = useQuery({
    queryKey: ["listing", hash],
    queryFn: async () => {
      const l = await getJson<any>(`/api/listings/${hash}`);
      return { ...hydrate(l), sale: l.sale as Sale | null };
    },
    // Closed listings stop polling, except a sale still waiting for its indexed details.
    refetchInterval: (query) => {
      const d = query.state.data;
      return d && (d.state === "cancelled" || d.state === "expired" || (d.state === "sold" && d.sale)) ? false : 6_000;
    },
  });
  const l = q.data;
  const { now, price } = useLivePrice(l);

  if (q.isError) return <div className="empty"><p>Listing not found.</p><Link className="btn small" href="/">Browse</Link></div>;
  if (!l)
    return (
      <div className="split" aria-busy>
        <div className="art skeleton" />
        <div className="rows"><div className="row skeleton" style={{ height: 120 }} /></div>
      </div>
    );

  const c = l.components;
  const floor = c.consideration[0].endAmount;
  const live = l.state === "active" && price !== null;
  return (
    <div className="split">
      <Art nft={l.nft} />
      <div>
        <p className="label">{l.nft?.collection}</p>
        <h2 style={{ margin: "6px 0 20px" }}>{l.nft?.name}</h2>
        <State state={l.state} />

        <div style={{ margin: "28px 0 8px" }}>
          <p className="label">{l.state === "sold" ? "Sold for" : "Price"}</p>
          <p className="big num" aria-live="off">{live ? eth(price) : l.state === "sold" && l.sale ? eth(l.sale.seller_proceeds) : eth(l.price ?? floor)}</p>
          <p className="muted small">ETH</p>
        </div>

        <div style={{ padding: "20px 0" }}>
          <Curve c={c} now={now} />
        </div>

        <div className="rows">
          {live && (
            <div className="row">
              <span className="muted">Buyer pays</span>
              <span className="num">{eth(buyerTotal(price!), 4, true)} ETH</span>
            </div>
          )}
          <div className="row">
            <span className="muted">Floor</span>
            <span className="num">{eth(floor)} ETH</span>
          </div>
          {l.state !== "sold" && l.state !== "cancelled" && (
            <div className="row">
              <span className="muted">{l.state === "scheduled" ? "Starts" : now < c.endTime ? "Ends in" : "Ended"}</span>
              <span>{l.state === "scheduled" ? date(c.startTime) : now < c.endTime ? duration(c.endTime - now) : date(c.endTime)}</span>
            </div>
          )}
          <div className="row">
            <span className="muted">Seller</span>
            <span className="num">{short(c.offerer)}</span>
          </div>
        </div>

        <div style={{ paddingTop: 32 }}>
          <Action l={l} price={price} refetch={() => q.refetch()} sale={l.sale} />
        </div>
      </div>
    </div>
  );
}

function Action({ l, price, refetch, sale }: { l: Listing; price: bigint | null; refetch: () => void; sale: Sale | null }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const balance = useBalance({ address });
  const { writeContractAsync } = useWriteContract();
  const buy = useTx(refetch);
  const cancel = useTx(refetch);
  const isSeller = address?.toLowerCase() === l.components.offerer.toLowerCase();

  if (l.state === "sold")
    return (
      <div className="rows">
        <div className="row">
          <span>{buy.state.s === "done" ? "Yours." : "Sold."}</span>
          {sale && explorer && (
            <a className="small" href={`${explorer}/tx/${sale.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>
              {short(sale.tx)}
            </a>
          )}
        </div>
        {sale && (
          <>
            <div className="row"><span className="muted">Seller received</span><span className="num">{eth(sale.seller_proceeds)} WETH</span></div>
            {BigInt(sale.executor_fee) > 0n && <div className="row"><span className="muted">Executor fee</span><span className="num">{eth(sale.executor_fee, 6)} WETH</span></div>}
            <div className="row"><span className="muted">Protocol fee</span><span className="num">{eth(sale.protocol_fee, 6)} WETH</span></div>
            <div className="row"><span className="muted">Buyer</span><span className="num">{short(sale.buyer)}</span></div>
          </>
        )}
      </div>
    );
  if (l.state === "cancelled")
    return (
      <>
        <p>Cancelled onchain.</p>
        {isSeller && <p className="small muted" style={{ marginTop: 8 }}>The collection approval stays on. It is shared with OpenSea listings.</p>}
      </>
    );
  if (l.state === "expired") return <p>Ended without a sale.</p>;

  const cancelButton = isSeller && (
    <>
      <TxButton
        ghost
        state={cancel.state}
        onClick={() =>
          cancel.run(() => writeContractAsync({ address: SEAPORT, abi: seaportAbi, functionName: "cancel", args: [[l.components]] }))
        }
      >
        Cancel listing
      </TxButton>
      <TxStatus state={cancel.state} />
    </>
  );

  if (l.state === "unavailable")
    return (
      <>
        <p style={{ marginBottom: 16 }}>{l.reason === "not owner" ? "The seller no longer holds this NFT." : "The seller's approval is off."}</p>
        {cancelButton}
      </>
    );
  if (l.state === "scheduled") return <>{cancelButton || <p>Not open yet.</p>}</>;
  if (isSeller) return <>{cancelButton}</>;
  if (!address)
    return (
      <div className="rows">
        <div className="row">
          <span>Connect a wallet to buy.</span>
          <Wallet />
        </div>
      </div>
    );

  const total = price !== null ? buyerTotal(price) : null;
  const short_ = balance.data && total !== null && balance.data.value < total;
  return (
    <>
      <TxButton
        state={buy.state}
        disabled={total === null || short_}
        onClick={() =>
          buy.run(async () => {
            // Chain price at the latest block; inclusion happens later, when it is lower, and Market refunds the difference.
            const p = await client!.readContract({ address: MARKET, abi: marketAbi, functionName: "currentPrice", args: [toParameters(l.components)] });
            const call = { address: MARKET, abi: marketAbi, functionName: "buy", args: [toAdvancedOrder(l.components, l.signature)], value: buyerTotal(p) } as const;
            // Estimation may see no excess; at inclusion the price is lower and the WETH refund adds a storage write.
            const gas = await client!.estimateContractGas({ ...call, account: address });
            return writeContractAsync({ ...call, gas: gas + 40_000n });
          })
        }
      >
        {short_ ? "Not enough ETH" : `Buy for ${eth(total, 4, true)} ETH`}
      </TxButton>
      <TxStatus state={buy.state} />
    </>
  );
}
