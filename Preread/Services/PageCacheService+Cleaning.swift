import Foundation
import SwiftSoup

// MARK: - HTML cleaning helpers

extension PageCacheService {

    // MARK: - Tiny image cleanup

    /// Strips `<img>` elements whose explicit width or height attribute is at or below the given threshold.
    /// These are almost always badges, tracking pixels, or tiny decorative icons — not article content.
    func stripTinyImages(in doc: Document, maxDimension: Int) throws {
        let images = try doc.select("img")
        for img in images.reversed() {
            guard img.parent() != nil else { continue }
            let widthStr = try img.attr("width")
            let heightStr = try img.attr("height")
            let width = Int(widthStr)
            let height = Int(heightStr)
            // Remove if either explicit dimension is tiny
            if let w = width, w > 0, w <= maxDimension {
                try img.remove()
            } else if let h = height, h > 0, h <= maxDimension {
                try img.remove()
            }
        }
    }

    /// Constrains author avatar images to a small inline size instead of
    /// rendering full-width. Detected by `alt` containing "avatar" (case-
    /// insensitive) AND the image being roughly square (within 10%). This
    /// combination is a strong signal for byline avatars without risking
    /// false positives on article content images.
    func constrainAvatarImages(in doc: Document) throws {
        for img in try doc.select("img[alt]") {
            let alt = try img.attr("alt").lowercased()
            guard alt.contains("avatar") else { continue }

            let w = Int(try img.attr("width")) ?? 0
            let h = Int(try img.attr("height")) ?? 0
            let maxDim = max(w, h)
            let minDim = min(w, h)
            guard maxDim > 0, Double(minDim) / Double(maxDim) >= 0.9 else { continue }

            try img.attr("width", "100")
            try img.attr("height", "100")
            try img.attr("style", "width:100px; height:100px; border-radius:50%; display:inline; margin:0 8px 0 0")
        }
    }

    /// Strips byline/author images from Readability output.
    ///
    /// Two patterns are detected generically:
    ///
    /// 1. **Avatar images** — identified by the possessive pattern "'s avatar"
    ///    in alt text (e.g. "Clem 🤗's avatar"), or by "avatar"/"avatars" as a
    ///    segment in the src URL (CDN hostnames like `cdn-avatars.example.com`
    ///    or paths like `/avatars/user.jpg`). The alt check uses the possessive
    ///    form to avoid false positives on articles about the movie "Avatar".
    ///
    /// 2. **Headshot images** — alt contains "headshot" or starts with "photo of",
    ///    both dimensions present and ≤ 200px, roughly square (aspect ratio ≥ 0.8).
    func stripBylineImages(in doc: Document) throws {
        let segmentDelims: Set<Character> = ["_", "-", ".", "/", " ", "?", "&", "="]
        for img in try doc.select("img").reversed() {
            guard img.parent() != nil else { continue }
            let alt = try img.attr("alt").lowercased().trimmingCharacters(in: .whitespaces)
            let src = try img.attr("src").lowercased()

            // Pattern 1a: Avatar images identified by possessive alt text
            // ("Clem's avatar", "ben burtenshaw's avatar"). The possessive
            // form is universal for author avatars and never matches movie
            // titles like "Avatar: The Way of Water".
            let isAvatarAlt = alt.contains("'s avatar") || alt.contains("\u{2019}s avatar")

            // Pattern 1b: Avatar images identified by src URL — CDN hostnames
            // or paths containing "avatar"/"avatars" as a segment.
            let srcSegments = Set(src.split { segmentDelims.contains($0) })
            let isAvatarSrc = srcSegments.contains("avatar") || srcSegments.contains("avatars")

            if isAvatarAlt || isAvatarSrc {
                try img.remove()
                continue
            }

            // Pattern 2: Headshot images — require explicit small square dimensions.
            guard alt.contains("headshot") || alt.hasPrefix("photo of") else { continue }
            let w = Int(try img.attr("width")) ?? 0
            let h = Int(try img.attr("height")) ?? 0
            guard w > 0, h > 0, w <= 200, h <= 200 else { continue }
            let ratio = Double(min(w, h)) / Double(max(w, h))
            guard ratio >= 0.8 else { continue }

            try img.remove()
        }
    }

    // MARK: - Linked thumbnail card cleanup

    /// Removes "related article" cards — containers that hold a small linked thumbnail alongside
    /// a headline linking to a different page. These are sidebar/related-story widgets that
    /// Readability sometimes absorbs into the article body.
    ///
    /// A card is identified generically: a container element (`div`, `li`, `article`) that
    /// contains both (a) a small image (explicit width ≤ 240 or explicit height ≤ 160) and
    /// (b) an anchor linking to a different path on the same site or an external site.
    /// Only removes when the image is itself wrapped in an anchor to a different page.
    func stripLinkedThumbnailCards(in doc: Document, pageURL: URL) throws {
        let pagePath = pageURL.path.lowercased()
        let containers = try doc.select("div, li, article")

        for container in containers.reversed() {
            guard container.parent() != nil else { continue }

            // Skip large containers — a related-article card is compact (thumbnail +
            // headline + maybe a short blurb). If the container has substantial text
            // content it is a structural wrapper, not a card widget.
            let textLength = (try? container.text().count) ?? 0
            guard textLength < 500 else { continue }

            // Must have at least one small image (explicit dimensions)
            let imgs = try container.select("img[width], img[height]")
            guard !imgs.isEmpty() else { continue }

            let hasSmallLinkedImage = try imgs.array().contains { img in
                let w = Int(try img.attr("width")) ?? Int.max
                let h = Int(try img.attr("height")) ?? Int.max
                guard w <= 240 || h <= 160 else { return false }

                // Walk up from image to find an enclosing <a> (within the container).
                // The anchor may be several levels up (e.g. img → picture → div → a).
                var node: Element? = img.parent()
                var anchor: Element?
                while let current = node {
                    if current === container { break }
                    if current.tagName() == "a" { anchor = current; break }
                    node = current.parent()
                }
                guard let anchor else { return false }
                let href = (try? anchor.attr("href"))?.lowercased() ?? ""
                guard !href.isEmpty, href != "#" else { return false }

                // Link must point to a different page
                return !href.contains(pagePath) || pagePath.count < 2
            }

            guard hasSmallLinkedImage else { continue }

            // Must also contain a headline linking elsewhere (h2-h6 with an anchor)
            let headlines = try container.select("h2 a[href], h3 a[href], h4 a[href], h5 a[href], h6 a[href]")
            guard !headlines.isEmpty() else { continue }

            try container.remove()
        }
    }

    // MARK: - Badge cluster cleanup

    /// Removes `<p>` elements whose only content is linked images with no meaningful text.
    /// This pattern (a row of `<a><img></a>` with no surrounding words) is almost always a
    /// badge/shield strip (build status, version, license, etc.) rather than article content.
    func stripBadgeClusters(in doc: Document) throws {
        let paragraphs = try doc.select("p")
        for p in paragraphs.reversed() {
            guard p.parent() != nil else { continue }
            // Check that every child node is either whitespace or an <a> containing only an <img>.
            // Only remove if there are 2+ images — a single linked image is usually content.
            var imageCount = 0
            var isBadgeCluster = true
            for node in p.getChildNodes() {
                if let textNode = node as? TextNode {
                    if !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        isBadgeCluster = false
                        break
                    }
                    continue
                }
                guard let element = node as? Element else {
                    isBadgeCluster = false
                    break
                }
                if element.tagName() == "a" {
                    // Link must contain exactly one child: an <img>
                    let linkChildren = element.children().array()
                    let linkHasText = element.getChildNodes().contains { node in
                        if let t = node as? TextNode {
                            return !t.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        return false
                    }
                    if linkChildren.count == 1, linkChildren[0].tagName() == "img", !linkHasText {
                        imageCount += 1
                    } else {
                        isBadgeCluster = false
                        break
                    }
                } else if element.tagName() == "img" {
                    imageCount += 1
                } else {
                    isBadgeCluster = false
                    break
                }
            }
            if isBadgeCluster && imageCount >= 2 {
                try p.remove()
            }
        }
    }

    // MARK: - Aria-hidden content recovery

    /// Strips `aria-hidden` from content elements (paragraphs, headings, list
    /// items, blockquotes, table cells) so that Readability and the full pipeline
    /// don't skip JS-toggled article text. Some CMS platforms use
    /// `aria-hidden="true"` as a progressive-disclosure mechanism — the attribute
    /// is removed client-side after a JS check, but since we disable JS it
    /// persists and hides the article body. Structural/decorative elements
    /// (divs, spans, anchors) keep their aria-hidden so the full pipeline's
    /// blanket removal still catches overlays and popovers.
    func stripAriaHiddenFromContent(in doc: Document) throws {
        let contentSelector = "p[aria-hidden], h1[aria-hidden], h2[aria-hidden], h3[aria-hidden], h4[aria-hidden], h5[aria-hidden], h6[aria-hidden], blockquote[aria-hidden], li[aria-hidden], td[aria-hidden], th[aria-hidden]"
        for el in try doc.select(contentSelector) {
            try el.removeAttr("aria-hidden")
        }
    }

    // MARK: - Interstitial cleanup

    /// Removes common in-article interstitials like "Article continues below"
    /// and "Continue reading below", plus JS-dependent embed placeholders
    /// whose only content is "Loading..." without JavaScript.
    func stripInterstitials(in doc: Document) throws {
        let interstitialPhrases: Set<String> = [
            "article continues below",
            "continue reading below",
            "story continues below",
            "loading...",
            "loading\u{2026}",
        ]

        // Check spans, paragraphs, and divs for exact interstitial text.
        // Use ownText() to match direct text content, not descendant text.
        let candidates = try doc.select("span, p, div")
        for el in candidates.reversed() {
            guard el.parent() != nil else { continue }
            let text = (try? el.ownText())?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if interstitialPhrases.contains(text) {
                try el.remove()
            }
        }
    }

    // MARK: - Empty element cleanup

    /// Removes elements that contain only whitespace after our cleaning passes
    /// have stripped their functional content (icons, buttons, etc.).
    /// Runs multiple passes since removing a child can leave its parent empty.
    /// Preserves void elements (img, br, hr, input) and table structure.
    func stripEmptyElements(in doc: Document) throws {
        let preservedTags: Set<String> = [
            "img", "br", "hr", "input", "source", "meta", "link",
            "canvas", "iframe", "embed", "object",
            "table", "thead", "tbody", "tfoot", "tr", "th", "td",
        ]
        // Multiple passes: removing empty <li> can leave <ul> empty,
        // removing empty <div> can leave its parent <div> empty, etc.
        for _ in 0..<6 {
            let candidates = try doc.select("li, span, div, p, ul, ol, section, aside, header, footer, fieldset, label")
            var changed = false
            for element in candidates.reversed() {
                guard element.parent() != nil else { continue }
                let tag = element.tagName()
                guard !preservedTags.contains(tag) else { continue }
                // Empty if no child elements and text is whitespace-only
                let hasChildElements = !element.children().isEmpty()
                if hasChildElements { continue }
                let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    try element.remove()
                    changed = true
                }
            }
            if !changed { break }
        }
    }

    // MARK: - Sticky/fixed positioning cleanup

    /// Neutralises sticky and fixed positioning in cached pages so site
    /// headers, toolbars, and floating elements don't overlay article content.
    /// Strips inline position styles and injects a CSS rule to catch
    /// stylesheet-defined positioning.
    func stripStickyPositioning(in doc: Document) throws {
        // Remove inline position:sticky/fixed from style attributes
        for el in try doc.select("[style*=position]") {
            guard let style = try? el.attr("style") else { continue }
            let cleaned = style.replacingOccurrences(
                of: #"position\s*:\s*(sticky|fixed)"#,
                with: "position:static",
                options: .regularExpression
            )
            if cleaned != style {
                try el.attr("style", cleaned)
            }
        }
        // Inject CSS rules to override stylesheet-defined sticky/fixed.
        // We can't use `* { position: static }` because that would break
        // legitimate relative/absolute positioning used for layout.
        // Instead, use the cascade: any element whose computed position
        // would be sticky or fixed gets overridden. CSS doesn't have a
        // selector for computed values, but we can target common sticky
        // patterns: header, [role=banner], and the generic sticky class.
        // The inline style cleanup above handles the rest.
        if let head = doc.head() {
            try head.prepend("""
                <style id="preread-unstick">
                header, [role="banner"], [style*="position"] {
                    position: static !important;
                }
                </style>
                """)
        }
    }

    // MARK: - Image layout cleanup

    /// Strips inline styles from `<img>` elements that break layout outside their original
    /// page context. Some sites use `position:absolute; width:100%; height:100%`
    /// to fill a parent container — once Readability extracts the image, that container is
    /// gone and the image becomes invisible (zero height). This removes the style attribute
    /// entirely and cleans up framework-specific attributes that add noise.
    func stripImageLayoutStyles(in doc: Document) throws {
        let images = try doc.select("img")
        for img in images {
            try img.removeAttr("style")
            try img.removeAttr("class")
            try img.removeAttr("loading")
            try img.removeAttr("data-nimg")
            try img.removeAttr("data-chromatic")
        }
    }

    /// Promotes image URLs from `<noscript>` fallbacks onto their JS-dependent
    /// sibling `<img>` tags. Many sites use a pattern where `<noscript>` holds
    /// an `<img>` with a real `src`, while a sibling `<img>` outside has no `src`
    /// and relies on JavaScript to populate it. Since we strip `<noscript>` later
    /// (it causes layout gaps), this copies the real URL before it's lost.
    func promoteNoscriptImages(in doc: Document) throws {
        for noscript in try doc.select("noscript").array() {
            let noscriptHTML = try noscript.html()
            guard noscriptHTML.contains("<img") else { continue }

            // Parse the noscript content to extract img src
            let fragment = try SwiftSoup.parseBodyFragment(noscriptHTML)
            guard let noscriptImg = try fragment.select("img[src]").first() else { continue }
            let realSrc = try noscriptImg.attr("src")
            guard !realSrc.isEmpty, !realSrc.hasPrefix("data:") else { continue }

            // Look for a sibling <img> with a placeholder src.
            // Some lazy-loaders place the <img> after the <noscript>,
            // others place it before (e.g. EWWW Image Optimizer).
            let siblings: [Element] = [
                try noscript.nextElementSibling(),
                try noscript.previousElementSibling()
            ].compactMap { $0 }

            var promoted = false
            for sibling in siblings {
                guard sibling.tagName() == "img" else { continue }
                let sibSrc = try sibling.attr("src")
                if sibSrc.isEmpty || sibSrc.hasPrefix("data:") {
                    try sibling.attr("src", realSrc)
                    promoted = true
                    break
                }
            }
            if promoted { continue }

            // No sibling img to promote into — extract the <img> from
            // the noscript and place it directly in the DOM. Handles
            // cases where images exist only inside <noscript> with no
            // JS-placeholder sibling.
            let imgHTML = try noscriptImg.outerHtml()
            try noscript.before(imgHTML)
        }
    }

    /// Recovers real image URLs for `<img>` tags that use placeholder `src` values.
    /// Many sites use JavaScript-based lazy loading where the real image URL lives
    /// in a data attribute (`data-lazy-src`, `data-src`, `data-original`, etc.)
    /// and `src` is set to a tiny placeholder (data URI, 1x1 GIF, fallback image).
    /// Since we fetch static HTML, the JS swap never runs and images stay blank.
    /// This method promotes the real URLs to standard attributes before Readability.
    func recoverPlaceholderImages(in doc: Document) throws {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "tiff"]
        let images = try doc.select("img")
        for img in images {
            let src = try img.attr("src")
            let srcIsPlaceholder = src.isEmpty
                || src.hasPrefix("data:")
                || src.contains("lazyload")
                || src.contains("fallback")
                || src.contains("spacer")
                || src.contains("blank.gif")
                || src.contains("grey-placeholder")
                || src.contains("placeholder")

            if srcIsPlaceholder {
                // Try well-known lazy-load attributes first (order matters when
                // multiple exist — e.g. data-src may hold a low-res fallback while
                // data-lazy-src holds the full-res version).
                let prioritySrcAttrs = ["data-lazy-src", "data-src", "data-original", "data-orig-file"]
                for attr in prioritySrcAttrs {
                    let value = try img.attr(attr)
                    if !value.isEmpty, !value.hasPrefix("data:") {
                        try img.attr("src", value)
                        try img.removeAttr(attr)
                        break
                    }
                }

                // Fallback: scan ALL data-* attributes for any whose name ends
                // with "src" (but not "srcset") and whose value looks like a URL.
                // Catches CMS-specific attributes like data-runner-src, data-hi-res-src,
                // data-full-src, etc. without hardcoding each one.
                let srcAfterPriority = try img.attr("src")
                if srcAfterPriority.isEmpty || srcAfterPriority.hasPrefix("data:") {
                    if let attrs = img.getAttributes() {
                        for attr in attrs {
                            let key = attr.getKey()
                            guard key.hasPrefix("data-"),
                                  key.hasSuffix("src"),
                                  !key.hasSuffix("srcset") else { continue }
                            let value = attr.getValue()
                            if !value.isEmpty, !value.hasPrefix("data:"),
                               value.hasPrefix("http") || value.hasPrefix("//") || value.hasPrefix("/") {
                                try img.attr("src", value)
                                try img.removeAttr(key)
                                break
                            }
                        }
                    }
                }

                // Try data-srcs (JSON-encoded lazy-load, e.g. Business Insider)
                // Format: {"https://example.com/image.jpg":{"contentType":"image/jpeg",...}}
                let srcAfterLazy = try img.attr("src")
                if srcAfterLazy.isEmpty || srcAfterLazy.hasPrefix("data:") {
                    let dataSrcs = try img.attr("data-srcs")
                    if !dataSrcs.isEmpty,
                       let jsonData = dataSrcs.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let firstURL = json.keys.first(where: { $0.hasPrefix("http") }) {
                        try img.attr("src", firstURL)
                        try img.removeAttr("data-srcs")
                    }
                }

                // Promote data-*-srcset → srcset if srcset is empty.
                // Try well-known attributes first, then scan data-* generically.
                let srcset = try img.attr("srcset")
                if srcset.isEmpty {
                    let prioritySrcsetAttrs = ["data-lazy-srcset", "data-srcset"]
                    var found = false
                    for attr in prioritySrcsetAttrs {
                        let value = try img.attr(attr)
                        if !value.isEmpty {
                            try img.attr("srcset", value)
                            try img.removeAttr(attr)
                            found = true
                            break
                        }
                    }
                    if !found, let attrs = img.getAttributes() {
                        for attr in attrs {
                            let key = attr.getKey()
                            guard key.hasPrefix("data-"), key.hasSuffix("srcset") else { continue }
                            let value = attr.getValue()
                            if !value.isEmpty {
                                try img.attr("srcset", value)
                                try img.removeAttr(key)
                                break
                            }
                        }
                    }
                }

                // Promote data-*-sizes → sizes if sizes is empty.
                let sizes = try img.attr("sizes")
                if sizes.isEmpty {
                    let prioritySizesAttrs = ["data-lazy-sizes", "data-sizes"]
                    var found = false
                    for attr in prioritySizesAttrs {
                        let value = try img.attr(attr)
                        if !value.isEmpty {
                            try img.attr("sizes", value)
                            try img.removeAttr(attr)
                            found = true
                            break
                        }
                    }
                    if !found, let attrs = img.getAttributes() {
                        for attr in attrs {
                            let key = attr.getKey()
                            guard key.hasPrefix("data-"), key.hasSuffix("sizes") else { continue }
                            let value = attr.getValue()
                            if !value.isEmpty {
                                try img.attr("sizes", value)
                                try img.removeAttr(key)
                                break
                            }
                        }
                    }
                }

                try img.removeAttr("aria-hidden")

                // Strip lazy-load classes/attributes so Readability's fixLazyImages
                // doesn't re-process images we already recovered
                try img.removeAttr("lazy-loadable")
                let className = try img.attr("class")
                if className.lowercased().contains("lazy") {
                    let cleaned = className
                        .components(separatedBy: " ")
                        .filter { !$0.lowercased().contains("lazy") }
                        .joined(separator: " ")
                    try img.attr("class", cleaned)
                }
            }

            // Fallback: if src is still a data URI placeholder and parent <a> links
            // to an image file, use the href as src
            let currentSrc = try img.attr("src")
            if currentSrc.hasPrefix("data:") {
                if let parent = img.parent(), parent.tagName() == "a" {
                    let href = try parent.attr("href")
                    if !href.isEmpty, !href.hasPrefix("data:") {
                        let pathComponent = URL(string: href)?.pathExtension.lowercased() ?? ""
                        if imageExtensions.contains(pathComponent) {
                            try img.attr("src", href)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Picture element unwrap

    /// Unwraps `<picture>` elements to just their `<img>` child, removing
    /// `<source>` elements. `<picture>` is a responsive image container that
    /// adds complexity for offline reader mode — the `<source srcset>` URLs
    /// reference external servers and won't work offline, and Readability
    /// sometimes drops the `<img>` fallback when the DOM is complex.
    ///
    /// If a `<picture>` has no `<img>` child, the first `<source srcset>` URL
    /// is promoted to a new `<img>` so the image isn't lost entirely.
    func unwrapPictureElements(in doc: Document) throws {
        for picture in try doc.select("picture").array() {
            let sources = try picture.select("source")

            // Extract the best URL from <source> srcset or data-srcset
            var sourceURL: String?
            for source in sources {
                let srcset = try source.attr("srcset")
                let dataSrcset = try source.attr("data-srcset")
                let value = srcset.isEmpty ? dataSrcset : srcset
                let url = value.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                if !url.isEmpty {
                    sourceURL = url
                    break
                }
            }

            if try picture.select("img").isEmpty() {
                // No <img> fallback — create one from source
                if let url = sourceURL {
                    try picture.appendElement("img").attr("src", url)
                }
            } else if let img = try picture.select("img").first() {
                // <img> exists but may lack src (lazy-loaded with data: placeholder)
                let src = try img.attr("src")
                if src.isEmpty || src.hasPrefix("data:") {
                    if let url = sourceURL {
                        try img.attr("src", url)
                    }
                }
            }
            try sources.remove()
            try picture.unwrap()
        }
    }

    // MARK: - Caption toggle cleanup

    /// Strips orphaned caption toggle UI text — some news sites wrap
    /// interactive show/hide caption controls in `<b>` tags. After
    /// JavaScript/button stripping these survive as meaningless visible text
    /// like "hide caption" or "toggle caption".
    func stripCaptionToggles(in doc: Document) throws {
        let captionToggles: Set<String> = ["hide caption", "toggle caption", "show caption"]
        for bold in try doc.select("b").array() {
            let text = try bold.text().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if captionToggles.contains(text) {
                try bold.remove()
            }
        }
    }

    // MARK: - OpenGraph image extraction

    /// Extracts the OpenGraph image URL (`og:image`) from the document's
    /// `<meta>` tags. Falls back to `twitter:image` if og:image is absent.
    /// Returns nil if no suitable image meta tag is found.
    ///
    /// This provides a reliable hero/thumbnail fallback for pages where the
    /// main article image is only declared in meta tags (common with
    /// JS-rendered pages) and not present as an `<img>` in the body.
    func extractOpenGraphImage(from doc: Document, baseURL: URL) throws -> String? {
        // Try og:image first (most widely used)
        if let ogMeta = try doc.select("meta[property=og:image]").first() {
            let content = try ogMeta.attr("content")
            if !content.isEmpty, let url = URL(string: content, relativeTo: baseURL) {
                // Upgrade http to https so ATS doesn't block the download
                var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                if components?.scheme == "http" { components?.scheme = "https" }
                return components?.url?.absoluteString ?? url.absoluteString
            }
        }
        // Fall back to twitter:image (some sites only set this)
        if let twitterMeta = try doc.select("meta[name=twitter:image]").first() {
            let content = try twitterMeta.attr("content")
            if !content.isEmpty, let url = URL(string: content, relativeTo: baseURL) {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                if components?.scheme == "http" { components?.scheme = "https" }
                return components?.url?.absoluteString ?? url.absoluteString
            }
        }
        return nil
    }

    // MARK: - Sibling image deduplication

    /// A regex that matches dimension suffixes like `-640x426`, `-1024x648`, `-980x652`,
    /// plus an optional trailing CDN hash like `-1774644559` (appended to cropped variants).
    private static let dimensionSuffixPattern = try! NSRegularExpression(
        pattern: #"-\d+x\d+(-\d+)?"#
    )

    /// Strips the dimension suffix from an image URL to produce a base key for comparison.
    /// e.g. "https://cdn.example.com/image-640x426.jpg" → "https://cdn.example.com/image.jpg"
    /// e.g. "https://cdn.example.com/image-1152x648-1774644559.jpg" → "https://cdn.example.com/image.jpg"
    func imageDedupKey(for src: String) -> String {
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        return Self.dimensionSuffixPattern.stringByReplacingMatches(
            in: src, range: range, withTemplate: ""
        )
    }

    /// Removes duplicate sibling `<img>` elements that share the same base URL
    /// (differing only in dimension suffixes like `-640x426` vs `-1024x648`).
    /// Keeps the variant with the largest width. This handles responsive image
    /// patterns where sites place multiple resolution variants as sibling elements.
    func deduplicateSiblingImages(in doc: Document) throws {
        // Group all images by (parent identity, dedup key)
        struct ParentKey: Hashable {
            let parentHash: Int  // ObjectIdentifier-like hash for the parent element
            let dedupKey: String
        }

        var groups: [ParentKey: [Element]] = [:]
        for img in try doc.select("img[src]") {
            guard let parent = img.parent() else { continue }
            let src = try img.attr("src")
            guard !src.isEmpty, !src.hasPrefix("data:") else { continue }
            let key = imageDedupKey(for: src)
            let pk = ParentKey(parentHash: ObjectIdentifier(parent).hashValue, dedupKey: key)
            groups[pk, default: []].append(img)
        }

        for (_, group) in groups where group.count > 1 {
            // Keep the image with the largest width attribute
            let sorted = group.sorted { a, b in
                let wa = Int((try? a.attr("width")) ?? "") ?? 0
                let wb = Int((try? b.attr("width")) ?? "") ?? 0
                return wa > wb
            }
            // Remove all but the first (largest)
            for img in sorted.dropFirst() {
                try img.remove()
            }
        }
    }

    // MARK: - Custom element unwrapping

    /// Unwraps HTML custom elements (tags containing a hyphen, per the HTML spec)
    /// such as `<mol-permabox>`, `<ad-slot>`, `<react-partial>`.
    ///
    /// CMS platforms wrap supplementary content in custom elements which creates
    /// separate scoring containers in Readability. This fragments article text and
    /// can cause Readability to pick a dense sidebar block (e.g. a quoted statement)
    /// over the main article body. Unwrapping merges their children into the parent
    /// so Readability sees one continuous block.
    func unwrapCustomElements(in doc: Document) throws {
        guard let allElements = try? doc.getAllElements() else { return }
        for element in allElements.reversed() {
            guard element.parent() != nil else { continue }
            let tag = element.tagName()
            guard tag.contains("-") else { continue }
            // Don't unwrap standard web component-like tags that are already handled
            guard tag != "br" else { continue }
            try element.unwrap()
        }
    }

    // MARK: - Image-only div flattening

    /// Unwraps `<div>` elements that contain only images and/or other divs (no text).
    /// This promotes images trapped in deep wrapper hierarchies up to the nearest
    /// text-containing ancestor so Readability can score them as article content.
    func flattenImageOnlyDivs(in doc: Document) throws {
        for _ in 0..<6 {
            guard let allDivs = try? doc.select("div") else { break }
            var changed = false
            for div in allDivs.reversed() {
                guard div.parent() != nil else { continue }
                // Skip if it has any direct text
                let hasText = div.getChildNodes().contains { node in
                    if let text = node as? TextNode {
                        return !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return false
                }
                guard !hasText else { continue }
                // Skip if it contains non-div, non-img element children
                let children = div.children().array()
                guard !children.isEmpty else { continue }
                let allImageOrDiv = children.allSatisfy { ["div", "img", "figcaption"].contains($0.tagName()) }
                guard allImageOrDiv else { continue }
                // Must contain at least one img (directly or nested)
                guard (try? div.select("img"))?.isEmpty() == false else { continue }
                do {
                    try div.unwrap()
                    changed = true
                } catch { continue }
            }
            if !changed { break }
        }
    }

    // MARK: - Post-Readability image recovery

    /// Recovers article images that Readability dropped during extraction.
    /// Readability discards `<p>` elements with zero text content, which includes
    /// image-only paragraphs. This method compares images in the pre-Readability
    /// content areas against the Readability output and re-injects missing images
    /// at their correct positions by matching neighboring paragraph text.
    func recoverDroppedImages(
        contentHTML: String,
        preDoc: Document,
        heroImageURL: String?,
        pageURL: URL
    ) throws -> String {
        let recoveryDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
        let existingSrcs = Set(
            try recoveryDoc.select("img[src]").array().compactMap { try? $0.attr("src") }
        )

        // Collect images from content landmarks in the pre-Readability HTML.
        // Prefer scoped selectors to avoid sidebar/chrome images.
        let scopedSelectors = [
            "article img[src]", "main img[src]",
            "[role=main] img[src]", "[itemprop=articleBody] img[src]",
        ]
        let preImages: [Element]
        if let scoped = scopedSelectors.lazy.compactMap({ sel in
            try? preDoc.select(sel)
        }).first(where: { !$0.isEmpty() }) {
            preImages = scoped.array()
        } else {
            preImages = try preDoc.select("img[src]").array()
        }

        var injected = false
        for img in preImages {
            guard let src = try? img.attr("src"), !src.isEmpty,
                  !src.hasPrefix("data:") else { continue }
            // Skip images already in Readability output or injected as hero
            guard !existingSrcs.contains(src) else { continue }
            if let hero = heroImageURL, src == hero { continue }

            // Walk up to find the block-level container this image sits in.
            // After wrapStandaloneImages, the image is inside a <p> wrapper.
            // Images may also be inside inline wrappers (<a>, <span>) — walk
            // past those to reach the block-level parent that has sibling paragraphs.
            var anchor: Element = img
            let inlineTags: Set<String> = ["a", "span", "em", "strong", "b", "i"]
            while let parent = anchor.parent() {
                if parent.tagName() == "p" {
                    anchor = parent
                    break
                }
                if inlineTags.contains(parent.tagName()) {
                    anchor = parent
                } else {
                    break
                }
            }
            guard let container = anchor.parent() else { continue }
            let siblings = container.children().array()
            guard let anchorIndex = siblings.firstIndex(where: { $0 === anchor }) else { continue }

            // Find the nearest following text-bearing element (paragraph or heading)
            var followingText: String?
            for i in (anchorIndex + 1)..<siblings.count {
                let tag = siblings[i].tagName()
                guard tag == "p" || tag.hasPrefix("h") else { continue }
                let text = (try? siblings[i].text())?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count >= 20 {
                    followingText = text
                    break
                }
            }
            guard let targetText = followingText else { continue }

            // Locate this text in the Readability output and inject the image before it
            for el in try recoveryDoc.select("p, h1, h2, h3, h4, h5, h6") {
                let elText = (try? el.text())?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if elText == targetText {
                    let imgHTML = try img.outerHtml()
                    try el.before("<p>\(imgHTML)</p>")
                    injected = true
                    break
                }
            }
        }

        if injected {
            return try recoveryDoc.body()?.html() ?? contentHTML
        }
        return contentHTML
    }

    // MARK: - Standalone image wrapping

    /// Wraps standalone `<img>` elements (direct children of block containers) in
    /// their own `<p>` tags so they're valid block-level content for Readability.
    /// Previously these were merged INTO adjacent text paragraphs, but Readability
    /// would often strip the `<img>` from the merged paragraph while keeping the
    /// text — causing article images to be silently dropped. Wrapping in a separate
    /// `<p>` keeps images as distinct scored elements within well-scored containers.
    func wrapStandaloneImages(in doc: Document) throws {
        let blockContainers: Set<String> = ["div", "section", "article", "main"]
        let images = try doc.select("img[src]")
        for img in images {
            guard let parent = img.parent(),
                  blockContainers.contains(parent.tagName()) else { continue }
            let wrapper = try Element(Tag("p"), "")
            try img.before(wrapper)
            try wrapper.appendChild(img)
        }
    }

    // MARK: - DOM flattening

    /// Unwraps `<div>` elements that serve purely as layout wrappers — those with exactly
    /// one element child and no meaningful direct text. Runs multiple passes until no more
    /// wrappers can be collapsed. This is critical for Readability to work correctly on
    /// sites that nest article content inside deep grid/flex layout structures.
    func flattenSingleChildDivs(in doc: Document) {
        let preservedAncestors: Set<String> = ["header", "footer"]
        for _ in 0..<6 {
            guard let allDivs = try? doc.select("div") else { break }
            var changed = false
            // Process in reverse (bottom-up) so inner wrappers are handled first
            for div in allDivs.reversed() {
                guard div.parent() != nil else { continue }
                // Don't unwrap divs inside <header> or <footer>
                var ancestor = div.parent()
                var insidePreserved = false
                while let a = ancestor {
                    if preservedAncestors.contains(a.tagName()) {
                        insidePreserved = true
                        break
                    }
                    ancestor = a.parent()
                }
                guard !insidePreserved else { continue }
                // Count element children — only unwrap if there's exactly one child element
                let elementChildren = div.children().array()
                guard elementChildren.count == 1 else { continue }
                // Only unwrap if the single child is a block/content element
                let childTag = elementChildren[0].tagName()
                let unwrapChildTags: Set<String> = [
                    "div", "img", "picture", "figure"
                ]
                guard unwrapChildTags.contains(childTag) else { continue }
                // Skip if the div has meaningful direct text
                var hasDirectText = false
                for node in div.getChildNodes() {
                    if let textNode = node as? TextNode,
                       !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasDirectText = true
                        break
                    }
                }
                guard !hasDirectText else { continue }
                // Unwrap: replace this div with its children
                do {
                    try div.unwrap()
                    changed = true
                } catch {
                    continue
                }
            }
            if !changed { break }
        }
    }
}
