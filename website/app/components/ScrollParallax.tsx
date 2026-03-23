"use client";

import { useRef } from "react";
import { motion, useScroll, useTransform } from "motion/react";

interface ScrollParallaxProps {
  children: React.ReactNode;
  className?: string;
  /** Y offset range in px. Positive = moves down as you scroll. Default: subtle float. */
  y?: [number, number];
  /** Opacity range. Default: no opacity change. */
  opacity?: [number, number];
}

/**
 * Applies a subtle parallax offset to an element as you scroll.
 * Good for floating phones slightly against their text counterparts.
 */
export function ScrollParallax({
  children,
  className = "",
  y = [20, -20],
  opacity,
}: ScrollParallaxProps) {
  const ref = useRef(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start end", "end start"],
  });

  const yValue = useTransform(scrollYProgress, [0, 1], y);
  const opacityValue = opacity
    ? useTransform(scrollYProgress, [0, 0.3, 0.7, 1], [opacity[0], 1, 1, opacity[1]])
    : undefined;

  return (
    <motion.div
      ref={ref}
      className={className}
      style={{ y: yValue, ...(opacityValue ? { opacity: opacityValue } : {}) }}
    >
      {children}
    </motion.div>
  );
}
