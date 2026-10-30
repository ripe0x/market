import { MARKET, meta } from "../../../../lib/server";
import { json } from "../json";

export const dynamic = "force-dynamic";

export function GET() {
  const seen = meta("keeper_seen");
  return json({ market: MARKET, matching: meta("matching") ?? "off", keeperSeen: seen ? Number(seen) : null });
}
