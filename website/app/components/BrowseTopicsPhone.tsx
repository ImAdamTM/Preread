/* Browse Topics phone: Matches the discover category list from screenshot */
import { PhoneFrame, StatusBar } from './PhoneFrame';
import { ChevronLeftIcon, ChevronRightIcon } from './Icons';
import { theme as t } from './theme';

const categories = [
  { icon: '🌍', name: 'World News', count: 4 },
  { icon: '💻', name: 'Tech', count: 19 },
  { icon: '🤖', name: 'AI', count: 14 },
  { icon: '🔬', name: 'Science', count: 10 },
  { icon: '🚀', name: 'Space', count: 9 },
  { icon: '📊', name: 'Business & Finance', count: 15 },
  { icon: '⚽', name: 'Sports', count: 18 },
  { icon: '❤️', name: 'Health & Wellness', count: 11 },
  { icon: '💪', name: 'Fitness', count: 13 },
  { icon: '🎬', name: 'Film & TV', count: 12 },
  { icon: '🎵', name: 'Music', count: 16 },
  { icon: '🎮', name: 'Gaming', count: 16 },
  { icon: '📺', name: 'Anime', count: 17 },
  { icon: '⭐', name: 'Celebrity & Pop Culture', count: 22 },
  { icon: '🍴', name: 'Food', count: 16 },
  { icon: '✈️', name: 'Travel', count: 4 },
  { icon: '📚', name: 'Books', count: 6 },
];

export function BrowseTopicsPhone() {
  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <div className="flex flex-col" style={{ background: t.bg, aspectRatio: '1/2.1' }}>
        <StatusBar />
        <div className="flex-1 px-5 pt-1 overflow-hidden">
          {/* Back chevron */}
          <div className="mb-3">
            <ChevronLeftIcon size={22} color={t.text} />
          </div>

          <h2 className="text-[24px] font-heading mb-4" style={{ color: t.text }}>Browse topics</h2>

          <div className="flex flex-col">
            {categories.map((cat, i) => (
              <div
                key={i}
                className="flex items-center py-[9px]"
                style={{ borderBottom: i < categories.length - 1 ? `1px solid ${t.border}` : 'none' }}
              >
                <span className="text-[14px] w-7 text-center">{cat.icon}</span>
                <span className="text-[13px] flex-1 ml-2" style={{ color: t.text }}>{cat.name}</span>
                <span
                  className="text-[11px] mr-2 px-2 py-0.5 rounded-full"
                  style={{ color: t.secondary }}
                >
                  {cat.count}
                </span>
                <ChevronRightIcon size={12} color={t.secondary} />
              </div>
            ))}
          </div>
        </div>
      </div>
    </PhoneFrame>
  );
}
