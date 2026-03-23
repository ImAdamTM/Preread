import Image from "next/image";
import { theme as t } from "../components/theme";

export function Footer() {
  return (
    <footer className="border-t border-white/5 py-12 px-6 bg-black">
      <div className="max-w-[1100px] mx-auto flex flex-col md:flex-row items-center justify-between gap-6">
        <div className="flex items-center gap-2">
          <Image
            src="/icon.png"
            alt=""
            width={24}
            height={24}
            className="rounded"
          />
          <span
            className="font-heading font-semibold tracking-wide"
            style={{ color: t.secondary }}
          >
            Preread
          </span>
        </div>
        <div
          className="flex flex-wrap justify-center gap-6 md:gap-8 text-sm font-medium"
          style={{ color: t.secondary }}
        >
          <a href="/support" className="hover:text-white transition-colors">
            Support
          </a>
          <a href="/privacy" className="hover:text-white transition-colors">
            Privacy Policy
          </a>
          <a href="/terms" className="hover:text-white transition-colors">
            Terms of Use
          </a>
        </div>
        <div className="text-sm" style={{ color: "rgba(136,136,153,0.5)" }}>
          © 2026 Streamline Labs LLC
        </div>
      </div>
    </footer>
  );
}
