"use client";

import { ScrollScale } from "./ScrollScale";

function WidgetCard({
  src,
  alt,
  style,
  borderRadius = 28,
  slideX,
  slideY = [20, 0],
}: {
  src: string;
  alt: string;
  style: React.CSSProperties;
  borderRadius?: number | string;
  slideX: [string, string];
  slideY?: [number, number];
}) {
  return (
    <ScrollScale
      className="absolute"
      x={{ default: [0, 0], md: slideX }}
      y={slideY}
      style={style}
    >
      <div
        className="overflow-hidden"
        style={{
          borderRadius: borderRadius,
          border: "3px solid rgba(50,50,50,1)",
          boxShadow: "0 8px 30px rgba(0,0,0,0.5)",
        }}
      >
        <img src={src} alt={alt} className="w-full h-full block" />
      </div>
    </ScrollScale>
  );
}

export function WidgetComposition({ className = "" }: { className?: string }) {
  return (
    <div className={`flex justify-center ${className}`}>
      <div
        className="relative scale-[0.9] md:scale-100 origin-top"
        style={{ width: 400, height: 460 }}
      >
        <WidgetCard
          src="/assets/widget-large.webp"
          alt="Large widget"
          style={{ width: 250, top: 0, left: -70, zIndex: 1 }}
          slideX={["-60%", "0%"]}
        />
        <WidgetCard
          src="/assets/widget-wide.webp"
          alt="Wide widget"
          style={{ width: 260, top: 90, right: -70, zIndex: 2 }}
          slideX={["40%", "0%"]}
          slideY={[40, 0]}
        />
        <WidgetCard
          src="/assets/widget-small.webp"
          alt="Small widget"
          style={{
            width: 190,
            bottom: 50,
            left: 50,
            zIndex: 3,
          }}
          slideX={["-30%", "0%"]}
          borderRadius={35}
          slideY={[60, 0]}
        />
      </div>
    </div>
  );
}
