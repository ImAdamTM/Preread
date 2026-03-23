/* Exact dark-mode colors from Preread Theme.swift */
export const theme = {
  bg: '#000000',
  sheet: '#0A0A0B',
  card: '#111118',
  raised: '#1E1E22',
  text: '#F0F0FF',
  secondary: '#888899',
  border: 'rgba(255,255,255,0.07)',
  borderProminent: 'rgba(255,255,255,0.22)',
  accent: '#6B6BF0',
  purple: '#A855F7',
  success: '#34C759',
} as const;

/* Source icon brand colors (matching demo-feed icons) */
export const sourceColors: Record<string, { bg: string; text: string }> = {
  Currentwave: { bg: '#6366f1', text: '#fff' },
  Sated: { bg: '#f59e0b', text: '#fff' },
  Meridian: { bg: '#0ea5e9', text: '#fff' },
  Prism: { bg: '#8b5cf6', text: '#fff' },
  Atelier: { bg: '#ef4444', text: '#fff' },
};

/* Local webp images (self-hosted from Unsplash, resized) */
export const images = {
  pasta: '/img/pasta.webp',
  sourdough: '/img/sourdough.webp',
  concrete: '/img/concrete.webp',
  concreteWide: '/img/concrete-wide.webp',
  joinery: '/img/joinery.webp',
  courtyard: '/img/courtyard.webp',
  brutalism: '/img/brutalism.webp',
  kyoto: '/img/kyoto-wide.webp',
  kyotoThumb: '/img/kyoto-thumb.webp',
  forest: '/img/forest.webp',
  stars: '/img/stars.webp',
  library: '/img/library.webp',
  keyboard: '/img/keyboard.webp',
  octopus: '/img/octopus.webp',
  fjord: '/img/fjord.webp',
};

/**
 * Matches the app's makeAccentGradientImage():
 * 64x64 diagonal gradient from Teal (#22D3EE) to Purple (#A855F7),
 * drawn from (0,0) to (w,h) = 135deg.
 */
export const accentGradientBg = "linear-gradient(135deg, #22D3EE, #A855F7)";
