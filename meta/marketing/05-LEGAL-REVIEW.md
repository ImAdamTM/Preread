# Legal Review — Marketing Materials

*Review by Sam (Legal) with recommended changes for the marketing team.*

---

## Overview

I've reviewed the App Store listing (01), screenshots plan (02), website copy (03), and the APP.md feature document. The core positioning is sound — the app is a personal reading tool, not a content scraping or ad-blocking product. However, several lines across the documents could be misread by publishers, platform reviewers, or competitors. Flagging them below with recommendations.

---

## Flags & Recommendations

### FLAG 1: "Fetching and storing full articles"
**Where it appears:**
- App Store description: "fetching and storing full articles"
- Website hero: "fetches full articles, and stores them beautifully"
- APP.md: "fetches the full articles — not just headlines — and stores them locally"

**Concern:** "Fetching and storing" full articles from third-party websites could be read as systematic copying of copyrighted content. While this is standard personal-use caching (no different from a browser cache or Pocket/Instapaper), the language emphasises the *storage* in a way that could draw attention.

**Recommendation:** Reframe around the *reading* experience rather than the *storage* mechanism. The user doesn't care about caching — they care that articles are ready to read.

**Before:** "Preread visits them on your behalf — fetching and storing full articles so they're ready before you are."
**After:** "Preread visits them on your behalf — preparing full articles so they're ready before you are."

**Before:** "fetches the full articles — not just headlines — and stores them locally"
**After:** "reads the full articles — not just headlines — so they're ready when you are"

---

### FLAG 2: "Preread visits them on your behalf"
**Where it appears:** App Store description, website hero, APP.md

**Concern:** This is actually fine and I'd keep it — it accurately describes what the app does (HTTP requests to public URLs) and frames it as a personal agent acting for the user. This is legally equivalent to a browser prefetching pages. No change needed.

**Status:** Cleared.

---

### FLAG 3: "Articles cleaned and processed" / "extracted"
**Where it appears:**
- APP.md: "Articles are extracted and presented in a clean, focused reader view"
- App Store: "articles presented in a clean, focused layout"

**Concern:** "Extracted" implies separating content from its context (and revenue model). The current App Store wording ("presented in a clean, focused layout") is already better than the APP.md wording.

**Recommendation:** Standardise on "presented" across all docs. Avoid "extracted," "stripped," "cleaned," or "processed" in user-facing copy.

**Before (APP.md):** "Articles are extracted and presented in a clean, focused reader view"
**After:** "Articles are presented in a clean, focused reader view with beautiful typography"

---

### FLAG 4: "Unlike basic feed readers that only show snippets"
**Where it appears:** APP.md

**Concern:** This comparison emphasises that Preread goes *beyond* what feeds provide — i.e., it navigates to the publisher's site and copies the full page content. This is a technically accurate description of how the app works, but advertising it as a differentiator is essentially saying "we take more content than other apps do." This is fine for internal documentation but should not appear in any public-facing marketing.

**Recommendation:** Remove this comparison from APP.md or keep it strictly internal. The benefit to the user ("full articles are ready") can be communicated without explaining the mechanism.

**Before:** "Unlike basic feed readers that only show snippets, Preread navigates to each article and reads the full page on your behalf, caching the complete content with images"
**After:** "Full articles — not just headlines — are ready to read, complete with images"

---

### FLAG 5: "Respects publishers" / "share original links" messaging
**Where it appears:**
- App Store: "Preread respects your time, your attention, and the publishers who create the content you love. When you share, you share the original link."
- APP.md: "Supporting the Sources You Love" section

**Concern:** Proactively defending the app's relationship with publishers can paradoxically draw attention to the tension. If you say "we respect publishers," a reviewer might think "why do they need to say that?" It also sets an expectation that could be challenged.

**Recommendation:** Keep the sharing-original-links point — that's a concrete, positive feature. Remove the broader "respects publishers" framing. Let the feature speak for itself.

**Before:** "Preread respects your time, your attention, and the publishers who create the content you love. When you share, you share the original link. When you discover a new source, you discover a new website to support."
**After:** "When you share an article from Preread, you share the original link — so your friends can visit the source directly."

Drop the "discover a new website to support" line. It's trying too hard.

---

### FLAG 6: APP.md "Supporting the Sources You Love" section
**Where it appears:** APP.md core value propositions

**Concern:** This entire section reads defensively. "Preread helps you discover sites you'd never have browsed to otherwise" is the app making a case for why publishers should be okay with it. This is an internal argument, not a marketing message. Users don't think about this.

**Recommendation:** Remove this section entirely from APP.md (it's a marketing doc, not a legal brief). If you want to keep the sentiment, fold the sharing-original-links feature into the Article Management section where it already appears.

---

### FLAG 7: "Save single pages" / "cache a single webpage"
**Where it appears:** App Store, website, APP.md

**Concern:** Low risk. Saving a single page for personal offline reading is well-established (Pocket, Instapaper, Safari Reading List all do this). No change needed.

**Status:** Cleared.

---

### FLAG 8: "40+ topics" / "hundreds of sources"
**Where it appears:** Throughout all docs

**Concern:** Make sure these numbers are accurate at launch. "40+ topics" and "hundreds of sources" are verifiable claims. If the directory has 38 topics, say "35+ topics." If it has 150 sources, don't say "hundreds" (plural implies 200+).

**Recommendation:** Verify counts before submission.

---

## Summary of Required Changes

| Doc | Change |
|---|---|
| 01-APP-STORE-LISTING | "fetching and storing full articles" → "preparing full articles" |
| 01-APP-STORE-LISTING | Remove "Preread respects... publishers" paragraph, replace with simpler sharing line |
| 03-WEBSITE | "fetches full articles, and stores them" → "prepares full articles" |
| APP.md | "extracted and presented" → "presented" |
| APP.md | Remove "Preread goes deeper" comparison with other readers |
| APP.md | Remove "Supporting the Sources You Love" section (fold sharing into features) |
| All docs | Verify "40+ topics" and "hundreds of sources" are accurate |

---

*Review complete. All other copy is clear. The overall positioning — personal reading tool, curated discovery, beautiful experience — is legally sound and commercially smart. — Sam*
