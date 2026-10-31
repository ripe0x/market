import { bidRow, db, liveBids, sync } from "../../../../../lib/server";
import { withNft } from "../../../../../lib/nft";
import { fail, json } from "../../json";

export const dynamic = "force-dynamic";

export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^\d{1,78}$/.test(id)) return fail("bad id");
  await sync();
  const row = bidRow(Number(id));
  if (!row) return fail("not found", 404);
  const [live] = await withNft(await liveBids([row]), (b) => ({ nft: b.bid.nft, tokenId: b.bid.minTokenId }));
  const fills = db().prepare("select * from sales where bid_id = ? order by block desc").all(Number(id));
  return json({ ...live, sales: fills });
}
