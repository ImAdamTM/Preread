"use client";

import { useRef, useState, useEffect } from "react";
import { motion, useScroll, useTransform } from "motion/react";

type Range<T> = [T, T];

interface ResponsiveRange<T> {
  default: Range<T>;
  md?: Range<T>;
}

type PropValue<T> = Range<T> | ResponsiveRange<T>;

function isResponsive<T>(v: PropValue<T>): v is ResponsiveRange<T> {
  return typeof v === "object" && "default" in v;
}

interface ScrollScaleProps {
  children: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
  /** Scale range. Supports responsive: { default: [1.5, 1], md: [2, 1] } */
  scale?: PropValue<number>;
  /** Y offset range. Supports responsive: { default: ["20%", "0%"], md: ["50%", "0%"] } */
  y?: PropValue<number | string>;
  /** X offset range. Supports responsive. */
  x?: PropValue<number | string>;
  /** Scroll offset range for the animation. */
  offset?: [string, string];
}

function useBreakpoint(breakpoint: number = 768) {
  const [isAbove, setIsAbove] = useState(false);
  useEffect(() => {
    const mq = window.matchMedia(`(min-width: ${breakpoint}px)`);
    setIsAbove(mq.matches);
    const handler = (e: MediaQueryListEvent) => setIsAbove(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, [breakpoint]);
  return isAbove;
}

function resolveRange<T>(prop: PropValue<T> | undefined, isMd: boolean): Range<T> | undefined {
  if (!prop) return undefined;
  if (isResponsive(prop)) {
    return isMd && prop.md ? prop.md : prop.default;
  }
  return prop as Range<T>;
}

export function ScrollScale({
  children,
  className = "",
  style: styleProp,
  scale,
  y,
  x,
  offset = ["start end", "end start"],
}: ScrollScaleProps) {
  const ref = useRef(null);
  const isMd = useBreakpoint(768);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: offset as any,
  });

  const resolvedScale = resolveRange(scale, isMd);
  const resolvedY = resolveRange(y, isMd);
  const resolvedX = resolveRange(x, isMd);

  const easeOut = (t: number) => 1 - Math.pow(1 - t, 3);

  const scaleValue = resolvedScale
    ? useTransform(scrollYProgress, [0, 0.5], resolvedScale, { ease: easeOut })
    : undefined;
  const yValue = resolvedY
    ? useTransform(scrollYProgress, [0, 0.5], resolvedY, { ease: easeOut })
    : undefined;
  const xValue = resolvedX
    ? useTransform(scrollYProgress, [0, 0.5], resolvedX, { ease: easeOut })
    : undefined;

  return (
    <motion.div
      ref={ref}
      className={className}
      style={{
        ...styleProp,
        ...(scaleValue ? { scale: scaleValue } : {}),
        ...(yValue ? { y: yValue } : {}),
        ...(xValue ? { x: xValue } : {}),
      }}
    >
      {children}
    </motion.div>
  );
}
