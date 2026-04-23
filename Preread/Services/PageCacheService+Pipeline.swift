import Foundation
import SwiftSoup
import SwiftReadability

// MARK: - HTML pipelines (standard, full, RSS fallback)

extension PageCacheService {

    // MARK: - Standard pipeline (testable)

    /// Runs the standard-mode HTML pipeline: cleaning, flattening, Readability
    /// extraction, hero re-injection, and post-processing. Returns the extracted
    /// article HTML, title, and image count.
    ///
    /// This is the same logic used by `performCacheArticle` for standard mode,
    /// extracted here so fixture-based unit tests can verify pipeline behaviour
    /// without requiring network access or database state.
    func runStandardPipeline(html: String, pageURL: URL) throws -> PipelineResult {
        let preDoc = try SwiftSoup.parse(html, pageURL.absoluteString)

        // Before stripping scripts, extract article HTML from __NEXT_DATA__
        // (Next.js sites that don't fully server-render their content).
        let nextDataContent = extractNextDataContent(from: preDoc)

        // Before stripping scripts, hydrate empty image placeholders from
        // Apollo Client cache (GraphQL + React server-rendered pages).
        let apolloImageCount = hydrateApolloImages(in: preDoc)
        if apolloImageCount > 0 {
            print("[PageCacheService] Hydrated \(apolloImageCount) Apollo images into placeholders")
        }

        try preDoc.select("script").remove()
        try promoteNoscriptImages(in: preDoc)
        try preDoc.select("noscript").remove()

        // If __NEXT_DATA__ had article HTML, inject it into the body.
        // The <article> tag gives Readability a strong content signal.
        if let nextContent = nextDataContent, let body = preDoc.body() {
            try body.append("<article id=\"next-data-article\">\(nextContent)</article>")
        }
        try preDoc.select("style").remove()
        try preDoc.select("meta[http-equiv=Content-Security-Policy]").remove()

        try preDoc.select("img.hide-when-no-script").remove()

        // Recover real URLs from lazy-loaded placeholder images BEFORE
        // stripping placeholders — otherwise recoverable images are lost.
        try recoverPlaceholderImages(in: preDoc)
        try preDoc.select("img[src*=placeholder]").remove()
        try unwrapPictureElements(in: preDoc)
        try stripCaptionToggles(in: preDoc)

        // Strip aria-hidden attributes from content elements so Readability
        // doesn't skip text that is toggled visible by JS. Many CMS platforms
        // use aria-hidden as a progressive-disclosure mechanism — the attribute
        // is removed client-side, but since we disable JS it persists and
        // causes Readability to ignore legitimate article paragraphs.
        try stripAriaHiddenFromContent(in: preDoc)

        try stripTinyImages(in: preDoc, maxDimension: 30)
        try stripBadgeClusters(in: preDoc)
        try stripImageLayoutStyles(in: preDoc)
        try constrainAvatarImages(in: preDoc)

        // Strip comment sections — these contain user-generated comments
        // that can outweigh article text and confuse Readability's scoring.
        // Uses standard ID/class conventions (WordPress, Disqus, etc.).
        try preDoc.select("#comments, .comments, #disqus_thread").remove()

        // Strip tooltip elements — informational popups, not article content.
        // Catches utility bars, share widgets, and other overlay-style chrome.
        try preDoc.select("[role=tooltip]").remove()

        // Strip elements marked as non-content by Google's data-nosnippet
        // attribute. Sites use this on comments, ads, and promotional sections.
        try preDoc.select("[data-nosnippet]").remove()

        // Strip newsletter signup containers — promotional widgets embedded
        // in articles. Uses semantic class/ID conventions common across CMS
        // platforms (WordPress plugins, Ghost, ConvertKit, etc.).
        try preDoc.select("[class*=newsletter], [id*=newsletter]").remove()

        // Strip common in-article interstitials ("Article continues below",
        // "Continue reading below", etc.) — standard CMS break points that
        // interrupt article flow and confuse Readability scoring.
        try stripInterstitials(in: preDoc)

        try preDoc.select("button").remove()
        try preDoc.select("dialog").remove()
        try preDoc.select("svg").remove()
        try preDoc.select("nav").remove()
        try preDoc.select("[role=navigation]").remove()
        try preDoc.select("header[id*=navigation], header[class*=navigation]").remove()
        // Unwrap aside elements that contain captioned images — these
        // are inline media galleries. The <figcaption> distinguishes them
        // from sidebar/related-content asides that only have thumbnails.
        for aside in try preDoc.select("aside:has(figcaption):has(img)").array().reversed() {
            try aside.unwrap()
        }
        try preDoc.select("aside").remove()
        try preDoc.select("form").remove()
        try preDoc.select("input").remove()
        try preDoc.select("select").remove()
        try preDoc.select("textarea").remove()
        try preDoc.select("iframe").remove()
        try preDoc.select("video").remove()
        try preDoc.select("audio").remove()

        try stripLinkedThumbnailCards(in: preDoc, pageURL: pageURL)

        try unwrapCustomElements(in: preDoc)
        try preDoc.select("figure").unwrap()
        try flattenImageOnlyDivs(in: preDoc)
        flattenSingleChildDivs(in: preDoc)
        try stripEmptyElements(in: preDoc)
        try wrapStandaloneImages(in: preDoc)

        let cleanedHTML = try preDoc.html()

        let readability = Readability(html: cleanedHTML, url: pageURL)
        let extracted = try readability.parse()

        // If Readability couldn't extract anything, the page likely requires
        // JavaScript to render (e.g. SPAs). Fail instead of caching empty content.
        guard let extracted = extracted else {
            throw NSError(domain: "PageCacheService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Readability returned nil — page may require JavaScript"
            ])
        }

        let articleTitle = extracted.title ?? ""
        var contentHTML = extracted.contentHTML

        // Also check that extracted content has meaningful text
        let textCheck = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
        let plainText = (try? textCheck.body()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count
        if plainText.count < 50 {
            throw NSError(domain: "PageCacheService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Extracted content too short (\(plainText.count) chars) — page may require JavaScript"
            ])
        }

        // If Readability dropped the hero image, re-inject it.
        // First look inside content landmarks (article, main) to avoid
        // sidebar images, then fall back to the whole page.
        var heroImageURL: String?

        let isHeroCandidate: (Element) -> Bool = { img in
            guard let src = try? img.attr("src"), !src.isEmpty,
                  !src.hasPrefix("data:") else { return false }
            // Skip images too small to be a meaningful hero (avatars, icons)
            let w = Int((try? img.attr("width")) ?? "") ?? Int.max
            let h = Int((try? img.attr("height")) ?? "") ?? Int.max
            if w < 120 || h < 120 { return false }
            // Small images (both dims ≤ 250) are avatars, sidebar thumbs, etc.
            if w != Int.max, h != Int.max, w <= 250, h <= 250 { return false }
            // Narrow portrait images (w ≤ 200, taller than wide) are author photos
            if w != Int.max, h != Int.max, w < h, w <= 200 { return false }
            // Also check URL resize parameters (e.g. ?w=150) — WordPress and
            // CDNs use these for thumbnail/avatar variants without setting
            // HTML width/height attributes.
            if let urlComps = URLComponents(string: src),
               let wParam = urlComps.queryItems?.first(where: { $0.name == "w" })?.value,
               let urlWidth = Int(wParam), urlWidth <= 150 {
                return false
            }
            let srcLower = src.lowercased()
            let imgId = (try? img.attr("id"))?.lowercased() ?? ""
            let alt = (try? img.attr("alt"))?.lowercased() ?? ""
            // Skip site chrome: SVGs, logos, flags, icons, social widgets
            if srcLower.contains(".svg") { return false }
            // Images marked as logos via structured data (schema.org itemprop)
            if (try? img.attr("itemprop")) == "logo" { return false }
            // WordPress theme assets are always site-wide decoration, never article content
            if srcLower.contains("/wp-content/themes/") { return false }
            let chromeWords = [
                "logo", "flag", "icon", "badge", "spinner",
                "facebook", "twitter", "instagram", "pinterest", "tiktok",
                "furniture", "share", "follow", "comment", "thumbnail",
                "banner", "bkgd", "reactions", "headshot",
                "blank", "spacer"
            ]
            // Use word-segment matching instead of substring matching to avoid
            // false positives on compound filenames (e.g. "blogouterbanner"
            // contains "logo" and "banner" as substrings but neither as a segment).
            let segmentDelims: Set<Character> = ["_", "-", ".", "/", " ", "?", "&", "="]
            let segments = { (text: String) -> Set<Substring> in
                Set(text.split { segmentDelims.contains($0) })
            }
            let idSegs = segments(imgId)
            let altSegs = segments(alt)
            let srcSegs = segments(srcLower)
            for word in chromeWords {
                let w = Substring(word)
                if idSegs.contains(w) || altSegs.contains(w) || srcSegs.contains(w) { return false }
            }
            // Check up to 2 ancestor levels for chrome signals.
            // Sites often wrap logos/avatars in containers like
            // <span class="site-logo">, <div data-pw="disclosureLogo">,
            // or <a aria-hidden="true"> where the image itself has no hint.
            var ancestor: Element? = img.parent()
            for _ in 0..<2 {
                guard let el = ancestor else { break }
                // aria-hidden="true" marks decorative elements (byline photos, etc.)
                if (try? el.attr("aria-hidden")) == "true" { return false }
                let attrs = el.getAttributes()?
                    .asList().map { $0.getValue().lowercased() } ?? []
                // Split attribute values into individual hyphen-delimited tokens
                // so "category-facebook" yields ["category", "facebook"] and
                // compound class names like that don't false-positive on "facebook".
                // We only match chrome words that appear as leading segments:
                // "facebook-share" → matches "facebook", but "category-facebook" → doesn't.
                let tokens = Set(attrs.flatMap { $0.split(separator: " ").map(String.init) })
                for word in chromeWords {
                    for token in tokens {
                        if token == word || token.hasPrefix(word + "-") { return false }
                    }
                }
                ancestor = el.parent()
            }
            // Profile images: avatars and author headshots served from
            // dedicated paths (/avatar/, /avatars/, /authors/) are never
            // article content.
            if srcLower.contains("/avatar/") || srcLower.contains("/avatars/")
                || srcLower.contains("/avatar.") || srcLower.contains("/avatar_")
                || srcLower.contains("/authors/")
                || imgId.contains("avatar") { return false }
            // Skip images whose alt text marks them as structural/decorative
            // (e.g. "background of header", "foreground of header"). These are
            // site-wide branding elements, not article content.
            if alt.hasPrefix("background") || alt.hasPrefix("foreground") { return false }
            // Skip images inside <a> links that navigate to a different page.
            // These are navigation/promo thumbnails (e.g. hero bars, related
            // article cards) not the article's own hero image.
            // Allow links to image files — a common lightbox/zoom pattern.
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif"]
            var walk: Element? = img.parent()
            for _ in 0..<5 {
                guard let el = walk else { break }
                if el.tagName() == "a",
                   let href = try? el.attr("href"), !href.isEmpty,
                   let linkURL = URL(string: href, relativeTo: pageURL) {
                    let ext = linkURL.pathExtension.lowercased()
                    if imageExtensions.contains(ext) { break }
                    let linkPath = linkURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let pagePath = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !linkPath.isEmpty && linkPath != pagePath { return false }
                    break
                }
                walk = el.parent()
            }
            return true
        }

        // Step 1: Try scoped selectors (prefer images inside article content)
        let scopedSelectors = [
            "article img[src]",
            "[itemprop=articleBody] img[src]",
            "main img[src]",
            "[role=main] img[src]",
        ]
        let scopedImg: Element? = scopedSelectors.lazy.compactMap { selector in
            try? preDoc.select(selector).first(where: isHeroCandidate)
        }.first

        // Step 2: Determine the hero image.
        // Check both the raw src and its resolved absolute URL so relative
        // paths (e.g. /wp-content/...) match their absolute counterparts
        // that Readability may have resolved. Also check HTML-encoded form
        // since & in URLs becomes &amp; in HTML attribute values.
        let heroAlreadyPresent = { (src: String) -> Bool in
            if contentHTML.contains(src) { return true }
            if let abs = URL(string: src, relativeTo: pageURL)?.absoluteString,
               abs != src {
                if contentHTML.contains(abs) { return true }
                let encoded = abs.replacingOccurrences(of: "&", with: "&amp;")
                if encoded != abs, contentHTML.contains(encoded) { return true }
            }
            return false
        }

        if let scoped = scopedImg {
            let src = (try? scoped.attr("src")) ?? ""
            if !heroAlreadyPresent(src) {
                // Scoped hero was dropped by Readability — inject it
                heroImageURL = src
                let heroTag = (try? scoped.outerHtml()) ?? ""
                if !heroTag.isEmpty {
                    contentHTML = heroTag + contentHTML
                }
            } else {
                // Scoped hero is already in Readability content — nothing to inject.
                heroImageURL = src
            }
        } else {
            // No scoped image found — fall back to page-level search
            if let pageFirst = try? preDoc.select("img[src]").first(where: isHeroCandidate) {
                let src = (try? pageFirst.attr("src")) ?? ""
                heroImageURL = src
                if !heroAlreadyPresent(src) {
                    let heroTag = (try? pageFirst.outerHtml()) ?? ""
                    if !heroTag.isEmpty {
                        contentHTML = heroTag + contentHTML
                    }
                }
            }
        }

        // If no hero image was found from <img> elements, fall back to
        // the OpenGraph image (og:image meta tag). Many sites declare their
        // primary image only via og:image (common with JS-rendered pages).
        // The meta tags survive cleaning (only CSP metas are stripped).
        if heroImageURL == nil {
            if let ogImage = try extractOpenGraphImage(from: preDoc, baseURL: pageURL) {
                heroImageURL = ogImage
                if !heroAlreadyPresent(ogImage) {
                    contentHTML = "<img src=\"\(escapeHTML(ogImage))\" />" + contentHTML
                }
            }
        }

        // Recover article images that Readability dropped. Readability discards
        // image-only <p> elements (zero text content) even when they're inside a
        // well-scored container. For each dropped image, find the nearest following
        // text paragraph in the pre-Readability HTML, locate that same text in the
        // Readability output, and re-inject the image before it.
        contentHTML = try recoverDroppedImages(
            contentHTML: contentHTML,
            preDoc: preDoc,
            heroImageURL: heroImageURL,
            pageURL: pageURL
        )

        // Post-processing
        let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
        guard contentDoc.body() != nil else {
            throw NSError(domain: "PageCacheService", code: 1, userInfo: nil)
        }

        // Deduplicate images — exact src match, then base-URL match
        // (strips query params so crop/size variants of the same image
        // are recognised as duplicates), then host+filename match
        // (catches CDN resize variants with different path hashes).
        var seenSrcs = Set<String>()
        var seenBasePaths = Set<String>()
        var seenHostFilenames = Set<String>()
        for img in try contentDoc.select("img[src]") {
            let src = try img.attr("src")
            guard !src.isEmpty, !src.hasPrefix("data:") else { continue }
            if !seenSrcs.insert(src).inserted {
                try img.remove()
                continue
            }
            if let url = URL(string: src),
               let scheme = url.scheme, let host = url.host {
                // Dedup by base path (scheme + host + path, ignoring query/fragment).
                // Include identity query params so media-library-style URLs and
                // CDN proxy URLs aren't falsely deduped. "url" covers CDNs like
                // Brightspot where the path is shared and ?url= identifies the source image.
                var basePath = "\(scheme)://\(host)\(url.path)"
                if let comps = URLComponents(string: src),
                   let items = comps.queryItems {
                    let idParams = items
                        .filter { ["id", "uuid", "p", "attachment_id", "url"].contains($0.name.lowercased()) }
                        .compactMap { item -> String? in
                            guard let value = item.value else { return nil }
                            return "\(item.name)=\(value)"
                        }
                        .sorted()
                    if !idParams.isEmpty {
                        basePath += "?" + idParams.joined(separator: "&")
                    }
                }
                if !seenBasePaths.insert(basePath).inserted {
                    try img.remove()
                    continue
                }
                // Dedup by host + filename — catches CDN resize variants where
                // only an intermediate path segment (hash/dimensions) differs.
                // Skip when the filename is generic (shared across many images).
                let filename = url.lastPathComponent
                let genericFilenames: Set<String> = [
                    "image.jpg", "image.jpeg", "image.png", "image.webp",
                    "photo.jpg", "photo.jpeg",
                    // Bare format names from CDN path segments (e.g. .../format/jpeg/)
                    "jpeg", "jpg", "png", "webp", "gif", "avif",
                    // CDN size/transform path segments (e.g. .../image/{uuid}/large)
                    // These indicate a resize variant, not a unique image identifier.
                    "large", "small", "medium", "thumbnail", "thumb",
                    "original", "full", "default",
                ]
                // CDN dimension-based filenames (e.g. 900x.jpg, 640x480.jpg)
                // are resize variants, not unique identifiers.
                let filenameLower = filename.lowercased()
                let isDimensionFilename = filenameLower.range(
                    of: #"^\d+x\d*\."#, options: .regularExpression
                ) != nil
                let isGeneric = genericFilenames.contains(filenameLower) || isDimensionFilename
                if !filename.isEmpty, filename != "/", !isGeneric {
                    // When the path has only 2 segments (e.g. /{hash}/file.jpg),
                    // the first segment is a content identifier — include it to
                    // avoid deduplicating different images that share a filename.
                    let pathSegs = url.pathComponents.filter { $0 != "/" }
                    let hostFilename: String
                    if pathSegs.count == 2 {
                        hostFilename = "\(host)/\(pathSegs[0])/\(filename)"
                    } else {
                        hostFilename = "\(host)/\(filename)"
                    }
                    if !seenHostFilenames.insert(hostFilename).inserted {
                        try img.remove()
                    }
                }
            }
        }

        // Deduplicate sibling images that share the same base URL
        // but differ only in dimension suffixes (e.g. image-640x426.jpg
        // vs image-1024x648.jpg). Keeps the largest variant.
        try deduplicateSiblingImages(in: contentDoc)

        try stripBylineImages(in: contentDoc)
        try stripEmptyElements(in: contentDoc)

        let imageCount = (try? contentDoc.select("img"))?.size() ?? 0
        contentHTML = (try? contentDoc.body()?.html()) ?? contentHTML

        return PipelineResult(title: articleTitle, contentHTML: contentHTML, imageCount: imageCount, heroImageURL: heroImageURL, wordCount: wordCount)
    }

    /// Runs the full-mode HTML cleaning pipeline: strips scripts, navigation,
    /// noscript fallbacks, interactive elements, and CSP meta tags, then
    /// removes empty elements left behind.
    /// Returns the cleaned HTML. Exposed as internal for test access.
    func runFullPipeline(html: String, pageURL: URL) throws -> FullPipelineResult {
        let doc = try SwiftSoup.parse(html, pageURL.absoluteString)

        // Before stripping scripts, extract article HTML from __NEXT_DATA__
        let nextDataContent = extractNextDataContent(from: doc)

        // Before stripping scripts, hydrate empty image placeholders from
        // Apollo Client cache (GraphQL + React server-rendered pages).
        let apolloImageCount = hydrateApolloImages(in: doc)
        if apolloImageCount > 0 {
            print("[PageCacheService] Hydrated \(apolloImageCount) Apollo images into placeholders (full mode)")
        }

        // Strip CSP meta tags
        try doc.select("meta[http-equiv=Content-Security-Policy]").remove()

        // If __NEXT_DATA__ had article HTML, inject it into the body before
        // scripts are stripped. This ensures the article content is visible
        // in the cleaned output for sites that don't server-render their content.
        if let nextContent = nextDataContent, let body = doc.body() {
            try body.append("<article id=\"next-data-article\">\(nextContent)</article>")
        }

        // Ensure a white background fallback. Many sites rely on browser
        // defaults or don't set an explicit background-color, which makes
        // text illegible when the WebView has a transparent/dark background.
        if let head = doc.head() {
            try head.append("<style>html, body { background-color: #fff !important; }</style>")
        }

        // Strip scripts and noscript fallbacks — we disable JS in the web
        // view, so noscript blocks render and create huge layout gaps
        // (full site-navigation trees can live inside <noscript>).
        try doc.select("script").remove()
        try promoteNoscriptImages(in: doc)
        try doc.select("noscript").remove()

        try recoverPlaceholderImages(in: doc)
        try unwrapPictureElements(in: doc)
        try stripCaptionToggles(in: doc)

        // Strip navigation — site nav links are non-functional offline
        // and take up significant space above article content.
        try doc.select("nav").remove()
        try doc.select("[role=navigation]").remove()
        try doc.select("header[id*=navigation], header[class*=navigation]").remove()

        // Strip comment sections — user-generated comments are non-functional
        // offline and add unnecessary weight.
        try doc.select("#comments, .comments, #disqus_thread").remove()

        // Strip tooltip elements — informational popups, not article content.
        try doc.select("[role=tooltip]").remove()

        // Strip elements marked as non-content by Google's data-nosnippet attribute.
        try doc.select("[data-nosnippet]").remove()

        // Strip newsletter signup containers — promotional widgets.
        try doc.select("[class*=newsletter], [id*=newsletter]").remove()

        // Strip common in-article interstitials.
        try stripInterstitials(in: doc)

        // Strip interactive elements that rely on JS
        try doc.select("button").remove()
        try doc.select("dialog").remove()
        try doc.select("svg").remove()
        try doc.select("form").remove()
        try doc.select("input").remove()
        try doc.select("select").remove()
        try doc.select("textarea").remove()
        try doc.select("video").remove()
        try doc.select("audio").remove()

        // Strip aria-hidden from content elements so JS-toggled text remains
        // visible, then remove remaining aria-hidden elements (popovers,
        // overlays, decorative wrappers that take up layout space without JS).
        try stripAriaHiddenFromContent(in: doc)
        try doc.select("[aria-hidden=true]").remove()

        // Strip related-article card widgets (small linked thumbnails + headlines)
        try stripLinkedThumbnailCards(in: doc, pageURL: pageURL)

        // Neutralise sticky/fixed positioning — site headers and toolbars
        // float over content and are non-functional in offline cached pages.
        // Inject a stylesheet rule so elements positioned via CSS stylesheets
        // are also caught (not just inline styles).
        try stripStickyPositioning(in: doc)

        // Cascade-remove empty elements left behind by the above stripping.
        // e.g. a div that contained only a button is now empty and takes up
        // space via CSS padding/margins. Multiple passes handle nested wrappers.
        try stripEmptyElements(in: doc)

        // Capture the first meaningful image for thumbnail backfill,
        // preferring images inside content landmarks over page chrome.
        var heroImageURL: String?
        let fullCandidateSelectors = [
            "article img[src]",
            "[itemprop=articleBody] img[src]",
            "main img[src]",
            "[role=main] img[src]",
            "img[src]"
        ]
        if let firstImg: Element = fullCandidateSelectors.lazy.compactMap({ selector in
            try? doc.select(selector).first(where: { img in
                guard let src = try? img.attr("src"), !src.isEmpty,
                      !src.hasPrefix("data:") else { return false }
                // Skip images too small to be a meaningful hero (avatars, icons)
                let w = Int((try? img.attr("width")) ?? "") ?? Int.max
                let h = Int((try? img.attr("height")) ?? "") ?? Int.max
                if w < 120 || h < 120 { return false }
                // Small images (both dims ≤ 250) are avatars, sidebar thumbs, etc.
                if w != Int.max, h != Int.max, w <= 250, h <= 250 { return false }
                // Narrow portrait images (w ≤ 200, taller than wide) are author photos
                if w != Int.max, h != Int.max, w < h, w <= 200 { return false }
                // Skip small URL-resized images (e.g. ?w=150 author thumbnails)
                if let urlComps = URLComponents(string: src),
                   let wParam = urlComps.queryItems?.first(where: { $0.name == "w" })?.value,
                   let urlWidth = Int(wParam), urlWidth <= 150 {
                    return false
                }
                let srcLower = src.lowercased()
                let imgId = (try? img.attr("id"))?.lowercased() ?? ""
                let alt = (try? img.attr("alt"))?.lowercased() ?? ""
                if srcLower.contains(".svg") { return false }
                if (try? img.attr("itemprop")) == "logo" { return false }
                let chromeWords = [
                    "logo", "flag", "icon", "badge", "spinner",
                    "facebook", "twitter", "instagram", "pinterest", "tiktok",
                    "furniture", "share", "follow", "comment", "thumbnail",
                    "banner", "bkgd", "headshot"
                ]
                // Word-segment matching (same as standard pipeline)
                let segmentDelims: Set<Character> = ["_", "-", ".", "/", " ", "?", "&", "="]
                let segments = { (text: String) -> Set<Substring> in
                    Set(text.split { segmentDelims.contains($0) })
                }
                let idSegs = segments(imgId)
                let altSegs = segments(alt)
                let srcSegs = segments(srcLower)
                for word in chromeWords {
                    let w = Substring(word)
                    if idSegs.contains(w) || altSegs.contains(w) || srcSegs.contains(w) { return false }
                }
                // Profile images: avatars and author headshots (same as standard pipeline)
                if srcLower.contains("/avatar/") || srcLower.contains("/avatars/")
                    || srcLower.contains("/avatar.") || srcLower.contains("/avatar_")
                    || srcLower.contains("/authors/")
                    || imgId.contains("avatar") { return false }
                // Skip images whose alt text marks them as structural/decorative
                if alt.hasPrefix("background") || alt.hasPrefix("foreground") { return false }
                // Skip images inside <a> links to different pages (navigation/promo thumbnails).
                // Allow links to image files — a common lightbox/zoom pattern.
                let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif"]
                var walk: Element? = img.parent()
                for _ in 0..<5 {
                    guard let el = walk else { break }
                    if el.tagName() == "a",
                       let href = try? el.attr("href"), !href.isEmpty,
                       let linkURL = URL(string: href, relativeTo: pageURL) {
                        let ext = linkURL.pathExtension.lowercased()
                        if imageExtensions.contains(ext) { break }
                        let linkPath = linkURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let pagePath = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !linkPath.isEmpty && linkPath != pagePath { return false }
                        break
                    }
                    walk = el.parent()
                }
                return true
            })
        }).first {
            heroImageURL = try? firstImg.attr("src")
        }

        // Fall back to OpenGraph image if no <img> hero found
        if heroImageURL == nil {
            heroImageURL = try extractOpenGraphImage(from: doc, baseURL: pageURL)
        }

        // Detect empty content (e.g. JS-rendered SPAs with no server-side HTML).
        let plainText = (try? doc.body()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count
        if plainText.count < 50 {
            throw NSError(domain: "PageCacheService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Cleaned content too short (\(plainText.count) chars) — page may require JavaScript"
            ])
        }

        let cleanedHTML = try doc.outerHtml()
        return FullPipelineResult(cleanedHTML: cleanedHTML, heroImageURL: heroImageURL, wordCount: wordCount)
    }

    // MARK: - RSS content fallback pipeline

    /// Cleans RSS content:encoded HTML for display in the reader template.
    /// Unlike the standard pipeline, this skips Readability extraction since
    /// the RSS content IS the article text. Only strips unsafe/interactive elements.
    func cleanRSSContent(html: String, baseURL: URL) throws -> PipelineResult {
        let doc = try SwiftSoup.parseBodyFragment(html, baseURL.absoluteString)
        guard let body = doc.body() else {
            throw NSError(domain: "PageCacheService", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "RSS content could not be parsed"
            ])
        }

        // Strip unsafe/interactive elements
        try doc.select("script").remove()
        try doc.select("style").remove()
        try doc.select("noscript").remove()
        try doc.select("button").remove()
        try doc.select("dialog").remove()
        try doc.select("svg").remove()
        try doc.select("nav").remove()
        try doc.select("form").remove()
        try doc.select("input").remove()
        try doc.select("select").remove()
        try doc.select("textarea").remove()
        try doc.select("iframe").remove()
        try doc.select("video").remove()
        try doc.select("audio").remove()
        try doc.select("[role=tooltip]").remove()
        try doc.select("[data-nosnippet]").remove()
        try doc.select("[class*=newsletter], [id*=newsletter]").remove()
        try stripInterstitials(in: doc)

        try stripEmptyElements(in: doc)

        // Add paragraph structure if content is flat text (no block-level elements).
        // Many RSS feeds provide content:encoded as a single text blob without
        // <p>, <br>, or any structural HTML — this makes them readable.
        let blockTags = "p, div, br, h1, h2, h3, h4, h5, h6, ul, ol, blockquote, pre, hr, table"
        if try body.select(blockTags).isEmpty() {
            let rawHTML = try body.html()
            let paragraphed = addParagraphBreaks(to: rawHTML)
            try body.html(paragraphed)
        }

        let contentHTML = try body.html()

        // Validate: must have meaningful text
        let plainText = (try? body.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count
        guard plainText.count >= 50 else {
            throw NSError(domain: "PageCacheService", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "RSS content too short (\(plainText.count) chars)"
            ])
        }

        let heroImageURL = try doc.select("img[src]").first().flatMap { img -> String? in
            let src = try? img.attr("src")
            guard let src, !src.isEmpty, !src.hasPrefix("data:") else { return nil }
            return src
        }

        let imageCount = (try? doc.select("img"))?.size() ?? 0

        return PipelineResult(
            title: "",
            contentHTML: contentHTML,
            imageCount: imageCount,
            heroImageURL: heroImageURL,
            wordCount: wordCount
        )
    }

    /// Adds `<p>` structure to flat text that lacks block-level HTML.
    /// Tries splitting on double newlines, then single newlines, then
    /// sentence boundaries (grouping ~3 sentences per paragraph).
    private func addParagraphBreaks(to html: String) -> String {
        // Try double newlines
        let doubleChunks = html.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if doubleChunks.count > 1 {
            return doubleChunks.map { "<p>\($0)</p>" }.joined(separator: "\n")
        }

        // Try single newlines
        let singleChunks = html.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if singleChunks.count > 1 {
            return singleChunks.map { "<p>\($0)</p>" }.joined(separator: "\n")
        }

        // No newlines: split on sentence boundaries
        // (period/exclamation/question mark + whitespace + capital letter)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<=[.!?])\\s+(?=[A-Z])",
            options: []
        ) else {
            return "<p>\(html)</p>"
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        guard !matches.isEmpty else {
            return "<p>\(html)</p>"
        }

        // Split at sentence boundaries
        var sentences: [String] = []
        var lastEnd = 0
        for match in matches {
            let chunk = nsHTML.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            sentences.append(chunk.trimmingCharacters(in: .whitespaces))
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < nsHTML.length {
            sentences.append(nsHTML.substring(from: lastEnd).trimmingCharacters(in: .whitespaces))
        }

        // Group every 3 sentences into a paragraph
        var paragraphs: [String] = []
        for i in stride(from: 0, to: sentences.count, by: 3) {
            let end = min(i + 3, sentences.count)
            let group = sentences[i..<end].joined(separator: " ")
            if !group.isEmpty {
                paragraphs.append(group)
            }
        }

        return paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
    }
}
