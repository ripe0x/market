"use client";
import { useState, type ReactNode } from "react";
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, type Hex } from "viem";
import { usePublicClient } from "wagmi";
import { explorer, short } from "./format";

export type TxState =
  | { s: "idle" }
  | { s: "wallet" }
  | { s: "pending"; hash: Hex }
  | { s: "done"; hash?: Hex }
  | { s: "error"; message: string; hash?: Hex };

// Plain messages for reverts a user can actually hit.
const reasons: Record<string, string> = {
  NotActive: "This order is not open.",
  NotEligible: "This NFT is not eligible for that bid.",
  PriceAboveLimit: "Price moved above your limit. Try again.",
  ProceedsBelowMinimum: "The offer no longer covers the minimum.",
  Incompatible: "This offer cannot settle here.",
  CurrencyDisabled: "This currency is not enabled.",
  PaymentFailed: "Payment failed. Check your balance.",
  NftNotDelivered: "The NFT did not transfer.",
  InvalidTerms: "These terms are not valid.",
  Unauthorized: "Not allowed from this wallet.",
  StrategyFailed: "The pricing strategy reverted.",
};

export function errorMessage(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "Rejected in wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && reasons[name]) return reasons[name];
    if (/insufficient funds/i.test(e.message)) return "Not enough ETH for this and gas.";
    if (/user (rejected|denied)/i.test(e.message)) return "Rejected in wallet.";
    return e.shortMessage || "Transaction failed.";
  }
  return e instanceof Error ? e.message : "Something went wrong.";
}

/**
 * One state machine for every wallet action: confirm in wallet, pending onchain,
 * done, or a readable error. `send` returns a tx hash, or nothing for signatures.
 */
export function useTx(onDone?: () => void) {
  const client = usePublicClient();
  const [state, setState] = useState<TxState>({ s: "idle" });
  async function run(send: () => Promise<Hex | void>) {
    setState({ s: "wallet" });
    let hash: Hex | undefined;
    try {
      hash = (await send()) ?? undefined;
      if (hash) {
        setState({ s: "pending", hash });
        const receipt = await client!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Reverted onchain.");
      }
      setState({ s: "done", hash });
      onDone?.();
      return true;
    } catch (e) {
      setState({ s: "error", message: errorMessage(e), hash });
      return false;
    }
  }
  return { state, run, reset: () => setState({ s: "idle" }), busy: state.s === "wallet" || state.s === "pending" };
}

export function TxButton(props: {
  state: TxState;
  onClick: () => void;
  children: ReactNode;
  done?: ReactNode;
  pendingLabel?: ReactNode;
  disabled?: boolean;
  ghost?: boolean;
  small?: boolean;
}) {
  const { state } = props;
  const busy = state.s === "wallet" || state.s === "pending";
  const label =
    state.s === "wallet" ? "Confirm in wallet" : state.s === "pending" ? props.pendingLabel ?? "Pending" : state.s === "done" && props.done ? props.done : props.children;
  return (
    <button
      className={`btn${props.ghost ? " ghost" : ""}${props.small ? " small" : ""}`}
      onClick={props.onClick}
      disabled={props.disabled || busy || (state.s === "done" && !!props.done)}
      data-busy={busy}
      aria-live="polite"
    >
      {busy && <span className="spin" aria-hidden />}
      {label}
    </button>
  );
}

export function TxStatus({ state }: { state: TxState }) {
  const link = (hash: Hex) =>
    explorer ? (
      <a href={`${explorer}/tx/${hash}`} target="_blank" rel="noreferrer">
        {short(hash)}
      </a>
    ) : (
      <span className="num">{short(hash)}</span>
    );
  if (state.s === "pending") return <p className="status">Waiting for confirmation {link(state.hash)}</p>;
  if (state.s === "done" && state.hash) return <p className="status">Confirmed {link(state.hash)}</p>;
  if (state.s === "error")
    return (
      <p className="status err" role="alert">
        {state.message} {state.hash && link(state.hash)}
      </p>
    );
  return <p className="status" />;
}
