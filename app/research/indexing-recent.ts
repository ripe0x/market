// For recent ERC721 transfers in collections with a live collection offer, ask OpenSea to sign
// for the new owner and the previous owner, and relate the answer to the transfer's age.
const A = new URL("../", import.meta.url).pathname;
const os = await import(A + "lib/opensea.ts");
const { createPublicClient, http, parseAbiItem } = await import("viem");
const { mainnet } = await import("viem/chains");
const c = createPublicClient({ chain: mainnet, transport: http("https://mainnet.gateway.tenderly.co") });
const H = { accept: "application/json", "content-type": "application/json", "x-api-key": process.env.OPENSEA_API_KEY! };
const cols: [string, `0x${string}`][] = [
  ["milady", "0x5Af0D9827E0c53E4799BB226655A1de152A425a5"],
  ["pudgypenguins", "0xBd3531dA5CF5857e7CfAA92426877b022e612cf8"],
  ["otherdeed", "0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258"],
  ["mutant-ape-yacht-club", "0x60E4d786628Fea6478F785A6d7e704777c86a7c6"],
  ["lilpudgys", "0x524cAB2ec69124574082676e6F654a18df49A048"],
  ["boredapeyachtclub", "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"],
];
async function ask(offer: any, fulfiller: string, nft: string, id: string) {
  const r = await fetch("https://api.opensea.io/api/v2/offers/fulfillment_data", { method: "POST", headers: H, body: JSON.stringify({
    offer: { hash: offer.order_hash, chain: "ethereum", protocol_address: offer.protocol_address },
    fulfiller: { address: fulfiller }, consideration: { asset_contract_address: nft, token_id: id }, units_to_fill: 1 }) });
  if (r.ok) return "signed";
  const t = await r.text(); return (t.match(/"errors" : \[ "([^"]+)"/) ?? [, `${r.status}`])[1];
}
const head = await c.getBlock();
const transfer = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)");
const out: any[] = [];
for (const [slug, nft] of cols) {
  const r = await fetch(`https://api.opensea.io/api/v2/offers/collection/${slug}`, { headers: H }).then((r) => r.json());
  const offer = (r.offers ?? []).find((o: any) => os.supported(o, nft) && o.protocol_data.parameters.consideration[0].itemType === 4);
  if (!offer) continue;
  const logs = await c.getLogs({ address: nft, event: transfer, fromBlock: head.number - 600n, toBlock: head.number });
  const last = new Map<string, any>();
  for (const l of logs) last.set(l.args.tokenId!.toString(), l);
  for (const [id, l] of [...last].slice(-6)) {
    if (l.args.to === "0x0000000000000000000000000000000000000000") continue;
    const b = await c.getBlock({ blockNumber: l.blockNumber });
    const now = Math.floor(Date.now() / 1000);
    const row = { slug, id, ageSec: now - Number(b.timestamp), newOwner: await ask(offer, l.args.to, nft, id), prevOwner: await ask(offer, l.args.from, nft, id) };
    out.push(row); console.log(JSON.stringify(row));
    await new Promise((r) => setTimeout(r, 300));
  }
}
