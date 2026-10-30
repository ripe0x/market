import { isAddress } from "viem";
import * as os from "../../../../lib/opensea";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

/** Wallet NFTs need an OpenSea API key; without one the app asks for contract and token id. */
export async function GET(req: Request) {
  const owner = new URL(req.url).searchParams.get("owner") ?? "";
  if (!isAddress(owner)) return fail("bad owner");
  if (!os.apiKey) return fail("no index", 501);
  return json(await os.ownedNfts(owner).catch(() => []));
}
