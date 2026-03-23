/* Step 2 phone: Home screen with sources and a preparing indicator */
import { PhoneFrame, StatusBar, SourceIcon } from './PhoneFrame';
import { ChevronDownIcon } from './Icons';
import { theme as t } from './theme';

export function PreparingPhone() {
  const sources = [
    { name: 'Currentwave', count: 9, time: '12min read' },
    { name: 'Sated', count: 7, time: '8min read' },
    { name: 'Meridian', count: 8, time: '14min read' },
    { name: 'Prism', count: 9, time: '15min read' },
    { name: 'Atelier', count: 7, time: '10min read' },
  ];

  return (
    <PhoneFrame className="w-full max-w-[260px]">
      <div className="flex flex-col relative" style={{ background: t.bg, aspectRatio: '1/2' }}>
        {/* Ambient glow */}
        <div className="absolute top-0 left-0 right-0 h-32 pointer-events-none" style={{ background: `linear-gradient(180deg, rgba(107,107,240,0.06) 0%, transparent 100%)` }} />

        <div className="relative z-10">
          <StatusBar />
          <div className="flex-1 px-4 pt-1 flex flex-col overflow-hidden">
            <h2 className="text-[20px] font-heading mb-0.5" style={{ color: t.text }}>Preread for you</h2>
            <p className="text-[10px] mb-3" style={{ color: t.secondary }}>40 articles ready</p>

            {sources.map((source, i) => (
              <div
                key={i}
                className="flex items-center gap-2.5 py-2"
                style={{ borderBottom: `1px solid ${t.border}` }}
              >
                <SourceIcon name={source.name} size={28} />
                <div className="flex-1 min-w-0">
                  <div className="text-[11px] font-semibold truncate" style={{ color: t.text }}>{source.name}</div>
                  <div className="text-[9px]" style={{ color: t.secondary }}>{source.count} articles · {source.time}</div>
                </div>
                <ChevronDownIcon size={14} color={t.accent} />
              </div>
            ))}

            {/* Preparing indicator */}
            <div className="flex flex-col items-center gap-2 mt-3 py-3 rounded-xl" style={{ background: t.card, border: `1px solid ${t.border}` }}>
              <div className="relative w-7 h-7">
                <svg className="animate-spin w-full h-full" viewBox="0 0 24 24">
                  <circle cx="12" cy="12" r="10" stroke={t.accent} strokeWidth="2" fill="none" opacity="0.2" />
                  <path fill={t.accent} opacity="0.7" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                </svg>
              </div>
              <span className="text-[10px]" style={{ color: t.secondary }}>Preparing new articles...</span>
              <div className="w-3/4 h-[3px] rounded-full overflow-hidden" style={{ background: 'rgba(255,255,255,0.08)' }}>
                <div className="h-full w-2/3 rounded-full accent-gradient" />
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
