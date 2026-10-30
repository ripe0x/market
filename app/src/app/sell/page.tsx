"use client";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, parseEventLogs, type Address } from "viem";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { MARKET, WETH, buyerPrice, erc721Abi, fixedPrice, listData, marketAbi, type Listing, type Price } from "../../../lib/order";
import { date, eth, parseEth } from "../../ui/format";
import { Art, Curve, Wallet, getJson, useNft, type Nft } from "../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../ui/tx";

const DAYS = [1, 3, 7, 14, 30];
type Kind = "fixed" | "declining" | "rising";

/** Accepts "0x…/123", "0x… 123" or an OpenSea item URL. */
function parseRef(s: string): { contract: Address; tokenId: string } | null {
  const m = s.match(/(0x[0-9a-fA-F]{40})[/\s:#]+(\d{1,78})/);
  return m && isAddress(m[1]) ? { contract: m[1], tokenId: m[2] } : null;
}

/** Listing terms from the form. start/end are seller net proceeds; floor is the minimum. */
function terms(p: { seller: Address; nft: Address; tokenId: bigint; kind: Kind; start: bigint; end: bigint; now: bigint; days: number }): Listing {
  const start = Number(p.now);
  const expiry = start + p.days * 86400;
  let price: Price;
  let floor: bigint;
  if (p.kind === "fixed") {
    price = fixedPrice(p.start);
    floor = p.start;
  } else {
    price = { start: p.start, end: p.end, startTime: start, endTime: expiry, strategy: "0x0000000000000000000000000000000000000000", data: `0x${"0".repeat(64)}` };
    floor = p.kind === "declining" ? p.end : p.start;
  }
  return { seller: p.seller, nft: p.nft, tokenId: p.tokenId, currency: WETH, recipient: p.seller, floor, expiry, price };
}

export default function Sell() {
  const { address } = useAccount();
  const [ref, setRef] = useState<{ contract: Address; tokenId: string } | null>(null);
  const [manual, setManual] = useState("");
  const [kind, setKind] = useState<Kind>("declining");
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [days, setDays] = useState(7);
  const [zeroOk, setZeroOk] = useState(false);

  const owned = useQuery({ queryKey: ["owned", address], queryFn: () => getJson<Nft[]>(`/api/nfts?owner=${address}`), enabled: !!address, retry: false });
  const nft = useNft(ref?.contract, ref?.tokenId);
  const isOwner = !!address && nft.data?.owner?.toLowerCase() === address.toLowerCase();

  const s = parseEth(start);
  const e = kind === "fixed" ? s : parseEth(end);
  // The minimum net proceeds this listing can settle at.
  const floorWei = kind === "declining" ? e : kind === "rising" ? s : s;
  const problem =
    s === null || s === 0n
      ? start
        ? "Enter a price above zero."
        : ""
      : kind !== "fixed" && e === null
        ? end
          ? "Enter an end price."
          : ""
        : kind === "declining" && e !== null && e > s
          ? "End must be at or below start."
          : kind === "rising" && e !== null && e < s
            ? "End must be at or above start."
            : floorWei === 0n && !zeroOk
              ? "zero"
              : "";
  const ready = !!ref && isOwner && s !== null && s > 0n && e !== null && problem === "";

  // Preview uses wall clock; the deposit uses chain time.
  const now = BigInt(Math.floor(Date.now() / 1000));
  const preview = ready && e !== null && s !== null ? terms({ seller: address!, nft: ref!.contract, tokenId: 0n, kind, start: s, end: e, now, days }) : null;

  return (
    <>
      <div className="head"><h1>Sell</h1></div>
      <div className="split">
        <div>
          {ref && <Art nft={nft.data} />}
          <div className="field">
            <label className="label" htmlFor="ref">NFT</label>
            {owned.data && owned.data.length > 0 ? (
              <div className="picker" style={{ paddingTop: 8 }}>
                {owned.data.map((n) => {
                  const on = ref?.contract.toLowerCase() === n.contract.toLowerCase() && ref.tokenId === n.tokenId;
                  return (
                    <button key={n.contract + n.tokenId} aria-pressed={on} onClick={() => setRef({ contract: n.contract as Address, tokenId: n.tokenId })}>
                      {n.image ? <img src={n.image} alt="" referrerPolicy="no-referrer" loading="lazy" /> : <div className="ph skeleton" />}
                      <span>{n.name}</span>
                    </button>
                  );
                })}
              </div>
            ) : (
              <>
                <input id="ref" placeholder="0x… / token id" value={manual} style={{ fontSize: 16 }} onChange={(e) => { setManual(e.target.value); setRef(parseRef(e.target.value)); }} autoComplete="off" spellCheck={false} />
                <span className="hint">Contract and token id, or an OpenSea link.</span>
              </>
            )}
            {ref && nft.isPending && <span className="hint">Loading</span>}
            {ref && nft.data && <span className="hint">{nft.data.collection} · {nft.data.name}</span>}
            {ref && nft.isError && <span className="err">Not found.</span>}
            {ref && nft.data && address && !isOwner && <span className="err">This wallet does not own this NFT.</span>}
          </div>
        </div>

        <div>
          <div className="field">
            <span className="label">Price</span>
            <div className="choices">
              {(["fixed", "declining", "rising"] as Kind[]).map((k) => (
                <button key={k} aria-pressed={kind === k} onClick={() => setKind(k)} style={{ textTransform: "capitalize" }}>{k}</button>
              ))}
            </div>
          </div>
          <div className="field">
            <label className="label" htmlFor="start">{kind === "fixed" ? "Price" : "Start price"}</label>
            <input id="start" inputMode="decimal" placeholder="0.00" value={start} onChange={(e) => setStart(e.target.value)} autoComplete="off" />
          </div>
          {kind !== "fixed" && (
            <div className="field">
              <label className="label" htmlFor="end">{kind === "declining" ? "Floor (end price)" : "End price"}</label>
              <input id="end" inputMode="decimal" placeholder="0.00" value={end} onChange={(e) => setEnd(e.target.value)} autoComplete="off" />
            </div>
          )}
          {problem && problem !== "zero" && <span className="err">{problem}</span>}
          {floorWei === 0n && s !== null && s > 0n && (
            <label className="check">
              <input type="checkbox" checked={zeroOk} onChange={(e) => setZeroOk(e.target.checked)} />
              <span>A zero floor can sell for almost nothing.</span>
            </label>
          )}

          <div className="field">
            <span className="label">Open for</span>
            <div className="choices">
              {DAYS.map((d) => (<button key={d} aria-pressed={days === d} onClick={() => setDays(d)}>{d}d</button>))}
            </div>
          </div>

          {preview && (
            <div style={{ padding: "24px 0" }}>
              <Curve price={preview.price} now={now} />
            </div>
          )}

          <div className="rows">
            <div className="row">
              <span className="muted">You receive at least</span>
              <span className="num">{s ? (kind === "fixed" ? `${eth(s)} WETH` : `${eth(s)} → ${eth(e ?? 0n)} WETH`) : "-"}</span>
            </div>
            <div className="row">
              <span className="muted">Buyers pay about</span>
              <span className="num">{s ? `${eth(buyerPrice(s), 4, true)} ETH + royalty` : "-"}</span>
            </div>
            <div className="row">
              <span className="muted">Ends</span>
              <span>{date(now + BigInt(days * 86400))}</span>
            </div>
            <div className="row">
              <span className="muted">Keeper or match sales</span>
              <span>0.5% fee. Any surplus over your price is yours.</span>
            </div>
          </div>

          <p className="small muted" style={{ marginTop: 20 }}>
            Listing deposits the NFT into the Market contract in one transaction. No approval. You can withdraw or cancel any time.
          </p>

          <div style={{ paddingTop: 24 }}>
            {address ? (
              ready ? <Deposit nft={ref!.contract} tokenId={BigInt(ref!.tokenId)} kind={kind} start={s!} end={e!} days={days} /> : <button className="btn" disabled>List</button>
            ) : (
              <div className="rows"><div className="row"><span>Connect a wallet to list.</span><Wallet /></div></div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}

function Deposit(p: { nft: Address; tokenId: bigint; kind: Kind; start: bigint; end: bigint; days: number }) {
  const router = useRouter();
  const client = usePublicClient();
  const { address } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const deposit = useTx();
  useEffect(() => deposit.reset(), [p.start, p.end, p.days, p.kind, p.nft, p.tokenId]); // eslint-disable-line react-hooks/exhaustive-deps

  // On confirmation, read the Listed id from the receipt and open the listing.
  useEffect(() => {
    if (deposit.state.s !== "done" || !deposit.state.hash) return;
    const hash = deposit.state.hash;
    client!.getTransactionReceipt({ hash }).then((r) => {
      const ev = parseEventLogs({ abi: marketAbi, eventName: "Listed", logs: r.logs })[0];
      if (ev) router.push(`/l/${(ev.args as any).id}`);
    });
  }, [deposit.state]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <>
      <TxButton
        state={deposit.state}
        pendingLabel="Depositing"
        onClick={() =>
          deposit.run(async () => {
            const block = await client!.getBlock();
            const l = terms({ seller: address!, nft: p.nft, tokenId: p.tokenId, kind: p.kind, start: p.start, end: p.end, now: block.timestamp, days: p.days });
            return writeContractAsync({ address: p.nft, abi: erc721Abi, functionName: "safeTransferFrom", args: [address!, MARKET, p.tokenId, listData(l)] });
          })
        }
      >
        List
      </TxButton>
      <TxStatus state={deposit.state} />
    </>
  );
}
