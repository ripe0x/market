import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Footer, Header } from "../ui/parts";
import { Providers } from "../ui/providers";
import "./globals.css";

export const metadata: Metadata = { title: "Market", description: "An open escrow exchange for Ethereum NFTs. List, bid, and settle on chain." };
export const viewport: Viewport = { width: "device-width", initialScale: 1 };

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main>
            <div className="wrap">{children}</div>
          </main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
