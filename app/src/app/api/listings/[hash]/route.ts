import { db, listing, liveState } from "../../../../../lib/server";
import { withNft } from "../../../../../lib/nft";
import { fail, json } from "../../json";

export const dynamic = "force-dynamic";

export async function GET(_: Request, { params }: { params: Promise<{ hash: string }> }) {
  const { hash } = await params;
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) return fail("bad hash");
  const row = listing(hash);
  if (!row) return fail("not found", 404);
  const [live] = await withNft(await liveState([row]));
  const sale = db().prepare("select * from sales where hash = ?").get(hash.toLowerCase());
  return json({ ...live, sale: sale ?? null });
}
