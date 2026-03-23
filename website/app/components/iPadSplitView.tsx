/* iPad split view mockup: Matches actual iPad screenshot layout */
import { Logo } from "./Logo";
import { SidebarIcon, ChevronLeftIcon, ShareIcon, BookmarkIcon, TextSizeIcon, RefreshIcon, GearIcon } from "./Icons";
import { theme as t, images as img } from "./theme";

const sidebarArticles = [
  { title: "Twelve Hours in Kyoto Without a P...", time: "2 days ago · 4 min read", thumb: img.kyotoThumb, active: true },
  { title: "The Norwegian Coast by Slow Ferry", time: "4 days ago · 1 min read", thumb: img.fjord, active: false },
  { title: "Mexico City\u2019s Best Neighbourhood Is...", time: "Mar 15, 2026 · 1 min read", thumb: img.concrete, active: false },
  { title: "A Week on the Amalfi Coast, Off-...", time: "Mar 12, 2026 · 1 min read", thumb: img.courtyard, active: false },
];

export function IPadSplitView() {
  return (
    <div className="ipad-scale-wrapper" style={{ margin: '0 auto' }}>
    <div
      className="w-[850px] h-[550px] rounded-3xl border border-white/10 shadow-2xl relative overflow-hidden flex text-left"
      style={{ background: t.bg, boxShadow: "0 30px 60px -15px rgba(0,0,0,0.8), 0 0 60px rgba(107,107,240,0.06)" }}
    >
      {/* ── Sidebar ── */}
      <div
        className="flex w-[260px] border-r flex-col flex-shrink-0 overflow-hidden relative"
        style={{ borderColor: t.border, background: t.bg }}
      >
        {/* Blurred favicon background — matches SourceHeroView.blurredBackground */}
        <div
          className="absolute top-0 left-0 right-0 pointer-events-none z-0 overflow-hidden"
          style={{
            height: 200,
            opacity: 0.3,
            maskImage: 'linear-gradient(to bottom, white 0%, white 40%, transparent 100%)',
            WebkitMaskImage: 'linear-gradient(to bottom, white 0%, white 40%, transparent 100%)',
          }}
        >
          <img
            src="/meridian-icon.png"
            alt=""
            className="w-full h-full object-cover"
            style={{ filter: 'blur(40px)', transform: 'scale(3)' }}
          />
        </div>

        {/* Sidebar toolbar */}
        <div className="flex items-center justify-between px-4 py-3 relative z-10">
          <div className="flex items-center gap-3">
            <SidebarIcon size={16} color={t.secondary} />
            <ChevronLeftIcon size={16} color={t.accent} />
          </div>
          <div className="flex items-center gap-3">
            <ShareIcon size={14} color={t.secondary} />
            <RefreshIcon size={14} color={t.secondary} />
            <GearIcon size={14} color={t.secondary} />
          </div>
        </div>

        {/* Source header */}
        <div className="px-4 py-3 relative z-10">
          <div className="flex items-center gap-2.5 mb-1">
            <img src="/meridian-icon.png" alt="" className="w-7 h-7 rounded-lg" />
            <div>
              <div className="text-[13px] font-semibold" style={{ color: t.text }}>Meridian</div>
              <div className="text-[9px]" style={{ color: t.secondary }}>8 articles · 10min read · Updated 3m ago</div>
            </div>
          </div>
        </div>

        {/* Hero card in sidebar */}
        <div className="mx-4 mb-3 relative rounded-xl overflow-hidden z-10" style={{ height: 120 }}>
          <img src={img.kyoto} alt="" className="w-full h-full object-cover" />
          <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/20 to-transparent" />
          <div className="absolute bottom-2.5 left-2.5 right-2.5">
            <h4 className="text-[12px] font-semibold leading-tight text-white">Twelve Hours in Kyoto Without a Plan</h4>
            <p className="text-[8px] text-white/60 mt-0.5">2 days ago · 4 min read</p>
          </div>
        </div>

        {/* All articles header */}
        <div className="flex items-center justify-between px-4 mb-1">
          <span className="text-[12px] font-semibold" style={{ color: t.text }}>All articles</span>
          <span className="text-[10px]" style={{ color: t.secondary }}>≡</span>
        </div>

        {/* Article list */}
        <div className="flex-1 overflow-hidden px-4">
          {sidebarArticles.map((item, i) => (
            <div
              key={i}
              className="flex items-center gap-2.5 py-2"
              style={{
                borderBottom: i < sidebarArticles.length - 1 ? `1px solid ${t.border}` : "none",
                background: item.active ? "rgba(107,107,240,0.08)" : "transparent",
                margin: item.active ? "0 -16px" : "0",
                padding: item.active ? "8px 16px" : undefined,
                borderRadius: item.active ? "8px" : undefined,
              }}
            >
              <img src={item.thumb} alt="" className="w-10 h-10 rounded-lg object-cover flex-shrink-0" />
              <div className="flex-1 min-w-0">
                <div className="text-[11px] font-medium leading-tight line-clamp-2" style={{ color: t.text }}>
                  {item.title}
                </div>
                <div className="text-[8px] mt-0.5" style={{ color: t.secondary }}>
                  {item.time}
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* ── Detail / Reader pane ── */}
      <div className="flex-1 flex flex-col overflow-hidden relative" style={{ background: t.bg }}>
        {/* Blurred article thumbnail background — matches app reader */}
        <div
          className="absolute top-0 left-0 right-0 pointer-events-none z-0 overflow-hidden"
          style={{
            height: 200,
            opacity: 0.2,
            maskImage: 'linear-gradient(to bottom, white 0%, white 30%, transparent 100%)',
            WebkitMaskImage: 'linear-gradient(to bottom, white 0%, white 30%, transparent 100%)',
          }}
        >
          <img
            src={img.kyoto}
            alt=""
            className="w-full h-full object-cover"
            style={{ filter: 'blur(40px)', transform: 'scale(1.5)' }}
          />
        </div>

        {/* Detail toolbar */}
        <div className="flex items-center justify-between px-5 py-3 relative z-10">
          <div className="flex items-center gap-2">
            <img src="/meridian-icon.png" alt="" className="w-5 h-5 rounded" />
            <span className="text-[13px] font-semibold" style={{ color: t.text }}>Meridian</span>
          </div>
          <div className="flex items-center gap-4">
            <ShareIcon size={14} color={t.secondary} />
            <BookmarkIcon size={14} color={t.secondary} />
            <TextSizeIcon size={14} color={t.secondary} />
          </div>
        </div>

        {/* Article content */}
        <div className="flex-1 px-8 py-6 overflow-hidden relative z-10">
          <div className="max-w-lg">
            <h3
              className="text-[24px] font-heading font-bold leading-[1.15] mb-2"
              style={{ color: t.text }}
            >
              Twelve Hours in Kyoto Without a Plan
            </h3>
            <p className="text-[12px] mb-4" style={{ color: t.secondary }}>
              Meridian · 20 March 2026
            </p>

            <img src={img.kyoto} alt="" className="w-full h-44 object-cover rounded-xl mb-5" />

            <div className="space-y-4 text-[14px] leading-[1.8]" style={{ color: "#c8c8d8" }}>
              <p>
                The best day I&apos;ve spent in Kyoto started with getting lost. I walked out of a small
                hotel near Gion with no map, no itinerary, and a vague intention to find breakfast.
                Three hours later I was sitting cross-legged on a tatami floor eating grilled fish and
                pickled vegetables while rain tapped against a paper screen.
              </p>
              <p>
                The architect, María Paz Undurraga, describes the design as &ldquo;a frame for what was
                already there.&rdquo; The concrete is board-formed, bearing the grain of the timber
                moulds, so even the solid walls carry the texture of the forest.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    </div>
  );
}
