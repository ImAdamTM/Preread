/* Hero phone: Matches SourcesListView home screen */
import { PhoneFrame, StatusBar } from "./PhoneFrame";
import { Logo } from "./Logo";
import { PlusIcon, RefreshIcon, GearIcon, ChevronDownIcon } from "./Icons";
import { theme as t, images as img, accentGradientBg } from "./theme";

export function HomePhone() {
  const articles = [
    {
      title: "The Concrete House That Feels Like a Forest",
      time: "Yesterday · 1 min read",
      thumb: img.concrete,
      unread: true,
    },
    {
      title: "What Japanese Joinery Can Teach Modern Builders",
      time: "4 days ago · 1 min read",
      thumb: img.joinery,
      unread: true,
    },
    {
      title: "The Return of the Courtyard Home",
      time: "Mar 15, 2026 · 1 min read",
      thumb: img.courtyard,
      unread: false,
    },
    {
      title: "Why Brutalism Looks Better With Age",
      time: "Mar 12, 2026 · 5 min read",
      thumb: img.brutalism,
      unread: false,
    },
    {
      title: "Designing a Room Around One Good Chair",
      time: "Mar 9, 2026 · 1 min read",
      thumb: img.concrete,
      unread: false,
    },
    {
      title: "The Library That Bends With the Wind",
      time: "Mar 6, 2026 · 1 min read",
      thumb: img.joinery,
      unread: false,
    },
  ];

  return (
    <PhoneFrame className="mt-16 mx-auto w-full max-w-[320px] md:max-w-[360px]">
      <div
        className="flex flex-col relative overflow-hidden"
        style={{ background: t.bg, aspectRatio: "1/2.15" }}
      >
        {/*
          Background blur — matches app exactly:
          1. makeAccentGradientImage(): 64x64 diagonal gradient from Teal to Purple
          2. Resized to fill width, 140px height
          3. blur(radius: 40)
          4. opacity(0.3)
          5. Masked: solid 0→40%, fade to transparent at 100%
        */}
        <div
          className="absolute top-0 left-0 right-0 pointer-events-none z-0 overflow-hidden"
          style={{
            height: 140,
            opacity: 0.3,
            maskImage: "linear-gradient(to bottom, white 0%, white 40%, transparent 100%)",
            WebkitMaskImage: "linear-gradient(to bottom, white 0%, white 40%, transparent 100%)",
          }}
        >
          <div
            style={{
              width: "100%",
              height: "100%",
              background: accentGradientBg,
              filter: "blur(40px)",
              transform: "scale(1.5)",
            }}
          />
        </div>

        <div className="relative z-10">
          <StatusBar />

          <div className="flex-1 px-4 pb-4 flex flex-col gap-2">
            {/* Nav bar — glass pill */}
            <div className="flex items-center justify-between mb-0.5">
              <div
                className="w-8 h-8 rounded-full flex items-center justify-center"
                style={{
                  background: "rgba(255,255,255,0.08)",
                  backdropFilter: "blur(12px)",
                  WebkitBackdropFilter: "blur(12px)",
                  border: "1px solid rgba(255,255,255,0.12)",
                  boxShadow:
                    "inset 0 1px 0 rgba(255,255,255,0.08), 0 1px 3px rgba(0,0,0,0.3)",
                }}
              >
                <Logo size={14} color="rgba(240,240,255,0.85)" />
              </div>
              <div
                className="flex items-center gap-3 px-3 py-1.5 rounded-full"
                style={{
                  background: "rgba(255,255,255,0.08)",
                  backdropFilter: "blur(12px)",
                  WebkitBackdropFilter: "blur(12px)",
                  border: "1px solid rgba(255,255,255,0.12)",
                  boxShadow:
                    "inset 0 1px 0 rgba(255,255,255,0.08), 0 1px 3px rgba(0,0,0,0.3)",
                }}
              >
                <PlusIcon size={15} color="rgba(240,240,255,0.85)" />
                <RefreshIcon size={14} color="rgba(240,240,255,0.85)" />
                <GearIcon size={14} color="rgba(240,240,255,0.85)" />
              </div>
            </div>

            {/* Title — tighter spacing */}
            <div className="mb-1">
              <h2
                className="text-[26px] font-heading leading-tight"
                style={{ color: t.text, lineHeight: 1 }}
              >
                Preread for you
              </h2>
              <p className="text-[11px]" style={{ color: t.secondary }}>
                25 articles ready
              </p>
            </div>

            {/* Hero carousel card */}
            <div
              className="relative rounded-2xl overflow-hidden"
              style={{ height: 150 }}
            >
              <img
                src={img.pasta}
                alt=""
                className="w-full h-full object-cover"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/20 to-transparent" />
              <div className="absolute top-3 left-3">
                <div
                  className="flex items-center gap-1.5 px-2 py-1 rounded-lg"
                  style={{
                    background: "rgba(0,0,0,0.5)",
                    backdropFilter: "blur(8px)",
                  }}
                >
                  <div
                    className="w-4 h-4 rounded flex items-center justify-center text-[8px] font-bold text-white"
                    style={{ background: "#f59e0b" }}
                  >
                    S
                  </div>
                  <span className="text-[10px] font-semibold text-white">
                    Sated
                  </span>
                </div>
              </div>
              <div className="absolute bottom-3 left-3 right-3">
                <h3 className="text-[15px] font-heading font-semibold leading-tight text-white">
                  The Simplest Pasta You&apos;ll Make All Spring
                </h3>
                <p className="text-[10px] text-white/60 mt-1">
                  Yesterday · 1 min read
                </p>
              </div>
            </div>

            {/* Source section header — with real Atelier icon */}
            <div className="flex items-center gap-2.5 mt-1">
              <img
                src="/atelier-icon.webp"
                alt="Atelier"
                className="w-[34px] h-[34px] rounded-lg"
              />
              <div className="flex-1">
                <div
                  className="text-[14px] font-semibold"
                  style={{ color: t.text }}
                >
                  Atelier
                </div>
                <div className="text-[11px]" style={{ color: t.secondary }}>
                  7 articles · 12min read
                </div>
              </div>
              <ChevronDownIcon size={16} color={t.accent} />
            </div>

            {/* Article rows with unread dots — overflow hidden */}
            <div className="flex flex-col overflow-hidden">
              {articles.map((article, i) => (
                <div
                  key={i}
                  className="flex items-center gap-2.5 py-2"
                  style={{
                    borderBottom:
                      i < articles.length - 1
                        ? `1px solid ${t.border}`
                        : "none",
                  }}
                >
                  <img
                    src={article.thumb}
                    alt=""
                    className="w-[50px] h-[50px] rounded-xl object-cover flex-shrink-0"
                  />
                  <div className="flex-1 min-w-0">
                    <h4
                      className="text-[12px] font-semibold leading-tight line-clamp-2"
                      style={{ color: t.text }}
                    >
                      {article.title}
                    </h4>
                    <p
                      className="text-[10px] mt-0.5"
                      style={{ color: t.secondary }}
                    >
                      {article.time}
                    </p>
                  </div>
                  {/* Unread dot — 6px circle, accent when unread, faded when read */}
                  <div
                    className="w-[6px] h-[6px] rounded-full flex-shrink-0"
                    style={{
                      background: article.unread
                        ? t.accent
                        : "rgba(136,136,153,0.2)",
                    }}
                  />
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
