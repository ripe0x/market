import type { Address } from "viem";
import { erc721Abi } from "./order";
import * as os from "./opensea";
import { client } from "./server";

const read = (contract: Address, fn: "name" | "tokenURI", tokenId?: bigint) =>
  client.readContract({ address: contract, abi: erc721Abi, functionName: fn, args: fn === "tokenURI" ? [tokenId!] : undefined } as any) as Promise<string>;

/** tokenURI JSON (data:, ipfs:// or http(s)), capped at 256 KB. Untrusted: only name and a vetted image survive. */
async function fromTokenUri(contract: Address, tokenId: string): Promise<os.Nft> {
  const [collection, uri] = await Promise.all([read(contract, "name").catch(() => ""), read(contract, "tokenURI", BigInt(tokenId)).catch(() => "")]);
  let meta: any = {};
  try {
    if (uri.startsWith("data:application/json;base64,")) meta = JSON.parse(Buffer.from(uri.slice(29), "base64").toString());
    else if (uri.startsWith("data:application/json")) meta = JSON.parse(decodeURIComponent(uri.slice(uri.indexOf(",") + 1)));
    else if (os.safeImage(uri)) {
      const res = await fetch(os.safeImage(uri)!, { signal: AbortSignal.timeout(5000) });
      const text = await res.text();
      if (text.length < 256_000) meta = JSON.parse(text);
    }
  } catch {}
  const name = typeof meta.name === "string" && meta.name ? meta.name.slice(0, 120) : `#${tokenId}`;
  return { contract, tokenId, name, collection: String(collection).slice(0, 120), image: os.safeImage(meta.image) };
}

// Metadata changes rarely; ten minutes bounds outside calls.
const cache = new Map<string, { at: number; nft: os.Nft }>();
export async function metadata(contract: Address, tokenId: string): Promise<os.Nft> {
  const k = `${contract.toLowerCase()}:${tokenId}`;
  const hit = cache.get(k);
  if (hit && Date.now() - hit.at < 600_000) return hit.nft;
  const nft = await os.nft(contract, tokenId).catch(() => fromTokenUri(contract, tokenId));
  cache.set(k, { at: Date.now(), nft });
  return nft;
}

export const withNft = <T extends { components: { offer: { token: Address; identifierOrCriteria: bigint }[] } }>(ls: T[]) =>
  Promise.all(ls.map(async (l) => ({ ...l, nft: await metadata(l.components.offer[0].token, l.components.offer[0].identifierOrCriteria.toString()) })));
