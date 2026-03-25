import Foundation
import SwiftSoup
import SwiftReadability

// MARK: - Config

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

// MARK: - Usage

guard CommandLine.arguments.count >= 2 else {
    print("Usage: CacheDebugger <URL> [--full]")
    print("")
    print("Fetches a URL and runs the Preread caching pipeline, saving")
    print("intermediate HTML files to ./output/ for inspection.")
    print("")
    print("Steps saved:")
    print("  1_raw.html           – Raw HTML from the server")
    print("  2_cleaned.html       – After SwiftSoup cleaning (scripts, noscript, styles removed)")
    print("  3_flattened.html     – After image/div flattening passes")
    print("  4_readability.html   – Readability extracted content (just the article HTML)")
    print("")
    print("Options:")
    print("  --full    Run the full-page pipeline instead of standard/reader mode")
    exit(1)
}

let urlString = CommandLine.arguments[1]
let isFullMode = CommandLine.arguments.contains("--full")

guard let pageURL = URL(string: urlString) else {
    print("Error: Invalid URL '\(urlString)'")
    exit(1)
}

// MARK: - Output directory

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("output", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: outputDir)
try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Helper: strip image layout styles

func stripImageLayoutStyles(in doc: Document) throws {
    let images = try doc.select("img")
    for img in images {
        try img.removeAttr("style")
        try img.removeAttr("class")
        try img.removeAttr("data-nimg")
        try img.removeAttr("data-chromatic")
    }
}

// MARK: - Helper: recover placeholder images from parent anchors

/// Recovers real image URLs for `<img>` tags that use placeholder `src` values
/// (e.g. a 1x1 transparent GIF data URI) when the parent `<a>` tag links to
/// an actual image file.
func recoverPlaceholderImages(in doc: Document) throws {
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "tiff"]
    let images = try doc.select("img")
    for img in images {
        let src = try img.attr("src")
        guard src.hasPrefix("data:") else { continue }

        guard let parent = img.parent(), parent.tagName() == "a" else { continue }
        let href = try parent.attr("href")
        guard !href.isEmpty, !href.hasPrefix("data:") else { continue }

        let pathComponent = URL(string: href)?.pathExtension.lowercased() ?? ""
        guard imageExtensions.contains(pathComponent) else { continue }

        try img.attr("src", href)
        try img.removeAttr("aria-hidden")
    }
}

// MARK: - Helper: unwrap custom elements

func unwrapCustomElements(in doc: Document) throws {
    guard let allElements = try? doc.getAllElements() else { return }
    for element in allElements.reversed() {
        guard element.parent() != nil else { continue }
        let tag = element.tagName()
        guard tag.contains("-") else { continue }
        guard tag != "br" else { continue }
        try element.unwrap()
    }
}

// MARK: - Helper: flatten image-only divs

func flattenImageOnlyDivs(in doc: Document) throws {
    for _ in 0..<6 {
        guard let allDivs = try? doc.select("div") else { break }
        var changed = false
        for div in allDivs.reversed() {
            guard div.parent() != nil else { continue }
            let hasText = div.getChildNodes().contains { node in
                if let text = node as? TextNode {
                    return !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }
            guard !hasText else { continue }
            let children = div.children().array()
            guard !children.isEmpty else { continue }
            let allImageOrDiv = children.allSatisfy { ["div", "img", "figcaption"].contains($0.tagName()) }
            guard allImageOrDiv else { continue }
            guard (try? div.select("img"))?.isEmpty() == false else { continue }
            do {
                try div.unwrap()
                changed = true
            } catch { continue }
        }
        if !changed { break }
    }
}

// MARK: - Helper: flatten single-child divs

func flattenSingleChildDivs(in doc: Document) {
    let preservedAncestors: Set<String> = ["header", "footer"]
    for _ in 0..<6 {
        guard let allDivs = try? doc.select("div") else { break }
        var changed = false
        for div in allDivs.reversed() {
            guard div.parent() != nil else { continue }
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
            let elementChildren = div.children().array()
            guard elementChildren.count == 1 else { continue }
            let childTag = elementChildren[0].tagName()
            guard childTag == "div" || childTag == "img" else { continue }
            var hasDirectText = false
            for node in div.getChildNodes() {
                if let textNode = node as? TextNode,
                   !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasDirectText = true
                    break
                }
            }
            guard !hasDirectText else { continue }
            do {
                try div.unwrap()
                changed = true
            } catch { continue }
        }
        if !changed { break }
    }
}

// MARK: - Helper: strip tiny images

func stripTinyImages(in doc: Document, maxDimension: Int) {
    guard let images = try? doc.select("img") else { return }
    for img in images.reversed() {
        guard img.parent() != nil else { continue }
        let widthStr = (try? img.attr("width")) ?? ""
        let heightStr = (try? img.attr("height")) ?? ""
        let width = Int(widthStr)
        let height = Int(heightStr)
        if let w = width, w > 0, w <= maxDimension {
            try? img.remove()
        } else if let h = height, h > 0, h <= maxDimension {
            try? img.remove()
        }
    }
}

// MARK: - Helper: strip linked thumbnail cards

func stripLinkedThumbnailCards(in doc: Document, pageURL: URL) {
    let pagePath = pageURL.path.lowercased()
    guard let containers = try? doc.select("div, li, article") else { return }

    for container in containers.reversed() {
        guard container.parent() != nil else { continue }

        // Skip large containers — a related-article card is compact
        let textLength = (try? container.text().count) ?? 0
        guard textLength < 500 else { continue }

        guard let imgs = try? container.select("img[width], img[height]"),
              !imgs.isEmpty() else { continue }

        let hasSmallLinkedImage = (try? imgs.array().contains { img in
            let w = Int((try? img.attr("width")) ?? "") ?? Int.max
            let h = Int((try? img.attr("height")) ?? "") ?? Int.max
            guard w <= 240 || h <= 160 else { return false }

            // Walk up from image to find an enclosing <a> (within the container)
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

            return !href.contains(pagePath) || pagePath.count < 2
        }) ?? false

        guard hasSmallLinkedImage else { continue }

        guard let headlines = try? container.select("h2 a[href], h3 a[href], h4 a[href], h5 a[href], h6 a[href]"),
              !headlines.isEmpty() else { continue }

        try? container.remove()
    }
}

// MARK: - Helper: strip badge clusters

func stripBadgeClusters(in doc: Document) throws {
    let paragraphs = try doc.select("p")
    for p in paragraphs.reversed() {
        guard p.parent() != nil else { continue }
        // Only remove if 2+ images — a single linked image is usually content.
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

// MARK: - Helper: deduplicate sibling images

/// Regex matching dimension suffixes like -640x426, -1024x648
let dimensionSuffixPattern = try! NSRegularExpression(pattern: #"-\d+x\d+"#)

func imageDedupKey(for src: String) -> String {
    let range = NSRange(src.startIndex..<src.endIndex, in: src)
    return dimensionSuffixPattern.stringByReplacingMatches(
        in: src, range: range, withTemplate: ""
    )
}

/// Removes duplicate sibling `<img>` elements that share the same base URL
/// (differing only in dimension suffixes). Keeps the variant with the largest width.
func deduplicateSiblingImages(in doc: Document) throws {
    struct ParentKey: Hashable {
        let parentHash: Int
        let dedupKey: String
    }

    var groups: [ParentKey: [Element]] = [:]
    for img in try doc.select("img[src]") {
        guard let parent = img.parent() else { continue }
        let src = try img.attr("src")
        guard !src.isEmpty, !src.hasPrefix("data:") else { continue }
        let key = imageDedupKey(for: src)
        guard key != src else { continue }
        let pk = ParentKey(parentHash: ObjectIdentifier(parent).hashValue, dedupKey: key)
        groups[pk, default: []].append(img)
    }

    for (_, group) in groups where group.count > 1 {
        let sorted = group.sorted { a, b in
            let wa = Int((try? a.attr("width")) ?? "") ?? 0
            let wb = Int((try? b.attr("width")) ?? "") ?? 0
            return wa > wb
        }
        for img in sorted.dropFirst() {
            try img.remove()
        }
    }
}

// MARK: - Helper: strip empty elements

func stripEmptyElements(in doc: Document) throws {
    let preservedTags: Set<String> = [
        "img", "br", "hr", "input", "source", "meta", "link",
        "canvas", "iframe", "embed", "object",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td",
    ]
    for _ in 0..<6 {
        let candidates = try doc.select("li, span, div, p, ul, ol, section, aside, header, footer, fieldset, label")
        var changed = false
        for element in candidates.reversed() {
            guard element.parent() != nil else { continue }
            let tag = element.tagName()
            guard !preservedTags.contains(tag) else { continue }
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

// MARK: - Helper: strip sticky/fixed positioning

func stripStickyPositioning(in doc: Document) throws {
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

// MARK: - Helper: save step

func saveStep(_ name: String, html: String) {
    let path = outputDir.appendingPathComponent(name)
    try? html.write(to: path, atomically: true, encoding: .utf8)
    let size = html.utf8.count
    let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    print("  -> \(name) (\(formatted))")
}

// MARK: - Fetch

print("Fetching: \(urlString)")
print("Mode: \(isFullMode ? "full" : "standard")")
print("")

var request = URLRequest(url: pageURL)
request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
request.timeoutInterval = 30

let (data, response) = try await URLSession.shared.data(for: request)

guard let httpResponse = response as? HTTPURLResponse else {
    print("Error: Not an HTTP response")
    exit(1)
}

print("HTTP \(httpResponse.statusCode)")
if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
    print("Content-Type: \(contentType)")
}
print("Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
print("")

let html = String(data: data, encoding: .utf8)
    ?? String(data: data, encoding: .ascii)
    ?? ""

guard !html.isEmpty else {
    print("Error: Empty HTML response")
    exit(1)
}

// MARK: - Step 1: Raw HTML

print("Pipeline steps:")
saveStep("1_raw.html", html: html)

if isFullMode {
    // MARK: - Full mode pipeline

    let doc = try SwiftSoup.parse(html, pageURL.absoluteString)

    // Strip CSP
    let cspMetas = try doc.select("meta[http-equiv=Content-Security-Policy]")
    try cspMetas.remove()

    // Ensure a white background fallback. Many sites rely on browser
    // defaults or don't set an explicit background-color, which makes
    // text illegible when the WebView has a transparent/dark background.
    if let head = doc.head() {
        try head.append("<style>html, body { background-color: #fff !important; }</style>")
    }

    // Strip scripts and noscript fallbacks
    let scripts = try doc.select("script")
    try scripts.remove()
    try doc.select("noscript").remove()

    // Strip navigation
    try doc.select("nav").remove()
    try doc.select("[role=navigation]").remove()
    try doc.select("header[id*=navigation], header[class*=navigation]").remove()

    // Strip comment sections
    try doc.select("#comments, .comments, #disqus_thread").remove()

    // Strip interactive elements that rely on JS
    try doc.select("button").remove()
    try doc.select("dialog").remove()
    try doc.select("svg").remove()
    try doc.select("form").remove()
    try doc.select("input").remove()
    try doc.select("select").remove()
    try doc.select("textarea").remove()

    // Strip elements explicitly marked as hidden
    try doc.select("[aria-hidden=true]").remove()

    // Neutralise sticky/fixed positioning
    try stripStickyPositioning(in: doc)

    // Cascade-remove empty elements left behind by the above stripping
    try stripEmptyElements(in: doc)

    let cleanedHTML = try doc.outerHtml()
    saveStep("2_cleaned.html", html: cleanedHTML)

    print("")
    print("Full mode: no Readability extraction (page saved as-is after cleaning)")

} else {
    // MARK: - Standard mode pipeline

    // Step 2: Clean
    let preDoc = try SwiftSoup.parse(html, pageURL.absoluteString)
    try preDoc.select("script").remove()
    try preDoc.select("noscript").remove()
    try preDoc.select("style").remove()
    try preDoc.select("meta[http-equiv=Content-Security-Policy]").remove()
    try preDoc.select("img.hide-when-no-script").remove()
    try preDoc.select("img[src*=placeholder]").remove()

    try recoverPlaceholderImages(in: preDoc)

    // Strip tiny images (badges, tracking pixels, decorative icons)
    stripTinyImages(in: preDoc, maxDimension: 30)

    // Strip badge clusters (rows of linked images with no text)
    try stripBadgeClusters(in: preDoc)

    try stripImageLayoutStyles(in: preDoc)

    // Strip comment sections — user-generated comments can outweigh article
    // text and confuse Readability's scoring.
    try preDoc.select("#comments, .comments, #disqus_thread").remove()

    // Strip interactive/UI elements that serve no purpose in reader mode
    // and prevent image wrapper divs from being flattened.
    try preDoc.select("button").remove()
    try preDoc.select("dialog").remove()
    try preDoc.select("svg").remove()
    try preDoc.select("nav").remove()
    try preDoc.select("[role=navigation]").remove()
    try preDoc.select("header[id*=navigation], header[class*=navigation]").remove()
    try preDoc.select("aside").remove()
    try preDoc.select("form").remove()
    try preDoc.select("input").remove()
    try preDoc.select("select").remove()
    try preDoc.select("textarea").remove()
    try preDoc.select("iframe").remove()
    try preDoc.select("video").remove()
    try preDoc.select("audio").remove()

    stripLinkedThumbnailCards(in: preDoc, pageURL: pageURL)

    let cleanedHTML = try preDoc.html()
    saveStep("2_cleaned.html", html: cleanedHTML)

    // Step 3: Flatten
    try unwrapCustomElements(in: preDoc)
    try preDoc.select("figure").unwrap()
    try flattenImageOnlyDivs(in: preDoc)
    flattenSingleChildDivs(in: preDoc)

    let flattenedHTML = try preDoc.html()
    saveStep("3_flattened.html", html: flattenedHTML)

    // Step 4: Readability
    let readability = Readability(html: flattenedHTML, url: pageURL)
    let extracted = try readability.parse()

    if let extracted = extracted {
        let title = extracted.title ?? "(no title)"
        var contentHTML = extracted.contentHTML

        // If Readability dropped the hero image, re-inject it.
        // First look inside content landmarks (article, main) to avoid
        // sidebar images, then fall back to the whole page.
        let isHeroCandidate: (Element) -> Bool = { img in
            guard let src = try? img.attr("src"), !src.isEmpty,
                  !src.hasPrefix("data:") else { return false }
            let srcLower = src.lowercased()
            let imgId = (try? img.attr("id"))?.lowercased() ?? ""
            let alt = (try? img.attr("alt"))?.lowercased() ?? ""
            if srcLower.contains(".svg") { return false }
            // WordPress theme assets are always site-wide decoration, never article content
            if srcLower.contains("/wp-content/themes/") { return false }
            let chromeWords = [
                "logo", "flag", "icon", "badge", "spinner",
                "facebook", "twitter", "instagram", "pinterest", "tiktok",
                "furniture", "share", "follow"
            ]
            for word in chromeWords {
                if imgId.contains(word) || alt.contains(word) || srcLower.contains(word) { return false }
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
            // "avatar" in URLs usually means a user profile image (/avatar/, /avatars/,
            // avatar.jpg, avatar_name.webp) but not when it's part of article content
            // (e.g. Avatar: The Last Airbender)
            if srcLower.contains("/avatar/") || srcLower.contains("/avatars/")
                || srcLower.contains("/avatar.") || srcLower.contains("/avatar_")
                || imgId.contains("avatar") { return false }
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

        // Step 2: Determine the hero image
        if let scoped = scopedImg {
            let src = (try? scoped.attr("src")) ?? ""
            if !contentHTML.contains(src) {
                let heroTag = (try? scoped.outerHtml()) ?? ""
                if !heroTag.isEmpty {
                    print("  -> Hero image re-injected (first image, dropped by Readability)")
                    contentHTML = heroTag + contentHTML
                }
            } else {
                print("  -> Hero image already in extracted content — no injection needed")
            }
        } else {
            // No scoped image found — fall back to page-level search
            if let pageFirst = try? preDoc.select("img[src]").first(where: isHeroCandidate) {
                let src = (try? pageFirst.attr("src")) ?? ""
                if !contentHTML.contains(src) {
                    let heroTag = (try? pageFirst.outerHtml()) ?? ""
                    if !heroTag.isEmpty {
                        print("  -> Hero image re-injected (page-level fallback)")
                        contentHTML = heroTag + contentHTML
                    }
                } else {
                    print("  -> Hero image already in extracted content")
                }
            }
        }

        print("  -> Readability title: \(title)")

        // Post-processing
        let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)

        // Deduplicate images — exact src match, then base-URL match
        // (strips query params so crop/size variants of the same image
        // are recognised as duplicates, e.g. The Verge product cards).
        var seenSrcs = Set<String>()
        var seenBasePaths = Set<String>()
        for img in try contentDoc.select("img[src]") {
            let src = try img.attr("src")
            guard !src.isEmpty, !src.hasPrefix("data:") else { continue }
            if !seenSrcs.insert(src).inserted {
                try img.remove()
                continue
            }
            // Also dedup by base path (scheme + host + path, ignoring query/fragment)
            if let url = URL(string: src),
               let scheme = url.scheme, let host = url.host {
                let basePath = "\(scheme)://\(host)\(url.path)"
                if !seenBasePaths.insert(basePath).inserted {
                    try img.remove()
                }
            }
        }

        // Deduplicate sibling images with same base URL but different dimension suffixes
        try deduplicateSiblingImages(in: contentDoc)

        // Strip empty elements left behind by our cleaning passes
        try stripEmptyElements(in: contentDoc)
        contentHTML = (try? contentDoc.body()?.html()) ?? contentHTML

        // Count images in extracted content
        if let images = try? contentDoc.select("img") {
            print("  -> Images in extracted content: \(images.size())")
        }

        saveStep("4_readability.html", html: contentHTML)
    } else {
        print("  !! Readability returned nil — extraction failed")
        saveStep("4_readability_FAILED.html", html: "<!-- Readability returned nil for this URL -->")
    }
}

print("")
print("Output saved to: \(outputDir.path)")
