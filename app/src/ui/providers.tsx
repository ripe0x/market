"use client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { createConfig, http, WagmiProvider } from "wagmi";
import { mainnet } from "wagmi/chains";
import { injected, mock } from "wagmi/connectors";
import type { Address } from "viem";

export const rpc = process.env.NEXT_PUBLIC_RPC_URL ?? "https://mainnet.gateway.tenderly.co";
// Mock connectors forward requests to the chain's default RPC, so it must be ours.
const chain = { ...mainnet, rpcUrls: { default: { http: [rpc] } } };

// Local fork only: anvil's unlocked accounts appear as wallets.
export const devAccounts = /^https?:\/\/(127\.0\.0\.1|localhost)/.test(rpc)
  ? ((process.env.NEXT_PUBLIC_DEV_ACCOUNTS ?? "").split(",").filter(Boolean) as Address[])
  : [];

export const config = createConfig({
  chains: [chain],
  connectors: [injected(), ...devAccounts.map((a) => mock({ accounts: [a], features: { reconnect: true } }))],
  transports: { [mainnet.id]: http(rpc) },
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchOnWindowFocus: true, retry: 1 } } }));
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
