// Watch new transfers; poll OpenSea every 5 s until it signs for the new owner. Lag = first signed time - block time.
const A = new URL("../", import.meta.url).pathname;
const os = await import(A + "lib/opensea.ts");
const { createPublicClient, http, parseAbiItem } = await import("viem");
const { mainnet } = await import("viem/chains");
const c = createPublicClient({ chain: mainnet, transport: http("https://mainnet.gateway.tenderly.co") });
const H = { accept: "application/json", "content-type": "application/json", "x-api-key": process.env.OPENSEA_API_KEY! };
const cols: [string, `0x${string}`][] = [
  ["pudgypenguins", "0xBd3531dA5CF5857e7CfAA92426877b022e612cf8"],
  ["lilpudgys", "0x524cAB2ec69124574082676e6F654a18df49A048"],
  ["boredapeyachtclub", "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"],
  ["mutant-ape-yacht-club", "0x60E4d786628Fea6478F785A6d7e704777c86a7c6"],
  ["otherdeed", "0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258"],
  ["milady", "0x5Af0D9827E0c53E4799BB226655A1de152A425a5"],
];
const offers = new Map<string, any>();
for (const [slug, nft] of cols) {
  const r = await fetch(`https://api.opensea.io/api/v2/offers/collection/${slug}`, { headers: H }).then((r) => r.json());
  const o = (r.offers ?? []).find((o: any) => os.supported(o, nft) && o.protocol_data.parameters.consideration[0].itemType === 4);
  if (o) offers.set(nft.toLowerCase(), o);
}
async function signed(offer: any, fulfiller: string, nft: string, id: string) {
  const r = await fetch("https://api.opensea.io/api/v2/offers/fulfillment_data", { method: "POST", headers: H, body: JSON.stringify({
    offer: { hash: offer.order_hash, chain: "ethereum", protocol_address: offer.protocol_address },
    fulfiller: { address: fulfiller }, consideration: { asset_contract_address: nft, token_id: id }, units_to_fill: 1 }) });
  return r.ok;
}
const transfer = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)");
let from = await c.getBlockNumber();
const watching: any[] = [];
const end = Date.now() + 8.5 * 60_000;
let lastScan = 0;
while (Date.now() < end) {
  if (Date.now() - lastScan > 6000) {
    lastScan = Date.now();
    const head = await c.getBlockNumber();
    if (head > from) {
      const logs = (await c.getLogs({ event: transfer, fromBlock: from + 1n, toBlock: head, strict: true })).filter((l: any) => l.topics.length === 4);
      from = head;
      for (const l of logs) {
        if (l.args.to === "0x0000000000000000000000000000000000000000" || l.args.from === "0x0000000000000000000000000000000000000000" || watching.length >= 6) continue;
        if (!offers.has(l.address.toLowerCase())) {
          try {
            const slug = await os.collectionSlug(l.address);
            const best = await os.bestOffer(slug, l.args.tokenId!.toString());
            offers.set(l.address.toLowerCase(), best && best.protocol_data?.parameters ? best : null);
          } catch { offers.set(l.address.toLowerCase(), null); }
        }
        if (!offers.get(l.address.toLowerCase())) continue;
        if (watching.some((w) => w.nft === l.address)) continue;
        const b = await c.getBlock({ blockNumber: l.blockNumber });
        watching.push({ nft: l.address, id: l.args.tokenId!.toString(), to: l.args.to, blockTime: Number(b.timestamp), polls: 0 });
      }
    }
  }
  for (const w of watching.filter((w) => w.lag === undefined)) {
    w.polls++;
    if (await signed(offers.get(w.nft.toLowerCase()), w.to, w.nft, w.id)) {
      w.lag = Math.floor(Date.now() / 1000) - w.blockTime;
      console.log(JSON.stringify({ nft: w.nft, id: w.id, lagSec: w.lag, polls: w.polls }));
    }
  }
  await new Promise((r) => setTimeout(r, 5000));
}
for (const w of watching.filter((w) => w.lag === undefined)) console.log(JSON.stringify({ nft: w.nft, id: w.id, unsignedAfterSec: Math.floor(Date.now() / 1000) - w.blockTime, polls: w.polls }));
console.log("watched", watching.length);
