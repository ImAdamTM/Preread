/* Settings phone: Matches SettingsView from screenshot */
import { PhoneFrame, StatusBar, SourceIcon } from './PhoneFrame';
import { ChevronLeftIcon } from './Icons';
import { theme as t } from './theme';

export function SettingsPhone() {
  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <div className="flex flex-col" style={{ background: t.bg, aspectRatio: '1/2.1' }}>
        <StatusBar />
        <div className="flex-1 px-4 pt-1 overflow-hidden">
          {/* Header */}
          <div className="flex items-center justify-between mb-2">
            <ChevronLeftIcon size={20} color={t.text} />
            <span className="text-[14px] font-semibold" style={{ color: t.text }}>Settings</span>
            <span className="w-5" />
          </div>
          <h2 className="text-[24px] font-heading mb-4" style={{ color: t.text }}>Settings</h2>

          {/* APPEARANCE */}
          <p className="text-[9px] font-semibold uppercase tracking-widest mb-2" style={{ color: t.secondary }}>Appearance</p>
          <div className="flex rounded-xl overflow-hidden mb-4 p-[3px]" style={{ background: t.card }}>
            {['System', 'Light', 'Dark'].map((mode, i) => (
              <div
                key={mode}
                className="flex-1 py-2 text-center text-[11px] font-medium rounded-lg"
                style={{
                  background: i === 2 ? `linear-gradient(90deg, ${t.accent}, ${t.purple})` : 'transparent',
                  color: i === 2 ? '#fff' : t.secondary,
                }}
              >
                {mode}
              </div>
            ))}
          </div>

          {/* READING */}
          <p className="text-[9px] font-semibold uppercase tracking-widest mb-2" style={{ color: t.secondary }}>Reading</p>
          <div className="rounded-xl p-3 mb-4" style={{ background: t.card }}>
            <div className="flex justify-between items-center mb-3" style={{ borderBottom: `1px solid ${t.border}`, paddingBottom: 10 }}>
              <span className="text-[12px]" style={{ color: t.text }}>Reading font</span>
              <span className="text-[12px]" style={{ color: t.secondary }}>System ⌄</span>
            </div>
            <div className="flex justify-between items-center mb-2">
              <span className="text-[12px]" style={{ color: t.text }}>Text size</span>
              <span className="text-[12px]" style={{ color: t.secondary }}>18pt</span>
            </div>
            <div className="flex items-center gap-2">
              <span className="text-[9px]" style={{ color: t.secondary }}>A</span>
              <div className="flex-1 h-[3px] rounded-full relative" style={{ background: 'rgba(255,255,255,0.08)' }}>
                <div className="absolute left-0 top-0 h-full w-1/2 rounded-full" style={{ background: `linear-gradient(90deg, ${t.accent}, ${t.purple})` }} />
                <div className="absolute top-1/2 w-3.5 h-3.5 bg-white rounded-full shadow" style={{ left: '50%', transform: 'translate(-50%, -50%)' }} />
              </div>
              <span className="text-[14px]" style={{ color: t.text }}>A</span>
            </div>
          </div>

          {/* SYNCING */}
          <p className="text-[9px] font-semibold uppercase tracking-widest mb-2" style={{ color: t.secondary }}>Syncing</p>
          <div className="rounded-xl p-3" style={{ background: t.card }}>
            <p className="text-[12px] mb-2" style={{ color: t.text }}>Check for new articles</p>
            <div className="flex gap-1.5 mb-3">
              {[
                { label: 'Auto', sub: 'Periodically', active: true },
                { label: 'On open', sub: 'When you launch', active: false },
                { label: 'Manual', sub: 'Only when asked', active: false },
              ].map((opt) => (
                <div
                  key={opt.label}
                  className="flex-1 py-1.5 rounded-lg text-center"
                  style={{
                    background: opt.active ? `linear-gradient(135deg, ${t.accent}, ${t.purple})` : t.raised,
                    border: opt.active ? 'none' : `1px solid rgba(255,255,255,0.05)`,
                  }}
                >
                  <div className="text-[9px] font-semibold" style={{ color: opt.active ? '#fff' : t.secondary }}>{opt.label}</div>
                  <div className="text-[7px]" style={{ color: opt.active ? 'rgba(255,255,255,0.7)' : 'rgba(136,136,153,0.5)' }}>{opt.sub}</div>
                </div>
              ))}
            </div>

            {/* Toggles */}
            <div className="flex justify-between items-center mb-2.5 py-1" style={{ borderBottom: `1px solid ${t.border}` }}>
              <div>
                <span className="text-[11px] block" style={{ color: t.text }}>WiFi only</span>
                <span className="text-[8px]" style={{ color: t.secondary }}>Only fetch when connected to WiFi</span>
              </div>
              <div className="w-[38px] h-[22px] rounded-full relative" style={{ background: 'rgba(255,255,255,0.15)' }}>
                <div className="absolute left-[2px] top-[2px] w-[18px] h-[18px] bg-white rounded-full shadow-sm" />
              </div>
            </div>
            <div className="flex justify-between items-center py-1">
              <div>
                <span className="text-[11px] block" style={{ color: t.text }}>Background refresh</span>
                <span className="text-[8px]" style={{ color: t.secondary }}>Periodically check in the background</span>
              </div>
              <div className="w-[38px] h-[22px] rounded-full relative" style={{ background: t.success }}>
                <div className="absolute right-[2px] top-[2px] w-[18px] h-[18px] bg-white rounded-full shadow-sm" />
              </div>
            </div>
          </div>

          {/* SOURCES */}
          <p className="text-[9px] font-semibold uppercase tracking-widest mb-2 mt-3 flex justify-between" style={{ color: t.secondary }}>
            Sources <span style={{ color: t.accent }}>Edit</span>
          </p>
          <div className="rounded-xl overflow-hidden" style={{ background: t.card }}>
            {['Atelier', 'Currentwave'].map((name, i) => (
              <div
                key={name}
                className="flex items-center gap-2.5 px-3 py-2.5"
                style={{ borderBottom: i === 0 ? `1px solid ${t.border}` : 'none' }}
              >
                <SourceIcon name={name} size={28} />
                <span className="text-[12px]" style={{ color: t.text }}>{name}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
