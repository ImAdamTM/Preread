# Screenshots & Video Plan — Final

*Updated by the marketing team to align with final site copy and positioning.*

---

## Principles

- **Dark mode throughout.** Stands out in the App Store where most listings are light. Matches the app's default appearance.
- **No device frames.** Full-bleed app UI with rounded corners and subtle shadow. Won't date when new devices ship.
- **One message per screenshot.** Short headline above or overlaid on the UI. The app does the talking.
- **Use the demo feeds.** Currentwave, Sated, Meridian, Prism, Atelier with Unsplash imagery. No trademark concerns.
- **Gabarito for overlay text.** Matches the app typeface.
- **No em dashes in copy.** Periods and short sentences.

---

## iPhone Screenshots (6 screens, 6.9" display)

### Screenshot 1 — The Hook
- **Text:** "All the things you love to read. Ready whenever you are."
- **Show:** Home screen with "Preread for you" header, hero carousel showing the Sated pasta article, Atelier section below with article rows and unread dots
- **Purpose:** First impression. Content-rich, polished, inviting. The food photo is universally appealing.

### Screenshot 2 — The Reader
- **Text:** "A reading-first experience."
- **Show:** Reader view of a Meridian article (Kyoto). Dark mode. Hero image, clean typography, source and date visible. Show both dark and light mode if possible (side by side or second screenshot).
- **Purpose:** The core experience. This is what using the app actually feels like.

### Screenshot 3 — Discovery
- **Text:** "Stumble into new interests."
- **Show:** Browse Topics screen showing the full category list with feed counts. World News, Tech, AI, Science, Food, Travel, Gaming, etc.
- **Purpose:** Shows breadth. "Oh, they have architecture? And boating?" Makes people think about what they'd add.

### Screenshot 4 — No Saving Required
- **Text:** "No saving required. It's already there."
- **Show:** Settings screen showing Auto refresh enabled, background refresh on, WiFi-only toggle. Conveys the set-and-forget value.
- **Purpose:** Differentiator from Pocket/Instapaper. You don't save articles one at a time.

### Screenshot 5 — Offline
- **Text:** "On a plane. On the subway. Off the grid."
- **Show:** Reader view with airplane mode visible in the status bar (use `xcrun simctl status_bar` to fake it). Article fully loaded, no loading indicators.
- **Purpose:** Owns the offline moment. The status bar tells the story.

### Screenshot 6 — Widgets
- **Text:** "Glance at your latest articles."
- **Show:** Home screen with Preread widget (large or medium size). Real articles visible in the widget with thumbnails.
- **Purpose:** System integration. Widgets signal a polished, native app.

### Optional Screenshot 7 — iPad
- **Text:** "Beautiful on iPad too."
- **Show:** Split view with sidebar and reader, Meridian article open. Same content as the website's iPad mockup.
- **Purpose:** Shows iPad support for users browsing on iPad.

---

## iPad Screenshots (if submitting separately)

Use the same messaging but show iPad-specific layouts:
1. **Split view** with sidebar + reader (landscape). Meridian article with blurred favicon background.
2. **Browse Topics** showing the wider layout
3. **Home screen** with multiple sources expanded
4. **Widget** on iPad home screen

---

## App Preview Video (15-20 seconds)

### Storyboard

| Time | What's on screen | Notes |
|---|---|---|
| 0-2s | App opens to home screen. "Preread for you" with articles loaded. | Start in motion. No splash screen. |
| 2-4s | Scroll through home. Carousel slides. Source sections with unread dots. | Show content density and imagery. |
| 4-7s | Tap a Meridian article. Reader opens with zoom transition. Kyoto hero image. | The "wow" moment. Clean reader, stunning photo. |
| 7-9s | Slow scroll through the article body. | Show the reading experience. |
| 9-11s | Swipe back. Tap "+". Browse Topics appears. | Show discovery. |
| 11-13s | Scroll through topics. Tap into Food or Travel briefly. | Show breadth. |
| 13-15s | Cut to home screen with Preread widget. | System integration. |
| 15-17s | Enable airplane mode. Open app. Articles still there. | The offline moment. |
| 17-20s | App icon with text: "Preread. Ready when you are." | Closing card. |

### Production Notes

- **Record on a real device** via QuickTime screen mirroring for natural scroll physics and animations
- **No narration.** Subtle ambient music (royalty-free). Apple allows this.
- **Dark mode throughout.**
- **Set status bar** before recording: `xcrun simctl status_bar booted override --time "9:41"`
- **Resolution:** 1290x2796 for iPhone 16 Pro Max / iPhone 17 Pro Max (6.9")
- **Demo feeds must be fully cached** before recording. No loading spinners visible.

---

## Screenshot Production Checklist

### Before capturing
- [ ] Load all 5 demo feeds and let them fully cache
- [ ] Set app to dark mode
- [ ] Set font to System, text size to default (18pt)
- [ ] Override status bar: `xcrun simctl status_bar booted override --time "9:41" --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100`

### Capture
- [ ] Screenshot 1: Home screen with carousel and Atelier articles
- [ ] Screenshot 2: Reader view (Meridian/Kyoto, dark mode)
- [ ] Screenshot 3: Browse Topics full list
- [ ] Screenshot 4: Settings with sync options visible
- [ ] Screenshot 5: Reader with airplane mode status bar
- [ ] Screenshot 6: Widget on home screen
- [ ] Screenshot 7 (optional): iPad split view

### Post-processing
- [ ] Add text overlays in Figma or Keynote (Gabarito font, white text on dark)
- [ ] Export at correct App Store resolutions
- [ ] Record video preview (15-20s) on real device

### For airplane mode screenshot
```bash
xcrun simctl status_bar booted override --time "9:41" --wifiBars 0 --cellularBars 0 --cellularMode notSupported --batteryState charged --batteryLevel 100
```

### Reset status bar after
```bash
xcrun simctl status_bar booted clear
```
