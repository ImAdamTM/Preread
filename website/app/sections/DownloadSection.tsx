import Image from "next/image";
import dynamic from "next/dynamic";
import { AppStoreButton } from "./AppStoreButton";

const FlipFluidCanvas = dynamic(
  () =>
    import("../components/FlipFluid/FlipFluid").then((m) => m.FlipFluidCanvas),
  { ssr: false },
);

export function DownloadSection() {
  return (
    <section
      id="download"
      className="py-56 px-6 relative overflow-hidden min-h-[600px] border-t border-b border-white/10"
      style={{
        background:
          "linear-gradient(135deg, #0f0d2e 0%, #1a1040 50%, #150a30 100%)",
      }}
    >
      {/* FLIP fluid particle simulation */}
      <FlipFluidCanvas className="absolute inset-0 z-0" />

      {/* Content sits on top */}
      <div
        className="max-w-[1100px] mx-auto text-center flex flex-col items-center relative z-10"
        style={{ filter: "drop-shadow(0 4px 10px rgba(0,0,0,0.8))" }}
      >
        <div className="relative w-28 h-28 mb-10">
          <div className="absolute inset-0 blur-3xl opacity-30 animate-glow rounded-full accent-gradient" />
          <Image
            src="/icon.png"
            alt="Preread"
            width={112}
            height={112}
            className="relative rounded-3xl shadow-2xl"
          />
        </div>
        <h2 className="text-4xl md:text-5xl font-heading font-bold mb-4">
          Preread is ready <span className="gradient-text">when you are.</span>
        </h2>
        <p className="mb-8 text-base text-white">
          One-time purchase. No account required. No in-app purchases.
        </p>
        <AppStoreButton />
      </div>
    </section>
  );
}
