import type { Metadata } from "next";
import { Suspense } from "react";
import Nav from "@/components/Nav";
import AppProvider from "@/components/AppProvider";
import TopBar from "@/components/TopBar";
import "./globals.css";

export const metadata: Metadata = {
  title: "NightShift",
  description: "Hands-free fault spotting and shift reports for night rounds",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="flex min-h-full flex-col">
        <AppProvider>
          <Suspense fallback={<div className="h-[73px] border-b border-zinc-800" />}>
            <Nav />
          </Suspense>
          <TopBar />
          <main className="mx-auto w-full max-w-7xl flex-1 px-6 py-8">{children}</main>
        </AppProvider>
      </body>
    </html>
  );
}
