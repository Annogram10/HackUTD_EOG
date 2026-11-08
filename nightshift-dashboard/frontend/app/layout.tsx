import type { Metadata } from "next";
import { IBM_Plex_Mono, IBM_Plex_Sans } from "next/font/google";
import { Suspense } from "react";
import Nav from "@/components/Nav";
import AppProvider from "@/components/AppProvider";
import GlitchIntro from "@/components/GlitchIntro";
import OwlCorner from "@/components/OwlCorner";
import TopBar from "@/components/TopBar";
import "./globals.css";

const plexSans = IBM_Plex_Sans({ subsets: ["latin"], weight: ["400", "500", "600", "700"], variable: "--font-plex-sans" });
const plexMono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500", "600"], variable: "--font-plex-mono" });

export const metadata: Metadata = {
  title: "NightShift",
  description: "Hands-free fault spotting and shift reports for night rounds",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`h-full antialiased ${plexSans.variable} ${plexMono.variable}`}>
      <body className="flex min-h-full flex-col">
        <AppProvider>
          <Suspense fallback={<div className="h-[73px] border-b border-zinc-800" />}>
            <Nav />
          </Suspense>
          <TopBar />
          <main className="mx-auto w-full max-w-7xl flex-1 px-6 py-8 pb-48">{children}</main>
          <OwlCorner />
          <GlitchIntro />
        </AppProvider>
      </body>
    </html>
  );
}
