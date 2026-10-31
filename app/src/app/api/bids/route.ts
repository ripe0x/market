import { isAddress } from "viem";
import { withNft } from "../../../../lib/nft";
import { allBidRows, bidRowsByBuyer, bidRowsByCollection, liveBids, sync } from "../../../../lib/server";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

/** Live bids. `?buyer=` filters by creator (every state); `?collection=` by NFT; otherwise active ones. */
export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const buyer = q.get("buyer");
  const collection = q.get("collection");
  if (buyer && !isAddress(buyer)) return fail("bad buyer");
  if (collection && !isAddress(collection)) return fail("bad collection");
  await sync();
  const rows = buyer ? bidRowsByBuyer(buyer) : collection ? bidRowsByCollection(collection) : allBidRows();
  const live = await liveBids(rows);
  const shown = buyer ? live : live.filter((b) => b.state === "active");
  return json(await withNft(shown, (b) => ({ nft: b.bid.nft, tokenId: b.bid.minTokenId })));
}
