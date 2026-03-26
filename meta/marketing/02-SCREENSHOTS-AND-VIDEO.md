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

## iPhone Screenshots (5 screens, 6.9" display)

### Screenshot 1 — The Hook
- **Text:**
  `All the things you love to read.`
  `Ready whenever you are.`
  `In one place. Even offline.`
- **Show:** Home screen with "Preread for you" header, hero carousel showing the Sated pasta article, Atelier section below with article rows and unread dots
- **Purpose:** First impression. Three beats: emotional, convenience, killer feature.

### Screenshot 2 — Discovery
- **Text:**
  `Stumble into new interests.`
  `Add the sites you love.`
  `Preread handles the rest.`
- **Show:** Browse Topics screen or Add Source sheet. Shows both entry points: browse or paste a URL.
- **Purpose:** Explains the mechanic and the breadth in one. "Oh, I just add sites and it does the rest."

### Screenshot 3 — The Reader
- **Text:**
  `Stop scrolling. Start reading.`
  `Beautifully presented.`
  `Full. Clean. Focused.`
- **Show:** Reader view of a Meridian article (Kyoto). Dark mode. Hero image, clean typography.
- **Purpose:** The feeling. This is what using the app actually looks like.

### Screenshot 4 — Set and Forget
- **Text:**
  `Set it and forget it.`
  `Preread keeps your library fresh.`
  `Open the app. Start reading.`
- **Show:** Settings screen with Auto refresh on, or home screen full of fresh articles.
- **Purpose:** The differentiator. Your reading list fills itself.

### Screenshot 5 — Everywhere
- **Text:**
  `On your homescreen.`
  `On your wrist.`
  `Widgets. Watch. Siri.`
- **Show:** Widget composite showing large, wide, and small widgets.
- **Purpose:** System integration. Signals a polished, deeply native app.

### Optional Screenshot 6 — iPad
- **Text:**
  `Beautiful on iPad too.`
  `Full split view with sidebar and reader.`
- **Show:** iPad split view with Meridian article open.
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
