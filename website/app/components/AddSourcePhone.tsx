/* Step 1 phone: Matches AddSourceSheet from screenshot */
import { PhoneFrame, StatusBar } from './PhoneFrame';
import { ClipboardIcon, SparklesIcon } from './Icons';
import { theme as t } from './theme';

export function AddSourcePhone() {
  return (
    <PhoneFrame className="w-full max-w-[260px]">
      <div className="flex flex-col" style={{ background: t.bg, aspectRatio: '1/2' }}>
        <StatusBar />
        <div className="flex-1 px-5 pt-1 flex flex-col">
          {/* Sheet handle */}
          <div className="flex justify-center mb-4">
            <div className="w-9 h-1 rounded-full" style={{ background: 'rgba(255,255,255,0.2)' }} />
          </div>

          <h3 className="text-[20px] font-heading font-semibold mb-0.5" style={{ color: t.text }}>Add a source</h3>
          <p className="text-[12px] mb-4" style={{ color: t.secondary }}>Search or paste a link</p>

          {/* Search field — matches the real text field with clipboard button */}
          <div
            className="flex items-center rounded-xl px-3 py-2.5 mb-5"
            style={{ background: t.card, border: `1px solid ${t.border}` }}
          >
            <span className="text-[13px] flex-1" style={{ color: t.secondary }}>Search or paste a link...</span>
            <ClipboardIcon size={16} color={t.secondary} />
          </div>

          {/* Buttons — matches the gradient Find Articles + outline Save Single Page */}
          <div className="flex gap-3 mb-5">
            <div
              className="flex-1 py-3.5 rounded-[14px] text-center text-[13px] font-semibold text-white"
              style={{ background: `linear-gradient(90deg, ${t.accent}, ${t.purple})` }}
            >
              Find articles
            </div>
            <div
              className="flex-1 py-3.5 rounded-[14px] text-center text-[13px] font-semibold"
              style={{ background: t.raised, color: t.text, border: `1px solid ${t.border}` }}
            >
              Save single page
            </div>
          </div>

          {/* Browse topics gradient text link */}
          <div className="text-center pt-1">
            <span
              className="text-[13px] font-semibold inline-flex items-center gap-1"
              style={{
                background: `linear-gradient(90deg, ${t.accent}, ${t.purple})`,
                WebkitBackgroundClip: 'text',
                WebkitTextFillColor: 'transparent',
              }}
            >
              Browse topics <SparklesIcon size={12} color={t.purple} />
            </span>
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
