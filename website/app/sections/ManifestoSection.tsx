import { Reveal } from "../components/Reveal";
import { theme as t } from "../components/theme";

export function ManifestoSection() {
  return (
    <section className="py-32 px-6 border-t border-white/5">
      <div className="max-w-3xl mx-auto text-center">
        <Reveal>
          <h2 className="text-4xl md:text-5xl lg:text-6xl font-heading font-bold tracking-tight">
            Stop scrolling.
            <br />
            <span className="gradient-text">Start reading.</span>
          </h2>
        </Reveal>
        <Reveal delay={0.15}>
          <div
            className="mt-8 space-y-6 text-xl md:text-2xl leading-relaxed font-light"
            style={{ color: t.secondary }}
          >
            <p>
              Social media buries the things you care about under noise you
              didn&apos;t ask for. Preread is the opposite. A calm space
              curated around your actual interests, not someone else&apos;s algorithm.
            </p>
            <p>
              No recommendations. No algorithms. Just the words and images,
              beautifully presented.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
