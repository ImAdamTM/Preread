import type { Metadata } from "next";
import dynamic from "next/dynamic";
import { SmoothScroll } from "./components/SmoothScroll";
import "./globals.css";

const SceneCanvas = dynamic(() => import("./components/Scene/SceneCanvas"), {
  ssr: false,
});

export const metadata: Metadata = {
  title: "Preread — Read what you love. Anywhere.",
  description:
    "Your personal article reader. Add the sites you love — full articles are ready to read before you are. On a plane, on the subway, anywhere.",
  openGraph: {
    title: "Preread",
    description: "Read what you love. Anywhere.",
    type: "website",
    url: "https://preread.app",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="scroll-smooth">
      <head>
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png" />
        <link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png" />
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link
          rel="preconnect"
          href="https://fonts.gstatic.com"
          crossOrigin="anonymous"
        />
        <link
          href="https://fonts.googleapis.com/css2?family=Gabarito:wght@400;500;600;700;800&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="bg-black text-text-primary antialiased">
        <SceneCanvas />
        <div className="relative z-10">
          <SmoothScroll>{children}</SmoothScroll>
        </div>
      </body>
    </html>
  );
}
