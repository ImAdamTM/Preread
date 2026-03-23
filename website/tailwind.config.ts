import type { Config } from 'tailwindcss';

const config: Config = {
  content: [
    './app/**/*.{js,ts,jsx,tsx}',
  ],
  theme: {
    extend: {
      colors: {
        // Exact dark mode colors from Theme.swift
        surface: '#000000',
        card: '#111118',
        raised: '#1E1E22',
        'app-border': 'rgba(255,255,255,0.07)',
        accent: '#6B6BF0',
        purple: '#A855F7',
        text: {
          primary: '#F0F0FF',
          secondary: '#888899',
        },
      },
      fontFamily: {
        sans: ['Gabarito', 'system-ui', 'sans-serif'],
        heading: ['Gabarito', 'sans-serif'],
      },
      keyframes: {
        'pulse-glow': {
          '0%, 100%': { opacity: '0.15', transform: 'scale(1)' },
          '50%': { opacity: '0.25', transform: 'scale(1.05)' },
        },
      },
      animation: {
        glow: 'pulse-glow 4s cubic-bezier(0.4,0,0.6,1) infinite',
      },
    },
  },
  plugins: [],
};

export default config;
