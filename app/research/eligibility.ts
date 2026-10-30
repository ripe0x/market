const A = new URL("../", import.meta.url).pathname;
const os = await import(A + "lib/opensea.ts");
const { createPublicClient, http, parseAbi } = await import("viem");
const { mainnet } = await import("viem/chains");
const c = createPublicClient({ chain: mainnet, transport: http("https://mainnet.gateway.tenderly.co"), batch: { multicall: true } });
const KEY = process.env.OPENSEA_API_KEY!;
const H = { accept: "application/json", "x-api-key": KEY };
const cols: [string, string][] = [
  ["milady", "0x5Af0D9827E0c53E4799BB226655A1de152A425a5"],
  ["pudgypenguins", "0xBd3531dA5CF5857e7CfAA92426877b022e612cf8"],
  ["otherdeed", "0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258"],
  ["boredapeyachtclub", "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"],
  ["mutant-ape-yacht-club", "0x60E4d786628Fea6478F785A6d7e704777c86a7c6"],
  ["lilpudgys", "0x524cAB2ec69124574082676e6F654a18df49A048"],
];
const abi = parseAbi(["function ownerOf(uint256) view returns (address)"]);
const head = await c.getBlockNumber();
async function created(a: string) {
  let lo = 0n, hi = head;
  while (lo < hi) { const mid = (lo + hi) / 2n; const code = await c.getCode({ address: a as any, blockNumber: mid }).catch(() => "0x"); if (code && code !== "0x") hi = mid; else lo = mid + 1n; }
  return lo;
}
const kind = (code: string) => code.startsWith("0x363d3d373d3d3d363d73") ? "EIP-1167 clone" : code.includes("a619486e") && code.length < 400 ? "Safe proxy" : code.length < 400 ? "small proxy" : "contract";
const rows: any[] = [];
for (const [slug, nft] of cols) {
  const r = await fetch(`https://api.opensea.io/api/v2/offers/collection/${slug}`, { headers: H }).then((r) => r.json());
  const offer = (r.offers ?? []).find((o: any) => os.supported(o, nft as any) && o.protocol_data.parameters.consideration[0].itemType === 4);
  if (!offer) { console.log(slug, "no supported collection offer"); continue; }
  const ids = Array.from({ length: 600 }, (_, i) => BigInt(i + 1));
  const owners = await Promise.all(ids.map((id) => c.readContract({ address: nft as any, abi, functionName: "ownerOf", args: [id] }).catch(() => null)));
  const seen = new Set<string>(); let n = 0;
  for (let i = 0; i < ids.length && n < 8; i++) {
    const o = owners[i]; if (!o || seen.has(o)) continue; seen.add(o);
    const code = await c.getCode({ address: o }); if (!code || code === "0x" || code.startsWith("0xef0100")) continue;
    n++;
    let res: string;
    try { await os.fulfillment(offer, o as any, nft as any, ids[i].toString()); res = "signed"; }
    catch (e) { res = (String(e).match(/"errors" : \[ "([^"]+)"/) ?? [, String(e).slice(0, 80)])[1]!; }
    rows.push({ slug, id: ids[i].toString(), holder: o, kind: kind(code), bytes: (code.length - 2) / 2, created: (await created(o)).toString(), res });
    console.log(JSON.stringify(rows.at(-1)));
    await new Promise((r) => setTimeout(r, 400));
  }
}
console.log("head", head.toString());
console.log("summary", JSON.stringify(rows.reduce((m: any, r) => ((m[r.res] = (m[r.res] ?? 0) + 1), m), {})));
