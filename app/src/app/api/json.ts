import { NextResponse } from "next/server";

/** JSON response with bigints as decimal strings. */
export const json = (data: unknown, status = 200) =>
  new NextResponse(JSON.stringify(data, (_, v) => (typeof v === "bigint" ? v.toString() : v)), {
    status,
    headers: { "content-type": "application/json" },
  });

export const fail = (error: string, status = 400) => json({ error }, status);
