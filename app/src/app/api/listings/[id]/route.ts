import { db, listingRow, liveListings, sync } from "../../../../../lib/server";
import { withNft } from "../../../../../lib/nft";
import { fail, json } from "../../json";

export const dynamic = "force-dynamic";

export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^\d{1,78}$/.test(id)) return fail("bad id");
  await sync();
  const row = listingRow(Number(id));
  if (!row) return fail("not found", 404);
  const [live] = await withNft(await liveListings([row]), (l) => ({ nft: l.listing.nft, tokenId: l.listing.tokenId }));
  const sale = db().prepare("select * from sales where listing_id = ?").get(Number(id)) ?? null;
  return json({ ...live, sale });
}
