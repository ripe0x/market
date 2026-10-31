import { formatEther, parseEther } from "viem";

/** 1.5, 0.0612. Rounds down for amounts received, up for amounts paid, so a shown figure never flatters. */
export function eth(wei: bigint | string | null | undefined, digits = 4, up = false): string {
  if (wei == null) return "-";
  const v = BigInt(wei);
  const unit = 10n ** BigInt(18 - digits);
  const s = formatEther(((v + (up ? unit - 1n : 0n)) / unit) * unit);
  return v > 0n && s === "0" ? `<${formatEther(unit)}` : s;
}

export function parseEth(s: string): bigint | null {
  if (!/^\d*\.?\d*$/.test(s.trim()) || !s.trim() || s.trim() === ".") return null;
  try {
    return parseEther(s.trim());
  } catch {
    return null;
  }
}

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

export function duration(seconds: bigint | number): string {
  let s = Math.max(0, Number(seconds));
  const d = Math.floor(s / 86400);
  s -= d * 86400;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s - h * 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m`;
  return `${Math.floor(s)}s`;
}

export const date = (seconds: bigint | number) =>
  new Date(Number(seconds) * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

export const explorer = process.env.NEXT_PUBLIC_EXPLORER ?? "https://etherscan.io";
