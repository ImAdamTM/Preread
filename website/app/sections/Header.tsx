"use client";

import Image from "next/image";
import { motion } from "motion/react";

export function Header() {
  return (
    <motion.header
      className="w-full fixed top-0 z-50 bg-black/80 backdrop-blur-md border-b border-white/5"
      style={{ transform: "translateY(-100%)" }}
      initial={{ y: "-100%" }}
      animate={{ y: 0 }}
      transition={{ duration: 0.6, delay: 0, ease: [0.22, 1, 0.36, 1] }}
    >
      <div className="max-w-[1100px] mx-auto px-6 h-16 flex items-center justify-between">
        <div className="flex items-center gap-2">
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
        </div>
        <a
          href="#download"
          className="text-sm font-semibold gradient-text hover:opacity-80 transition-opacity"
        >
          Get the app
        </a>
      </div>
    </motion.header>
  );
}
