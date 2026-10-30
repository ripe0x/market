"use client";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, type Address } from "viem";
import { useAccount, usePublicClient, useReadContract, useSignTypedData, useWriteContract } from "wagmi";
import { OS_CONDUIT, SEAPORT, buildListing, buyerTotal, erc721Abi, orderTypes, seaportAbi, seaportDomain, toJson } from "../../../lib/order";
import { date, eth, parseEth } from "../../ui/format";
import { Art, Curve, Wallet, getJson, useNft, type Nft } from "../../ui/parts";
import { TxButton, TxStatus, useTx } from "../../ui/tx";

const DAYS = [1, 3, 7, 14, 30];

/** Accepts "0x…/123", "0x… 123" or an OpenSea item URL. */
function parseRef(s: string): { contract: Address; tokenId: string } | null {
  const m = s.match(/(0x[0-9a-fA-F]{40})[/\s:#]+(\d{1,78})/);
  return m && isAddress(m[1]) ? { contract: m[1], tokenId: m[2] } : null;
}

export default function Sell() {
  const { address } = useAccount();
  const [ref, setRef] = useState<{ contract: Address; tokenId: string } | null>(null);
  const [manual, setManual] = useState("");
  const [start, setStart] = useState("");
  const [floor, setFloor] = useState("");
  const [days, setDays] = useState(7);
  const [zeroOk, setZeroOk] = useState(false);

  const owned = useQuery({
    queryKey: ["owned", address],
    queryFn: () => getJson<Nft[]>(`/api/nfts?owner=${address}`),
    enabled: !!address,
    retry: false,
  });
  const nft = useNft(ref?.contract, ref?.tokenId);
  const owner = (nft.data as any)?.owner as string | undefined;
  const isOwner = !!address && owner?.toLowerCase() === address.toLowerCase();

  const s = parseEth(start);
  const f = parseEth(floor);
  const problem =
    !start ? "" : s === null || s === 0n ? "Enter a start price above zero." : f === null ? (floor ? "Enter a floor." : "") : f > s ? "Floor must be at or below start." : f === 0n && !zeroOk ? "zero" : "";
  const ready = !!ref && isOwner && s !== null && s > 0n && f !== null && f <= s && problem === "";

  // Preview curve uses wall clock; the signed order uses chain time.
  const now = BigInt(Math.floor(Date.now() / 1000));
  const preview = s && f !== null && f <= s ? buildListing({ seller: address ?? "0x0000000000000000000000000000000000000000", nft: ref?.contract ?? "0x0000000000000000000000000000000000000000", tokenId: 0n, start: s, floor: f, startTime: now, endTime: now + BigInt(days * 86400), counter: 0n, salt: 0n }) : null;

  return (
    <>
      <div className="head">
        <h1>Sell</h1>
      </div>
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
                <input
                  id="ref"
                  placeholder="0x… / token id"
                  value={manual}
                  style={{ fontSize: 16 }}
                  onChange={(e) => {
                    setManual(e.target.value);
                    setRef(parseRef(e.target.value));
                  }}
                  autoComplete="off"
                  spellCheck={false}
                />
                <span className="hint">Contract and token id, or an OpenSea link.</span>
              </>
            )}
            {ref && nft.isPending && <span className="hint">Loading</span>}
            {ref && nft.data && (
              <span className="hint">
                {nft.data.collection} · {nft.data.name}
              </span>
            )}
            {ref && nft.isError && <span className="err">Not found.</span>}
            {ref && nft.data && address && !isOwner && <span className="err">This wallet does not own this NFT.</span>}
          </div>
        </div>

        <div>
          <div className="field">
            <label className="label" htmlFor="start">Start price</label>
            <input id="start" inputMode="decimal" placeholder="0.00" value={start} onChange={(e) => setStart(e.target.value)} autoComplete="off" />
          </div>
          <div className="field">
            <label className="label" htmlFor="floor">Floor</label>
            <input id="floor" inputMode="decimal" placeholder="0.00" value={floor} onChange={(e) => setFloor(e.target.value)} autoComplete="off" />
            {problem && problem !== "zero" && <span className="err">{problem}</span>}
            {f === 0n && (
              <label className="check">
                <input type="checkbox" checked={zeroOk} onChange={(e) => setZeroOk(e.target.checked)} />
                <span>A zero floor can sell for almost nothing.</span>
              </label>
            )}
          </div>
          <div className="field">
            <span className="label">Falls to floor over</span>
            <div className="choices">
              {DAYS.map((d) => (
                <button key={d} aria-pressed={days === d} onClick={() => setDays(d)}>
                  {d}d
                </button>
              ))}
            </div>
          </div>

          {preview && (
            <div style={{ padding: "24px 0" }}>
              <Curve c={preview} now={now} />
            </div>
          )}

          <div className="rows">
            <div className="row">
              <span className="muted">You receive at least</span>
              <span className="num">{s ? `${eth(s)} → ${eth(f ?? 0n)} WETH` : "-"}</span>
            </div>
            <div className="row">
              <span className="muted">Ends</span>
              <span>{date(now + BigInt(days * 86400))}</span>
            </div>
            <div className="row">
              <span className="muted">Buyers pay</span>
              <span className="num">{s ? `${eth(buyerTotal(s), 4, true)} ETH now` : "+0.2%"}</span>
            </div>
            <div className="row">
              <span className="muted">Offer sales</span>
              <span>0.5% fee. Any amount above your price is yours.</span>
            </div>
          </div>

          <div style={{ paddingTop: 32 }}>
            {address ? (
              ref && ready ? <Steps nft={ref.contract} tokenId={BigInt(ref.tokenId)} start={s!} floor={f!} days={days} /> : <button className="btn" disabled>List</button>
            ) : (
              <Connect />
            )}
          </div>
        </div>
      </div>
    </>
  );
}

function Connect() {
  return (
    <div className="rows">
      <div className="row">
        <span>Connect a wallet to list.</span>
        <Wallet />
      </div>
    </div>
  );
}

function Steps(p: { nft: Address; tokenId: bigint; start: bigint; floor: bigint; days: number }) {
  const router = useRouter();
  const client = usePublicClient();
  const { address } = useAccount();
  const approved = useReadContract({ address: p.nft, abi: erc721Abi, functionName: "isApprovedForAll", args: [address!, OS_CONDUIT] });
  const { writeContractAsync } = useWriteContract();
  const { signTypedDataAsync } = useSignTypedData();
  const approve = useTx(() => approved.refetch());
  const sign = useTx();
  const [saving, setSaving] = useState(false);
  const isApproved = approved.data === true;
  useEffect(() => sign.reset(), [p.start, p.floor, p.days, p.nft, p.tokenId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function list() {
    await sign.run(async () => {
      const [block, counter] = await Promise.all([
        client!.getBlock(),
        client!.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getCounter", args: [address!] }),
      ]);
      const c = buildListing({
        seller: address!,
        nft: p.nft,
        tokenId: p.tokenId,
        start: p.start,
        floor: p.floor,
        startTime: block.timestamp,
        endTime: block.timestamp + BigInt(p.days * 86400),
        counter,
        salt: BigInt("0x" + crypto.randomUUID().replaceAll("-", "")),
      });
      const signature = await signTypedDataAsync({ domain: seaportDomain, types: orderTypes, primaryType: "OrderComponents", message: c });
      setSaving(true);
      try {
        const { hash } = await getJson<{ hash: string }>("/api/listings", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ components: JSON.parse(toJson(c)), signature }),
        });
        router.push(`/l/${hash}`);
      } finally {
        setSaving(false);
      }
    });
  }

  return (
    <div className="steps">
      <div className="step" data-done={isApproved} data-active={!isApproved}>
        <span className="n">1</span>
        <div>
          <p>Approve collection</p>
          <p className="small muted" style={{ marginBottom: isApproved ? 0 : 12 }}>
            {isApproved ? "Approved." : "One approval per collection for the OpenSea conduit. The NFT stays in your wallet."}
          </p>
          {!isApproved && (
            <>
              <TxButton
                state={approve.state}
                onClick={() => approve.run(() => writeContractAsync({ address: p.nft, abi: erc721Abi, functionName: "setApprovalForAll", args: [OS_CONDUIT, true] }))}
                disabled={approved.isPending}
              >
                Approve
              </TxButton>
              <TxStatus state={approve.state} />
            </>
          )}
        </div>
      </div>
      <div className="step" data-active={isApproved}>
        <span className="n">2</span>
        <div>
          <p>Sign listing</p>
          <p className="small muted" style={{ marginBottom: 12 }}>Free. Cancel anytime onchain.</p>
          <TxButton state={saving ? { s: "pending", hash: "0x" } : sign.state} pendingLabel={saving ? "Saving" : undefined} onClick={list} disabled={!isApproved}>
            Sign listing
          </TxButton>
          {sign.state.s === "error" && <TxStatus state={sign.state} />}
        </div>
      </div>
    </div>
  );
}
