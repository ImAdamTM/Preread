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

/* Unsplash thumbnails from demo feeds (small crops for phone mockups) */
export const images = {
  pasta: 'https://images.unsplash.com/photo-1621996346565-e3dbc646d9a9?w=400&h=400&fit=crop',
  sourdough: 'https://images.unsplash.com/photo-1585478259715-876acc5be8eb?w=400&h=400&fit=crop',
  concrete: 'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=400&h=400&fit=crop',
  concreteWide: 'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=1200',
  joinery: 'https://images.unsplash.com/photo-1528360983277-13d401cdc186?w=400&h=400&fit=crop',
  courtyard: 'https://images.unsplash.com/photo-1600607687939-ce8a6c25118c?w=400&h=400&fit=crop',
  brutalism: 'https://images.unsplash.com/photo-1479839672679-a46483c0e7c8?w=400&h=400&fit=crop',
  kyoto: 'https://images.unsplash.com/photo-1493976040374-85c8e12f0c0e?w=1200',
  kyotoThumb: 'https://images.unsplash.com/photo-1493976040374-85c8e12f0c0e?w=400&h=400&fit=crop',
  forest: 'https://images.unsplash.com/photo-1448375240586-882707db888b?w=400&h=400&fit=crop',
  stars: 'https://images.unsplash.com/photo-1519681393784-d120267933ba?w=400&h=400&fit=crop',
  library: 'https://images.unsplash.com/photo-1507842217343-583bb7270b66?w=400&h=400&fit=crop',
  keyboard: 'https://images.unsplash.com/photo-1618384887929-16ec33fab9ef?w=400&h=400&fit=crop',
  octopus: 'https://images.unsplash.com/photo-1545671913-b89ac1b4ac10?w=400&h=400&fit=crop',
  fjord: 'https://images.unsplash.com/photo-1520769669658-f07657f5a307?w=400&h=400&fit=crop',
};
