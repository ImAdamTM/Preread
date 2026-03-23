"use client";

import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "motion/react";
import { PhoneFrame } from "./PhoneFrame";

interface PhoneCyclerProps {
  images: string[];
  interval?: number;
  className?: string;
}

export function PhoneCycler({ images, interval = 4000, className = "" }: PhoneCyclerProps) {
  const [index, setIndex] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setIndex((prev) => (prev + 1) % images.length);
    }, interval);
    return () => clearInterval(timer);
  }, [images.length, interval]);

  return (
    <PhoneFrame className={`relative ${className}`}>
      <div className="relative w-full" style={{ aspectRatio: "1260 / 2736" }}>
        <AnimatePresence>
          <motion.img
            key={index}
            src={images[index]}
            alt=""
            className="absolute inset-0 w-full h-full block"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.6, ease: "easeInOut" }}
          />
        </AnimatePresence>
      </div>
    </PhoneFrame>
  );
}
