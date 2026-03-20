# Preread — Claude Code Notes

## Article ordering

When querying or processing articles (refreshing, retrying, caching), always sort newest-first: `ORDER BY COALESCE(publishedAt, addedAt) DESC`. This applies to every code path that fetches articles for processing — feed refresh, retry of failed/pending articles, background tasks, etc.

## Debugging the caching pipeline

There is a standalone CLI tool at `debug-cache/` for inspecting what happens when Preread caches a URL. It replicates the exact standard-mode pipeline from `PageCacheService` and saves intermediate HTML files.

When the user says "debug this URL" (or similar), run:

```bash
cd /Users/adamhartwig/gitrepos/Preread/debug-cache && swift run CacheDebugger "<URL>"
```

For full-page mode, add `--full`:

```bash
cd /Users/adamhartwig/gitrepos/Preread/debug-cache && swift run CacheDebugger "<URL>" --full
```

This produces 4 files in `debug-cache/output/`:

| File | Pipeline step |
|---|---|
| `1_raw.html` | Raw HTML from the server |
| `2_cleaned.html` | After removing scripts, noscript, styles, CSP meta tags, placeholder images, and stripping image layout attributes |
| `3_flattened.html` | After figure unwrapping, image-only div flattening, and single-child div collapsing |
| `4_readability.html` | Readability-extracted article content |

After running, read the output files to inspect what each stage produces. Common things to check:
- **Images missing after Readability?** Compare `3_flattened.html` vs `4_readability.html` to see what Readability dropped.
- **Content truncated or wrong section extracted?** Look at `3_flattened.html` to see if the DOM structure is confusing Readability.
- **Garbage in output?** Check `2_cleaned.html` to see if cleaning missed something (e.g. inline JS, non-standard tags).

The `output/` directory is gitignored.

## Pipeline test suite

After any changes to the readability/cleaning pipeline in `PageCacheService.swift`:

1. Run the pipeline tests to verify no regressions
2. If adding a new cleaning rule, add a fixture + test for the case it fixes
3. **CRITICAL: Apply the same change to `debug-cache/Sources/main.swift`**. The debug tool replicates the production pipeline and must stay in sync — hero image filtering, cleaning rules, image stripping, and all other pipeline logic must match `PageCacheService.swift` exactly.
4. Fixture files live in `PrereadTests/Fixtures/` — raw HTML saved from the debug-cache tool's `1_raw.html` output

### Adding a new fixture

1. Run the debug-cache tool against the URL: `cd debug-cache && swift run CacheDebugger "<URL>"`
2. Copy `debug-cache/output/1_raw.html` to `PrereadTests/Fixtures/<name>.html`
3. Add a new `@Test` in `PrereadTests/PipelineTests.swift` that loads the fixture and asserts on expected pipeline output (title, image count, content presence/absence)

### What the tests verify

Every fixture is tested through **both** pipelines:

**Standard mode** (`runStandardPipeline`) — Readability extraction:
- `title` contains expected text
- `imageCount` meets expected minimum
- `contentHTML` contains expected article text
- `contentHTML` does not contain `<script>`, `<nav>`, or `<style>` tags
- Fixture-specific checks (e.g. badges stripped, tables preserved, hero image injected)

**Full mode** (`runFullPipeline`) — whole-page cleaning:
- `cleanedHTML` does not contain `<script>`, `<nav>`, `<noscript>`, `<svg>`, `<form>` tags
- `cleanedHTML` preserves article content, images, tables, and CSS stylesheets
- Fixture-specific checks (e.g. no buttons, no dialogs, no hidden elements)

**CRITICAL: When adding a new fixture, always add tests for both modes.** Skipping one leaves half the pipeline unvalidated.

## Pipeline cleanup rules

**CRITICAL: Always prefer generic, standards-based approaches over site-specific selectors.** Never use `data-testid`, `data-component`, or other site-specific attributes to identify elements to strip.

Good (generic):
- Strip by HTML tag: `<nav>`, `<aside>`, `<button>`, `<svg>`
- Strip by standard attribute: `[aria-hidden=true]`
- Cascade-remove empty elements after stripping children (`stripEmptyElements`)

Bad (site-specific):
- `[data-testid=drawer-background]`
- `[data-component=ad-slot]`
- `.site-specific-class-name`

If a site has layout problems after caching, the fix should work across any site with the same structural pattern (e.g. hidden popovers, empty wrappers, noscript fallbacks).

## Performance and battery

Before introducing any of the following patterns, **flag the performance implications** and discuss alternatives with the user first:

- **Polling loops** (`Task.sleep` + retry) — prefer reactive observation (e.g. GRDB `ValueObservation`, Combine publishers, `AsyncSequence`) so work only happens when data actually changes.
- **Repeating animations** (`.repeatForever`, `TimelineView` with high refresh rates) — each one keeps the GPU active and prevents the display from dropping to lower refresh rates. Evaluate whether the animation is visible and necessary.
- **Runtime JS evaluation in web views** — batch or debounce calls (e.g. text size slider) rather than evaluating on every state change. Prefer doing work at cache/build time over runtime when possible.
- **Continuous observation of high-frequency state** (e.g. `.onChange` on a value that updates many times per second) — debounce or throttle the downstream work.
- **Background tasks that iterate large datasets** — ensure they yield (`Task.sleep`, batching) and don't block the main thread.
- **Work inside SwiftUI `body`** — `body` re-evaluates on every state change and during scrolling. Never create `UIImage`, run `UIGraphicsImageRenderer`, or do other non-trivial computation inline in `body`. Cache results in `@State` and generate them once via `.task` or `onAppear`.

The general principle: **if something runs repeatedly, ask whether it needs to**. One-shot or reactive approaches are always preferred over polling or continuous loops.

## Feed directory

The feed directory lives at `scripts/update-feed-directory/`. Feeds are organised as per-category JSON files in `scripts/update-feed-directory/categories/*.json`.

### Generated files — never edit by hand

**CRITICAL: `Preread/Resources/discover_feeds.json` is a generated output.** It is produced by the feed directory tool and must never be edited manually. All feed changes go through the category files, then the tool regenerates the output.

### Workflow for adding or changing feeds

1. Edit (or create) the relevant `categories/<slug>.json` file.
2. Run the tool **with validation** to verify all feeds:
   ```bash
   cd /Users/adamhartwig/gitrepos/Preread/scripts/update-feed-directory && swift run UpdateFeedDirectory
   ```
   This validates every feed (reachable, not stale, not thin content) and writes `discover_feeds.json`.
3. If feeds fail validation, either fix the feed URL or remove the entry.
4. For new categories, also update `FeedDirectory.swift`:
   - Add the category to `categoryOrder` at the correct position.
   - Add an SF Symbol icon to `categoryIcons`.

**CRITICAL: The `--skip-validation` and `--skip-quality` flags must not be used as the final step when adding new feeds.** They exist for development speed only. New feeds must pass the full validation pipeline before being considered done.

Other tool modes:
- `verify` — checks all existing feeds, auto-discovers replacement URLs for broken ones, and updates category files.
- `discover` — finds new candidate feeds from upstream OPML sources.

## Test failures

**CRITICAL: Never dismiss a test failure as "pre-existing" or "unrelated to this change".** Every failing test must be investigated. If a test fails while verifying your work, diagnose the root cause and fix it — even if the failure appears to predate your changes. Do not move on until all tests you run are passing.

## Problem-solving approach

When a fix attempt fails, **do not guess at another fix**. Instead:

1. Search the web for the specific error, API, or platform behaviour before proposing a second attempt
2. Check Apple Developer Forums, Stack Overflow, and official documentation for known issues or breaking changes (e.g. iOS version-specific API changes)
3. Present findings to the user before applying the next fix

This is especially important for platform-level code (extensions, entitlements, background tasks, URL schemes) where behaviour varies across OS versions and documentation is often incomplete.
