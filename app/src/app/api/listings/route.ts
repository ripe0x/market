import { isAddress, type Hex } from "viem";
import { fromJson, listingProblem, orderTypes, seaportAbi, seaportDomain, SEAPORT, erc721Abi, toJson } from "../../../../lib/order";
import { allListings, client, db, listingsBySeller, liveState } from "../../../../lib/server";
import { withNft } from "../../../../lib/nft";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  const seller = new URL(req.url).searchParams.get("seller");
  if (seller && !isAddress(seller)) return fail("bad seller");
  const live = await liveState(seller ? listingsBySeller(seller) : allListings());
  const shown = seller ? live : live.filter((l) => l.state === "active" || l.state === "scheduled");
  return json(await withNft(shown));
}

/**
 * Store a signed listing. The Seaport signature is the authentication: it must
 * recover the offerer (EOA or ERC-1271), match the current counter, and the
 * offerer must own the NFT now.
 */
export async function POST(req: Request) {
  let c, signature: Hex;
  try {
    const body = await req.json();
    c = fromJson(JSON.stringify(body.components));
    signature = body.signature;
    if (!/^0x[0-9a-fA-F]+$/.test(signature) || !isAddress(c.offerer) || !isAddress(c.offer[0]?.token)) throw 0;
  } catch {
    return fail("malformed listing");
  }
  const problem = listingProblem(c);
  if (problem) return fail(problem);
  const now = (await client.getBlock()).timestamp;
  if (c.endTime <= now) return fail("already ended");
  if (c.endTime - c.startTime > 366n * 86400n) return fail("longer than a year");

  const [counter, hash, owner] = await Promise.all([
    client.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getCounter", args: [c.offerer] }),
    client.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getOrderHash", args: [c] }),
    client.readContract({ address: c.offer[0].token, abi: erc721Abi, functionName: "ownerOf", args: [c.offer[0].identifierOrCriteria] }).catch(() => null),
  ]);
  if (counter !== c.counter) return fail("stale counter");
  if (owner?.toLowerCase() !== c.offerer.toLowerCase()) return fail("seller does not own this NFT");
  const valid = await client
    .verifyTypedData({ address: c.offerer, domain: seaportDomain, types: orderTypes, primaryType: "OrderComponents", message: c, signature })
    .catch(() => false);
  if (!valid) return fail("bad signature");

  db()
    .prepare("insert or ignore into listings values (?,?,?,?,?,?,?)")
    .run(hash.toLowerCase(), c.offerer.toLowerCase(), c.offer[0].token.toLowerCase(), c.offer[0].identifierOrCriteria.toString(), toJson(c), signature, Date.now());
  return json({ hash: hash.toLowerCase() }, 201);
}
