// OpenSea API is a discovery surface only. Every order it returns is re-checked
// against signed data and simulated onchain before use.
import type { Address, Hex } from "viem";
import { SEAPORT, WETH } from "./order";

const BASE = "https://api.opensea.io/api/v2";
export const apiKey = process.env.OPENSEA_API_KEY;

async function get(path: string, init?: RequestInit): Promise<any> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(BASE + path, {
      ...init,
      headers: { accept: "application/json", "content-type": "application/json", ...(apiKey ? { "x-api-key": apiKey } : {}), ...init?.headers },
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 429 && attempt < 3) {
      await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt + Number(res.headers.get("retry-after") ?? 0) * 1000));
      continue;
    }
    if (!res.ok) throw new Error(`OpenSea ${res.status} ${path.split("?")[0]}: ${(await res.text()).slice(0, 300)}`);
    return res.json();
  }
}

export type Nft = { contract: Address; tokenId: string; name: string; collection: string; image: string | null };

/** Only http(s) images are passed through; ipfs is mapped to a gateway. Everything else is dropped. */
export function safeImage(url: unknown): string | null {
  if (typeof url !== "string") return null;
  if (url.startsWith("ipfs://")) return "https://ipfs.io/ipfs/" + url.slice(7).replace(/^ipfs\//, "");
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

const clean = (s: unknown, max = 120) => (typeof s === "string" ? s.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, max) : "");

export async function nft(contract: Address, tokenId: string): Promise<Nft> {
  const { nft: n } = await get(`/chain/ethereum/contract/${contract}/nfts/${tokenId}`);
  return {
    contract,
    tokenId,
    name: clean(n.name) || `#${tokenId}`,
    collection: clean(n.collection),
    image: safeImage(n.display_image_url ?? n.image_url),
  };
}

/** Needs an API key. */
export async function ownedNfts(owner: Address): Promise<Nft[]> {
  const { nfts } = await get(`/chain/ethereum/account/${owner}/nfts?limit=100`);
  return (nfts as any[])
    .filter((n) => n.token_standard === "erc721" && !n.is_disabled)
    .map((n) => ({
      contract: n.contract,
      tokenId: n.identifier,
      name: clean(n.name) || `#${n.identifier}`,
      collection: clean(n.collection),
      image: safeImage(n.display_image_url ?? n.image_url),
    }));
}

export const collectionSlug = async (contract: Address): Promise<string> => (await get(`/chain/ethereum/contract/${contract}`)).collection;

type RawOffer = { order_hash: Hex; protocol_address: Address; protocol_data: { parameters: any } };

/** Best item or collection offer OpenSea reports for this NFT. Headline only; net is computed later. */
export async function bestOffer(slug: string, tokenId: string): Promise<RawOffer | null> {
  try {
    const o = await get(`/offers/collection/${slug}/nfts/${tokenId}/best`);
    return o?.order_hash ? o : null;
  } catch (e) {
    if (String(e).includes(" 404 ")) return null;
    throw e;
  }
}

/** Seaport 1.6, WETH-paying, single-item offers only. Trait offers need proofs we do not support. */
export function supported(o: RawOffer, nftContract: Address): boolean {
  const p = o.protocol_data.parameters;
  if (o.protocol_address.toLowerCase() !== SEAPORT.toLowerCase()) return false;
  if (p.offer.length !== 1 || p.offer[0].itemType !== 1 || p.offer[0].token.toLowerCase() !== WETH.toLowerCase()) return false;
  const nftItem = p.consideration[0];
  if (nftItem.token.toLowerCase() !== nftContract.toLowerCase()) return false;
  // 2 = ERC721 item offer; 4 = ERC721_WITH_CRITERIA where criteria 0 means any token (collection offer).
  if (!(nftItem.itemType === 2 || (nftItem.itemType === 4 && BigInt(nftItem.identifierOrCriteria) === 0n))) return false;
  return p.consideration.slice(1).every((c: any) => c.itemType === 1 && c.token.toLowerCase() === WETH.toLowerCase());
}

/**
 * Raw fulfillment input_data OpenSea signs for `fulfiller` (the Market contract),
 * carrying the zone extraData that names it. Either a `fulfillAdvancedOrder` or a
 * `matchAdvancedOrders` shape; the keeper normalizes both. Needs an API key.
 */
export async function fulfillmentData(o: RawOffer, fulfiller: Address, nftContract: Address, tokenId: string): Promise<any> {
  const r = await get("/offers/fulfillment_data", {
    method: "POST",
    body: JSON.stringify({
      offer: { hash: o.order_hash, chain: "ethereum", protocol_address: o.protocol_address },
      fulfiller: { address: fulfiller },
      consideration: { asset_contract_address: nftContract, token_id: tokenId },
      units_to_fill: 1,
    }),
  });
  const input = r.fulfillment_data.transaction.input_data;
  if (!input.advancedOrder && !input.orders?.length) throw new Error(`unexpected fulfillment shape: ${r.fulfillment_data.transaction.function}`);
  return input;
}
