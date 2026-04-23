import Image from "next/image";
import { ObfuscatedEmail } from "../components/ObfuscatedEmail";
import { theme as t } from "../components/theme";

export const metadata = {
  title: "Support — Preread",
};

const faqs = [
  {
    q: "How do I add a source?",
    a: "Tap the + button on the home screen, then either paste a website URL or browse topics to find something new. Preread will find the feed automatically.",
  },
  {
    q: "Does Preread use mobile data?",
    a: "By default, yes. You can enable WiFi-only mode in Settings to restrict background fetching to WiFi connections.",
  },
  {
    q: "How do I get articles on my Apple Watch?",
    a: "Articles sync automatically to your watch when your iPhone updates. Make sure both devices are nearby and the Preread watch app is installed.",
  },
  {
    q: "Is there a subscription?",
    a: "No. Preread is a one-time purchase with no in-app purchases, no account required, and no recurring fees.",
  },
  {
    q: "Why are some articles showing as failed?",
    a: "Some websites block automated access or have unusual page structures. You can tap a failed article to retry, or try adding the source in full-page mode from its settings.",
  },
];

export default function SupportPage() {
  return (
    <>
      <header className="w-full fixed top-0 z-50 bg-black/80 backdrop-blur-md border-b border-white/5">
        <div className="max-w-[1100px] mx-auto px-6 h-16 flex items-center justify-between">
          <a href="/" className="flex items-center gap-2">
            <Image
              src="/icon.png"
              alt="Preread"
              width={32}
              height={32}
              className="rounded-lg"
            />
            <span className="font-heading font-semibold text-xl tracking-tight">
              Preread
            </span>
          </a>
          <a
            href="/#download"
            className="text-sm font-semibold gradient-text hover:opacity-80 transition-opacity"
          >
            Get the app
          </a>
        </div>
      </header>

      <main className="pt-32 pb-24 px-6">
        <div className="max-w-[680px] mx-auto">
          <h1 className="text-4xl md:text-5xl font-heading font-bold mb-4">
            Support
          </h1>
          <p className="text-lg mb-12" style={{ color: t.secondary }}>
            Have a question or running into an issue? Check below or get in
            touch.
          </p>

          <div className="space-y-6 mb-16">
            {faqs.map((faq, i) => (
              <div key={i} className="border-b border-white/5 pb-6">
                <h2
                  className="text-[17px] font-semibold mb-2"
                  style={{ color: t.text }}
                >
                  {faq.q}
                </h2>
                <p
                  className="text-[15px] leading-relaxed"
                  style={{ color: "#c8c8d8" }}
                >
                  {faq.a}
                </p>
              </div>
            ))}
          </div>

          <section>
            <h2
              className="text-xl font-heading font-semibold mb-3"
              style={{ color: t.text }}
            >
              Still need help?
            </h2>
            <p
              className="text-[15px] leading-relaxed"
              style={{ color: "#c8c8d8" }}
            >
              Send us an email at{" "}
              <ObfuscatedEmail user="hello" domain="streamlinelabs.io" /> and
              we'll get back to you as soon as we can.
            </p>
          </section>

          <div
            className="pt-8 mt-8 border-t border-white/5 text-sm"
            style={{ color: t.secondary }}
          >
            <p>Streamline Labs LLC</p>
          </div>
        </div>
      </main>
    </>
  );
}
