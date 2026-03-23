import { theme as t } from './theme';

export function PhoneFrame({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return (
    <div
      className={`rounded-[32px] md:rounded-[40px] bg-black border-[8px] border-[#1c1c1e] relative overflow-hidden text-left ${className}`}
      style={{ boxShadow: '0 30px 60px -15px rgba(0,0,0,0.8), 0 0 60px rgba(107,107,240,0.08)' }}
    >
      {children}
    </div>
  );
}

export function StatusBar({ airplane = false }: { airplane?: boolean }) {
  return (
    <div className="h-14 flex items-center justify-between px-7 pt-3 relative z-20">
      <span className="text-[13px] font-semibold" style={{ color: t.text }}>9:41</span>
      <div className="flex items-center gap-1.5 text-[13px]" style={{ color: t.text }}>
        {airplane ? (
          <span className="text-xs">✈️</span>
        ) : (
          <>
            <svg width="17" height="12" viewBox="0 0 17 12" fill="currentColor"><rect x="0" y="5" width="3" height="7" rx="1"/><rect x="4.5" y="3" width="3" height="9" rx="1"/><rect x="9" y="1" width="3" height="11" rx="1"/><rect x="13.5" y="0" width="3" height="12" rx="1"/></svg>
            <svg width="16" height="12" viewBox="0 0 16 12" fill="currentColor"><path d="M8 3.6c1.8 0 3.4.7 4.6 1.9l1.2-1.2C12.2 2.7 10.2 1.8 8 1.8S3.8 2.7 2.2 4.3l1.2 1.2C4.6 4.3 6.2 3.6 8 3.6zM8 7.2c1 0 1.9.4 2.6 1l1.2-1.2C10.7 5.9 9.4 5.4 8 5.4S5.3 5.9 4.2 7l1.2 1.2c.7-.6 1.6-1 2.6-1zM9.2 9.8c0 .7-.5 1.2-1.2 1.2s-1.2-.5-1.2-1.2.5-1.2 1.2-1.2 1.2.5 1.2 1.2z"/></svg>
          </>
        )}
        <svg width="25" height="12" viewBox="0 0 25 12" fill="currentColor"><rect x="0" y="1" width="21" height="10" rx="2" stroke="currentColor" strokeWidth="1" fill="none"/><rect x="22" y="4" width="2" height="4" rx="0.5"/><rect x="1.5" y="2.5" width="18" height="7" rx="1"/></svg>
      </div>
    </div>
  );
}

export function SourceIcon({ name, size = 28 }: { name: string; size?: number }) {
  const colors: Record<string, string> = {
    Currentwave: '#6366f1',
    Sated: '#f59e0b',
    Meridian: '#0ea5e9',
    Prism: '#8b5cf6',
    Atelier: '#ef4444',
  };
  return (
    <div
      className="rounded-lg flex items-center justify-center font-heading font-bold flex-shrink-0"
      style={{ width: size, height: size, backgroundColor: colors[name] || '#333', color: '#fff', fontSize: size * 0.45 }}
    >
      {name[0]}
    </div>
  );
}
