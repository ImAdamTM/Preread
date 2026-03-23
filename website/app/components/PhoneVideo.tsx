"use client";

import { useRef, useEffect } from "react";

interface PhoneVideoProps {
  src: string;
  className?: string;
}

export function PhoneVideo({ src, className = "" }: PhoneVideoProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    const container = containerRef.current;
    if (!video || !container) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          video.play().catch(() => {});
        } else {
          video.pause();
        }
      },
      { threshold: 0.3 }
    );

    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  return (
    <div
      ref={containerRef}
      className={`rounded-[32px] md:rounded-[40px] bg-black border-[8px] border-[#1c1c1e] relative text-left ${className}`}
      style={{
        aspectRatio: "497 / 1080",
        boxShadow: "0 30px 60px -15px rgba(0,0,0,0.8), 0 0 60px rgba(107,107,240,0.08)",
        isolation: "isolate",
      }}
    >
      <div
        className="absolute inset-0 overflow-hidden rounded-[24px] md:rounded-[32px]"
        style={{
          WebkitMaskImage: "-webkit-radial-gradient(white, black)",
          willChange: "transform",
          transform: "translateZ(0)",
        }}
      >
        <video
          ref={videoRef}
          src={src}
          muted
          loop
          playsInline
          preload="metadata"
          className="w-full h-full object-cover"
          style={{ imageRendering: "auto", WebkitFontSmoothing: "antialiased" }}
        />
      </div>
    </div>
  );
}
