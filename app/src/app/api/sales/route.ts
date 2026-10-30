import { isAddress } from "viem";
import { db } from "../../../../lib/server";
import { fail, json } from "../json";

export const dynamic = "force-dynamic";

export function GET(req: Request) {
  const seller = new URL(req.url).searchParams.get("seller") ?? "";
  if (!isAddress(seller)) return fail("bad seller");
  return json(db().prepare("select * from sales where seller = ? order by block desc").all(seller.toLowerCase()));
}
