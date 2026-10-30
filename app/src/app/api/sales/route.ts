import { isAddress } from "viem";
import { db, sync } from "../../../../lib/server";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

/** Sales for a `?seller=` or `?buyer=`. */
export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const seller = q.get("seller");
  const buyer = q.get("buyer");
  if (seller && !isAddress(seller)) return fail("bad seller");
  if (buyer && !isAddress(buyer)) return fail("bad buyer");
  if (!seller && !buyer) return fail("seller or buyer required");
  await sync();
  const col = seller ? "seller" : "buyer";
  const who = (seller ?? buyer)!.toLowerCase();
  return json(db().prepare(`select * from sales where ${col} = ? order by block desc`).all(who));
}
