import { HomePhone } from "../components/HomePhone";
import { Reveal } from "../components/Reveal";
import { ScrollScale } from "../components/ScrollScale";
import { theme as t, accentGradientBg } from "../components/theme";
import { AppStoreButton } from "./AppStoreButton";

export function HeroSection() {
  return (
    <section className="pt-40 pb-16 md:pt-48 md:pb-24 px-6 overflow-hidden relative">
      {/* Accent glow — same technique as app: gradient image → scale up → blur → opacity → fade mask */}
      <div
        className="absolute top-0 left-0 right-0 pointer-events-none z-0 overflow-hidden"
        style={{
          height: 500,
          opacity: 0.25,
          maskImage: "linear-gradient(to bottom, white 0%, white 30%, transparent 80%)",
          WebkitMaskImage: "linear-gradient(to bottom, white 0%, white 30%, transparent 80%)",
        }}
      >
        <div
          style={{
            width: "100%",
            height: "100%",
            background: accentGradientBg,
            filter: "blur(80px)",
            transform: "scale(1.5)",
          }}
        />
      </div>
      <div className="max-w-[1100px] mx-auto text-center relative z-10">
        <Reveal>
          <h1 className="text-4xl md:text-7xl lg:text-[80px] font-heading font-bold leading-[1.1] tracking-tight mb-8">
            All the things you love to read. In one place.
          </h1>
        </Reveal>
        <Reveal delay={0.1}>
          <h2 className="text-4xl md:text-7xl lg:text-[80px] font-heading font-bold leading-[1.1] tracking-tight gradient-text">
            Ready whenever you are.
          </h2>
        </Reveal>
        <Reveal delay={0.2}>
          <p
            className="mt-8 text-xl md:text-2xl max-w-2xl mx-auto leading-relaxed"
            style={{ color: t.secondary }}
          >
            Add the sites you love. Preread makes sure there's always something
            great to read. Even without WiFi.
          </p>
          <p
            className="mt-3 text-sm max-w-sm md:max-w-md mx-auto"
            style={{ color: t.secondary }}
          >
            One-time purchase. No account required. No in-app purchases.
          </p>
        </Reveal>
        <Reveal delay={0.3}>
          <div className="mt-10 flex justify-center">
            <AppStoreButton />
          </div>
        </Reveal>
        <Reveal delay={0.4} y={50}>
          <ScrollScale
            scale={{ default: [1.7, 1], md: [2.5, 1] }}
            y={{ default: ["30%", "0%"], md: ["75%", "0%"] }}
          >
            <HomePhone />
          </ScrollScale>
        </Reveal>
      </div>
    </section>
  );
}
