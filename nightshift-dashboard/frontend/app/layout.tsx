import type { Metadata } from "next";
import { Big_Shoulders_Stencil, JetBrains_Mono, Rajdhani } from "next/font/google";
import { Suspense } from "react";
import Nav from "@/components/Nav";
import AppProvider from "@/components/AppProvider";
import GlitchIntro from "@/components/GlitchIntro";
import OwlBuddy from "@/components/OwlBuddy";
import TopBar from "@/components/TopBar";
import "./globals.css";

const rajdhani = Rajdhani({ subsets: ["latin"], weight: ["500", "600", "700"], variable: "--font-rajdhani" });
const mono = JetBrains_Mono({ subsets: ["latin"], weight: ["400", "500", "600", "700"], variable: "--font-jetbrains-mono" });
const stencil = Big_Shoulders_Stencil({ subsets: ["latin"], weight: ["700", "800"], variable: "--font-stencil" });

export const metadata: Metadata = {
  title: "NightShift",
  description: "Hands-free fault spotting and shift reports for night rounds",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`h-full antialiased ${rajdhani.variable} ${mono.variable} ${stencil.variable}`}>
      <body className="flex min-h-full flex-col">
        <AppProvider>
          <Suspense fallback={<div className="h-[73px] border-b border-zinc-800" />}>
            <Nav />
          </Suspense>
          <TopBar />
          <main className="mx-auto w-full max-w-7xl flex-1 px-6 py-8 pb-16">{children}</main>
          <Suspense fallback={null}>
            <OwlBuddy />
          </Suspense>
          <GlitchIntro />
        </AppProvider>
      </body>
    </html>
  );
}
