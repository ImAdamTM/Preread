import Image from "next/image";
import { theme as t } from "../components/theme";
import { ObfuscatedEmail } from "../components/ObfuscatedEmail";

export const metadata = {
  title: "Privacy Policy — Preread",
};

export default function PrivacyPage() {
  return (
    <>
      <header className="w-full fixed top-0 z-50 bg-black/80 backdrop-blur-md border-b border-white/5">
        <div className="max-w-[1100px] mx-auto px-6 h-16 flex items-center justify-between">
          <a href="/" className="flex items-center gap-2">
            <Image src="/icon.png" alt="Preread" width={32} height={32} className="rounded-lg" />
            <span className="font-heading font-semibold text-xl tracking-tight">Preread</span>
          </a>
          <a href="/#download" className="text-sm font-semibold gradient-text hover:opacity-80 transition-opacity">
            Get the app
          </a>
        </div>
      </header>

      <main className="pt-32 pb-24 px-6">
        <div className="max-w-[680px] mx-auto">
          <h1 className="text-4xl md:text-5xl font-heading font-bold mb-4">Privacy Policy</h1>
          <p className="text-sm mb-12" style={{ color: t.secondary }}>Last updated: 23 March 2026</p>

          <div className="space-y-8 text-[15px] leading-relaxed" style={{ color: "#c8c8d8" }}>
            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>The short version</h2>
              <p>
                Preread does not collect, store, or transmit any personal data. The app runs entirely on your device.
                There are no accounts, no analytics, and no tracking. Your reading habits are yours alone.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Data we collect</h2>
              <p>None. Preread does not collect any personal information, usage data, or device identifiers.</p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Data stored on your device</h2>
              <p>
                Preread stores the following data locally on your device to provide its core functionality:
              </p>
              <ul className="list-disc pl-6 mt-3 space-y-2">
                <li>The list of sources (feeds) you have added</li>
                <li>Cached article content, images, and associated assets for offline reading</li>
                <li>Your preferences and settings (appearance, font, sync frequency)</li>
                <li>Read/unread status and saved articles</li>
              </ul>
              <p className="mt-3">
                This data never leaves your device. It is not transmitted to us or any third party. If you delete
                the app, all locally stored data is removed.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Network requests</h2>
              <p>
                Preread makes network requests to fetch content from the websites and feeds you have added. These
                requests go directly from your device to the publisher&apos;s servers. We do not route, proxy, or
                intercept these requests. We have no visibility into what you read or which sources you subscribe to.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Third-party content</h2>
              <p>
                Articles and images displayed within Preread are fetched from third-party websites chosen by you.
                These websites may have their own privacy policies and data practices. Preread has no control over
                the content or privacy practices of these third-party sites.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Apple services</h2>
              <p>
                Preread uses standard Apple platform features including Background App Refresh, Widgets, Watch
                Connectivity, and Siri Shortcuts. These features are managed by Apple and subject to Apple&apos;s
                privacy policy. We do not receive any data from these services.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Children&apos;s privacy</h2>
              <p>
                Preread does not knowingly collect any information from anyone, including children under the age of 13.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Service availability</h2>
              <p>
                Preread prepares articles for offline reading using background refresh and on-demand fetching. The
                availability and timeliness of cached content depends on factors including your device&apos;s network
                connectivity, the number of sources you subscribe to, iOS background task scheduling, and the
                availability of third-party publisher servers. Preread makes reasonable efforts to keep your reading
                library current but does not guarantee that all articles will be available at any given time.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Changes to this policy</h2>
              <p>
                We may update this privacy policy from time to time. Any changes will be posted on this page with
                an updated revision date. Your continued use of Preread after any changes constitutes acceptance of
                the updated policy.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Contact</h2>
              <p>
                If you have any questions about this privacy policy, please contact us at{" "}
                <ObfuscatedEmail user="hello" domain="streamlinelabs.io" />
              </p>
            </section>

            <div className="pt-8 border-t border-white/5 text-sm" style={{ color: t.secondary }}>
              <p>Streamline Labs LLC</p>
            </div>
          </div>
        </div>
      </main>
    </>
  );
}
