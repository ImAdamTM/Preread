/* Reader view phone: Matches ReaderView from screenshot */
import { PhoneFrame, StatusBar } from './PhoneFrame';
import { XMarkIcon, ShareIcon, BookmarkIcon, TextSizeIcon } from './Icons';
import { theme as t, images as img } from './theme';

export function ReaderPhone({ article, airplane = false }: {
  article?: { source: string; title: string; date: string; image: string; body: string[] };
  airplane?: boolean;
}) {
  const a = article || {
    source: 'Atelier',
    title: 'The Concrete House That Feels Like a Forest',
    date: '21 March 2026',
    image: img.concreteWide,
    body: [
      "From the street, it\u2019s a modest concrete box on a wooded hillside in southern Chile. Step inside and the walls dissolve. Floor-to-ceiling glass wraps three sides, framing the native beech forest so completely that the architecture disappears.",
      "The architect, Mar\u00eda Paz Undurraga, describes the design as \u201Ca frame for what was already there.\u201D The concrete is board-formed, bearing the grain of the timber moulds, so even the solid walls carry the texture of the forest.",
    ],
  };

  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <div className="flex flex-col" style={{ background: t.bg, aspectRatio: '1/2.1' }}>
        <StatusBar airplane={airplane} />
        <div className="flex-1 px-4 pt-1 flex flex-col overflow-hidden">
          {/* Toolbar — matches ReaderView toolbar: X, gradient square, spacer, share, bookmark, Aa */}
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center gap-3">
              <XMarkIcon size={16} color={t.text} />
              <div className="w-5 h-5 rounded accent-gradient" />
            </div>
            <div className="flex items-center gap-4">
              <ShareIcon size={15} color={t.secondary} />
              <BookmarkIcon size={15} color={t.secondary} />
              <TextSizeIcon size={15} color={t.secondary} />
            </div>
          </div>

          {/* Article title */}
          <h3 className="text-[20px] font-heading font-bold leading-snug mb-1.5" style={{ color: t.text }}>
            {a.title}
          </h3>
          <p className="text-[11px] mb-3" style={{ color: t.secondary }}>{a.source} · {a.date}</p>

          {/* Hero image */}
          <img src={a.image} alt="" className="w-full h-28 object-cover rounded-xl mb-3" />

          {/* Body text */}
          <div className="space-y-2.5 text-[12px] leading-relaxed" style={{ color: '#c8c8d8' }}>
            {a.body.map((p, i) => (
              <p key={i}>{p}</p>
            ))}
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
