import { isAddress } from "viem";
import { erc721Abi } from "../../../../lib/order";
import { metadata } from "../../../../lib/nft";
import { client } from "../../../../lib/server";
import { fail, json } from "../json";

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const contract = q.get("contract") ?? "";
  const id = q.get("id") ?? "";
  if (!isAddress(contract) || !/^\d{1,78}$/.test(id)) return fail("bad nft");
  const [nft, owner] = await Promise.all([
    metadata(contract, id),
    client.readContract({ address: contract, abi: erc721Abi, functionName: "ownerOf", args: [BigInt(id)] }).catch(() => null),
  ]);
  return json({ ...nft, owner });
}
