import { Reveal } from "../components/Reveal";
import { IPadSplitView } from "../components/iPadSplitView";
import { theme as t } from "../components/theme";

export function OfflineSection() {
  return (
    <section className="py-32 px-6 border-t border-white/5 bg-[#050508] relative overflow-hidden">
      <div className="max-w-[1100px] mx-auto text-center relative z-10">
        <Reveal>
          <h2 className="text-4xl md:text-5xl lg:text-6xl font-heading font-bold tracking-tight mb-6">
            <span className="whitespace-nowrap">On a plane.</span>{" "}
            <span className="whitespace-nowrap">On the subway.</span>
            <br />
            <span className="gradient-text whitespace-nowrap">
              Off the grid.
            </span>
          </h2>
          <p
            className="text-xl max-w-2xl mx-auto mb-16"
            style={{ color: t.secondary }}
          >
            Preread prepares your articles while you&apos;re connected, so
            they&apos;re there when you&apos;re not. No waiting. No spinning.
            Just open and read.
          </p>
        </Reveal>

        <Reveal y={40}>
          <IPadSplitView />
        </Reveal>
      </div>
    </section>
  );
}
