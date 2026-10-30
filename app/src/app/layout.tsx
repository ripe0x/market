import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Footer, Header } from "../ui/parts";
import { Providers } from "../ui/providers";
import "./globals.css";

export const metadata: Metadata = { title: "Market", description: "Sell an NFT at a price that falls until it sells." };
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
