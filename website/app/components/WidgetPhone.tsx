/* Lock screen with widget: Shows Preread widget on lock screen */
import Image from 'next/image';
import { PhoneFrame, StatusBar, SourceIcon } from './PhoneFrame';
import { theme as t, images as img } from './theme';

export function WidgetPhone() {
  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <div className="relative" style={{ aspectRatio: '1/2.1' }}>
        {/* Wallpaper gradient */}
        <div className="absolute inset-0 bg-gradient-to-br from-[#0a0a1a] via-[#151030] to-[#1a0830]" />
        <div className="absolute inset-0 bg-black/20" />

        <div className="relative z-10 h-full flex flex-col">
          <StatusBar />
          <div className="px-5 pt-2 flex flex-col flex-1">
            {/* Lock screen time */}
            <div className="text-center mb-8">
              <div className="text-[10px] font-semibold tracking-wider" style={{ color: t.text }}>SATURDAY, MARCH 22</div>
              <div className="text-[48px] font-bold tracking-tighter leading-none mt-0.5" style={{ color: t.text }}>9:41</div>
            </div>

            {/* Widget — matches PrereadWidget medium size */}
            <div
              className="rounded-2xl p-3.5 mt-auto mb-12 border border-white/10"
              style={{ background: 'rgba(17,17,24,0.75)', backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)' }}
            >
              <div className="flex items-center justify-between mb-2.5">
                <div className="flex items-center gap-1.5 text-[10px] font-semibold" style={{ color: 'rgba(255,255,255,0.8)' }}>
                  <Image src="/icon.png" alt="" width={13} height={13} className="rounded" />
                  PREREAD
                </div>
                <span className="text-[10px]" style={{ color: 'rgba(255,255,255,0.4)' }}>3 new</span>
              </div>

              {[
                { title: 'The Trees That Talk to Each Other Underground', source: 'Prism', time: '3m ago', thumb: img.forest },
                { title: 'Morning Eggs, Five Ways', source: 'Sated', time: '12m ago', thumb: img.pasta },
                { title: 'Why the Night Sky Is Disappearing', source: 'Prism', time: '1h ago', thumb: img.stars },
              ].map((item, i) => (
                <div key={i}>
                  {i > 0 && <div className="h-px bg-white/5 my-2" />}
                  <div className="flex gap-2.5">
                    <img src={item.thumb} alt="" className="w-10 h-10 rounded-lg object-cover flex-shrink-0" />
                    <div className="flex-1 min-w-0">
                      <div className="text-[11px] font-medium leading-tight line-clamp-2" style={{ color: t.text }}>{item.title}</div>
                      <div className="text-[9px] mt-0.5" style={{ color: 'rgba(255,255,255,0.4)' }}>{item.source} · {item.time}</div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
