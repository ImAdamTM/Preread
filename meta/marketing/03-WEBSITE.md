# Website Plan — preread.app

*Finalised by Kai (Design) with content from Maya (Marketing). Updated to align with App Store listing and legal review.*

---

## Design Direction

Dark theme matching the app. Single-page scroll. Minimal, editorial, generous whitespace. The phone does the talking — mockups are the centrepiece, copy is supporting.

No stock photos. All visuals are either app UI screenshots or the demo feed imagery (Unsplash-licensed). No device bezels — frameless phone screenshots with rounded corners and a soft shadow.

Gabarito for headings (matching the app), system sans-serif for body text. The accent gradient (teal to purple) used sparingly — CTAs and small highlights only.

---

## Page Structure

### Section 1: Hero

**Headline:**
> All the things you love to read.
> In one place. Ready whenever you are.

**Subheadline:**
> Preread is your personal article reader. Add the sites you love — full articles are ready to read before you are. On a plane, on the subway, anywhere.

**CTA:** App Store download badge (centred)

**Visual:** iPhone mockup (frameless) showing the home screen in dark mode — "Preread for you" header, carousel with a Sated pasta article, Atelier section below.

**Layout:** Headline and subheadline centred above. Phone mockup centred below, slightly overlapping the next section. App Store badge between text and phone.

---

### Section 2: The Pitch

**Headline:**
> Stop scrolling. Start reading.

**Body:**
> Social media buries the things you care about under noise you didn't ask for. Preread is the opposite — a calm space where every article is something you chose. No recommendations. No algorithms. Just the words and images, beautifully presented.

**Visual:** None needed. Let the words breathe. Subtle gradient divider or dark-to-darker background transition from the hero.

---

### Section 3: How It Works

Three steps, horizontal on desktop, stacked on mobile. Each step: number, headline, one sentence, phone mockup below.

**Step 1:**
> **Add the sites you love.**
> Browse 55+ topics or paste any URL. Preread finds the articles for you.

*Mockup: Browse Topics screen or Add Source sheet*

**Step 2:**
> **We make them ready for you.**
> Articles are prepared automatically in the background — including images — so your reading list is always full. No saving required.

*Mockup: Home screen showing multiple sources with article counts and "X articles ready"*

**Step 3:**
> **Read anywhere. Even offline.**
> On the train, on a plane, or just on the sofa. Your articles are always there — beautifully presented and ready to read, even without a connection.

*Mockup: Reader view showing a Meridian travel article with stunning hero image*

---

### Section 4: Feature Highlights

Alternating left-right layout. Phone mockup on one side, headline + short copy on the other. Flip sides for each row.

**Feature A — Discovery**
> **Stumble into new interests.**
> Browse 500+ sources across world news, science, food, travel, gaming, DIY, celebrity culture, architecture, and 55+ more topics and countries. Your next favourite publication is one tap away.

*Mockup: Browse Topics screen*

**Feature B — The Reader**
> **A reading-first experience.**
> Clean typography, customisable fonts, adjustable text sizes. Just you and the article. Dark mode or light — the reader adapts.

*Mockup: Reader view, dark mode, beautiful article*

**Feature C — Always Ready**
> **No saving required.**
> Most reading apps make you save articles one at a time. Preread does the opposite — articles are ready automatically, so you never open the app to an empty screen.

*Mockup: Home screen with "25 articles ready" or settings showing Auto refresh*

**Feature D — Everywhere**
> **Widgets. Watch. Siri. Share.**
> Glance at articles from your home screen. Read on your wrist. Share any URL to Preread from Safari. Ask Siri to open your favourite source.

*Mockup: Home screen with a Preread widget, or composite with widget + Watch*

---

### Section 5: The Offline Moment

**Headline:**
> On a plane. On the subway. Off the grid.

**Body:**
> Your articles are ready to read even without a connection. No loading. No "check your internet." Just open and read.

**Visual:** Phone mockup showing the reader view. Optionally, a subtle airplane mode icon in the status bar to sell the moment visually.

**Kai's note:** This section didn't exist before. ChatGPT was right — we need to *own* the offline moment rather than bury it in a bullet point. This is the emotional beat that converts someone from "interesting" to "I need this." It's short, visual, and lands right before the closing CTA.

---

### Section 6: Closing CTA

**Headline:**
> Preread is ready when you are.

**CTA:** App Store download badge (centred)

**Visual:** App icon, large, centred above the headline. Subtle gradient glow behind it.

---

### Footer

- Privacy Policy link
- Support / Contact link
- "Made by Streamline Labs" or similar
- Copyright 2026

---

## Pages Beyond the Homepage

### /privacy
Simple privacy policy page. Plain text, clean layout. Required by the App Store.

### /support
Contact information or a simple FAQ. Can be as minimal as an email address. Required by the App Store.

---

## Technical Notes

- Static HTML/CSS. No JavaScript framework needed.
- Host on preread.app (or streamlinelabs.io/preread as a redirect).
- Mobile-first responsive. Breakpoints at 768px and 1200px.
- Lazy-load phone mockup images for performance.
- OG meta tags for social sharing (see asset requirements below).

---

## Prompt Kit

Use these prompts with an AI frontend tool, Cursor, or a designer to build the site.

### Global Style Prompt
```
Build a single-page marketing website for an iOS app called "Preread."

Design system:
- Background: #0a0a0f (near-black)
- Text: #f5f5f5 (off-white)
- Secondary text: #a0a0a8
- Accent gradient: linear-gradient(135deg, #4fd1c5, #9f7aea)
- Card/surface: #141419
- Border: #2a2a30
- Font: Gabarito (Google Fonts) for headings, system sans-serif for body
- Border radius: 16px on cards, 24px on phone mockups
- Max content width: 1100px, centred

Tone: Minimal, editorial, calm. Generous whitespace. No feature grids.
Mobile-first responsive. Static HTML/CSS, no JavaScript frameworks.
```

### Hero Section Prompt
```
Hero section with a large centred heading split across two lines:
"All the things you love to read."
"In one place. Ready whenever you are."

Subheading below in secondary text: "Preread is your personal article reader. Add the sites you love — full articles are ready to read before you are. On a plane, on the subway, anywhere."

Centred Apple App Store download badge below the subheading. Below that, a frameless iPhone screenshot (rounded corners, subtle drop shadow) showing the app home screen.

Dark background. Generous padding (120px top, 80px bottom).
```

### The Pitch Prompt
```
Text-only section. Centred heading: "Stop scrolling. Start reading." in large type. Two sentences below in secondary text about calm, focused reading with no algorithms or recommendations. Dark background, generous vertical padding. Let the words breathe — no images, no cards.
```

### How It Works Prompt
```
Three-column layout (stacked on mobile). Each column: large step number rendered in the accent gradient, bold headline below, one sentence in secondary text, and a phone screenshot underneath. Columns have equal width with 40px gap. Section has a subtle heading "How it works" in small caps above.

Steps:
1. "Add the sites you love." — Browse 55+ topics or paste any URL.
2. "We make them ready for you." — Articles prepared automatically, no saving required.
3. "Read anywhere. Even offline." — On the train, on a plane, always there.
```

### Feature Highlights Prompt
```
Alternating two-column rows. Each row has a phone screenshot on one side and a headline + short paragraph on the other. Flip the layout for each row. Phone screenshots have rounded corners and a subtle shadow. Text is left-aligned on its side. Vertical spacing between rows: 120px.

Four features:
1. "Stumble into new interests." — 500+ sources, 55+ topics.
2. "A reading-first experience." — Clean typography, fonts, dark mode.
3. "No saving required." — Articles ready automatically.
4. "Widgets. Watch. Siri. Share." — System integration.
```

### Offline Moment Prompt
```
Centred section with heading: "On a plane. On the subway. Off the grid." Subtext: "Your articles are ready to read even without a connection." Phone mockup showing the reader view, optionally with airplane mode visible in the status bar. Dark background with slightly lighter surface tone to create visual separation.
```

### CTA / Footer Prompt
```
Closing section: centred app icon (120px) with a subtle accent gradient glow behind it. Heading "Preread is ready when you are." in large text. App Store badge below. Minimal footer underneath with privacy/support links and copyright. Footer text in secondary colour, small size.
```

---

## Asset Requirements

| Asset | Spec | Source |
|---|---|---|
| Home screen mockup | 1290x2796 PNG, dark mode, demo feeds loaded | App screenshot |
| Reader view mockup | 1290x2796 PNG, Meridian or Atelier article | App screenshot |
| Reader view (offline) | 1290x2796 PNG, reader with airplane mode in status bar | App screenshot (enable airplane mode) |
| Browse Topics mockup | 1290x2796 PNG, full category list | App screenshot |
| Add Source mockup | 1290x2796 PNG, sheet with URL + buttons | App screenshot |
| Settings mockup | 1290x2796 PNG, appearance/font/sync sections | App screenshot |
| Widget mockup | Home screen with Preread widget visible | iOS home screen screenshot |
| Watch mockup | Apple Watch showing article list | Watch screenshot or render |
| App icon (high-res) | 1024x1024 PNG | Existing asset |
| OG sharing image | 1200x630 PNG, app icon + tagline on dark bg | Needs creation |
| Favicon | 32x32 + 180x180 PNG | Crop from app icon |

### OG Image Prompt
```
Create a 1200x630 social sharing image. Dark background (#0a0a0f).
Centred: Preread app icon (200px) with the text "Preread" in Gabarito
below it, and "Read what you love. Anywhere." in smaller secondary text
underneath. Subtle accent gradient glow behind the icon. Clean and minimal.
```
