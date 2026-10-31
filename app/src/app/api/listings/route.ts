import { isAddress } from "viem";
import { withNft } from "../../../../lib/nft";
import { allListingRows, listingRowsBySeller, liveListings, sync } from "../../../../lib/server";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

/** Live listings. `?seller=` shows every state for that seller; otherwise only active ones. */
export async function GET(req: Request) {
  const seller = new URL(req.url).searchParams.get("seller");
  if (seller && !isAddress(seller)) return fail("bad seller");
  await sync();
  const live = await liveListings(seller ? listingRowsBySeller(seller) : allListingRows());
  const shown = seller ? live : live.filter((l) => l.state === "active");
  return json(await withNft(shown, (l) => ({ nft: l.listing.nft, tokenId: l.listing.tokenId })));
}
