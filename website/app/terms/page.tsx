import Image from "next/image";
import { theme as t } from "../components/theme";
import { ObfuscatedEmail } from "../components/ObfuscatedEmail";

export const metadata = {
  title: "Terms of Use — Preread",
};

export default function TermsPage() {
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
          <h1 className="text-4xl md:text-5xl font-heading font-bold mb-4">Terms of Use</h1>
          <p className="text-sm mb-12" style={{ color: t.secondary }}>Last updated: 23 March 2026</p>

          <div className="space-y-8 text-[15px] leading-relaxed" style={{ color: "#c8c8d8" }}>
            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Acceptance of terms</h2>
              <p>
                By downloading, installing, or using Preread (&ldquo;the App&rdquo;), you agree to be bound by these
                Terms of Use. If you do not agree to these terms, do not use the App. These terms are in addition
                to Apple&apos;s standard Licensed Application End User License Agreement (EULA).
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Description of service</h2>
              <p>
                Preread is a personal article reader that allows you to add website sources, prepare articles for
                offline reading, and read content on your device. The App fetches publicly available content from
                third-party websites on your behalf and stores it locally on your device for personal, non-commercial use.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>License</h2>
              <p>
                Streamline Labs LLC grants you a limited, non-exclusive, non-transferable, revocable license to use
                the App on any Apple device that you own or control, subject to these terms and the Apple Media
                Services Terms and Conditions.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Third-party content</h2>
              <p>
                The App displays content from third-party websites that you choose to subscribe to. Streamline Labs
                does not own, control, or endorse any third-party content accessed through the App. You are
                responsible for ensuring your use of third-party content complies with applicable laws and the
                respective publisher&apos;s terms of use.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Acceptable use</h2>
              <p>You agree to use the App only for personal, non-commercial purposes. You agree not to:</p>
              <ul className="list-disc pl-6 mt-3 space-y-2">
                <li>Redistribute, republish, or commercially exploit content obtained through the App</li>
                <li>Use the App to systematically download or archive content beyond personal reading</li>
                <li>Reverse engineer, decompile, or disassemble any part of the App</li>
                <li>Use the App in any manner that could damage, disable, or impair third-party servers or networks</li>
              </ul>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Service availability and limitations</h2>
              <p>
                Preread prepares articles for offline reading using background refresh and on-demand fetching. The
                availability, completeness, and timeliness of cached content depends on factors outside our control,
                including but not limited to:
              </p>
              <ul className="list-disc pl-6 mt-3 space-y-2">
                <li>Your device&apos;s network connectivity and available storage</li>
                <li>The number and frequency of sources you subscribe to</li>
                <li>iOS background task scheduling and system resource allocation</li>
                <li>Third-party publisher server availability and content structure</li>
              </ul>
              <p className="mt-3">
                Preread makes reasonable efforts to keep your reading library current but does not guarantee that
                all articles from all sources will be available at any given time. The App is provided on an
                &ldquo;as is&rdquo; and &ldquo;as available&rdquo; basis.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Disclaimer of warranties</h2>
              <p>
                To the maximum extent permitted by applicable law, Streamline Labs LLC disclaims all warranties,
                express or implied, including but not limited to implied warranties of merchantability, fitness for
                a particular purpose, and non-infringement. We do not warrant that the App will be uninterrupted,
                error-free, or free of harmful components.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Limitation of liability</h2>
              <p>
                To the maximum extent permitted by applicable law, Streamline Labs LLC shall not be liable for any
                indirect, incidental, special, consequential, or punitive damages, or any loss of data, use, or
                profits, arising out of or related to your use of the App, regardless of the theory of liability.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Changes to these terms</h2>
              <p>
                We reserve the right to modify these terms at any time. Changes will be posted on this page with an
                updated revision date. Your continued use of the App after any changes constitutes acceptance of the
                updated terms.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Governing law</h2>
              <p>
                These terms shall be governed by and construed in accordance with the laws of the United States,
                without regard to conflict of law principles.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-heading font-semibold mb-3" style={{ color: t.text }}>Contact</h2>
              <p>
                If you have any questions about these terms, please contact us at{" "}
                <ObfuscatedEmail user="legal" domain="streamlinelabs.io" />
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
