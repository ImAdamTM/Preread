import { HomePhone } from "../components/HomePhone";
import { Reveal } from "../components/Reveal";
import { ScrollScale } from "../components/ScrollScale";
import { theme as t } from "../components/theme";
import { AppStoreButton } from "./AppStoreButton";

export function HeroSection() {
  return (
    <section className="pt-40 pb-16 md:pt-48 md:pb-24 px-6 overflow-hidden relative">
      <div className="absolute top-1/4 left-1/2 -translate-x-1/2 w-[600px] h-[600px] rounded-full blur-[120px] opacity-10 pointer-events-none accent-gradient" />
      <div className="max-w-[1100px] mx-auto text-center relative z-10">
        <Reveal>
          <h1 className="text-5xl md:text-7xl lg:text-[80px] font-heading font-bold leading-[1.1] tracking-tight mb-8">
            All the things you love to read. In one place.
          </h1>
        </Reveal>
        <Reveal delay={0.1}>
          <h2 className="text-5xl md:text-7xl lg:text-[80px] font-heading font-bold leading-[1.1] tracking-tight gradient-text">
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
          <p className="mt-3 text-sm" style={{ color: t.secondary }}>
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
            scale={{ default: [1.3, 1], md: [2.5, 1] }}
            y={{ default: ["20%", "0%"], md: ["75%", "0%"] }}
          >
            <HomePhone />
          </ScrollScale>
        </Reveal>
      </div>
    </section>
  );
}
