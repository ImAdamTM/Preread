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
        try img.removeAttr("loading")
        try img.removeAttr("data-nimg")
        try img.removeAttr("data-chromatic")
    }
}

// MARK: - Helper: recover placeholder images from parent anchors

/// Promotes image URLs from `<noscript>` fallbacks onto their JS-dependent
/// sibling `<img>` tags. Many sites use a pattern where `<noscript>` holds
/// an `<img>` with a real `src`, while a sibling `<img>` outside has no `src`
/// and relies on JavaScript to populate it.
func promoteNoscriptImages(in doc: Document) throws {
    for noscript in try doc.select("noscript").array() {
        let noscriptHTML = try noscript.html()
        guard noscriptHTML.contains("<img") else { continue }

        let fragment = try SwiftSoup.parseBodyFragment(noscriptHTML)
        guard let noscriptImg = try fragment.select("img[src]").first() else { continue }
        let realSrc = try noscriptImg.attr("src")
        guard !realSrc.isEmpty, !realSrc.hasPrefix("data:") else { continue }

        guard let sibling = try noscript.nextElementSibling(),
              sibling.tagName() == "img" else { continue }
        let sibSrc = try sibling.attr("src")
        guard sibSrc.isEmpty || sibSrc.hasPrefix("data:") else { continue }

        try sibling.attr("src", realSrc)
    }
}

/// Recovers real image URLs for `<img>` tags that use placeholder `src` values
/// (e.g. a 1x1 transparent GIF data URI) when the parent `<a>` tag links to
/// an actual image file.
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

// MARK: - Helper: unwrap <picture> elements

/// Unwraps `<picture>` elements to just their `<img>` child, removing
/// `<source>` elements. If a `<picture>` has no `<img>` child, the first
/// `<source srcset>` URL is promoted to a new `<img>`.
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
            // <img> exists but may lack src (lazy-loaded sites like ESPN)
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

// MARK: - Helper: strip caption toggle text

/// Strips orphaned caption toggle UI text (e.g. "hide caption", "toggle caption")
/// left behind after button/JS stripping.
func stripCaptionToggles(in doc: Document) throws {
    let captionToggles: Set<String> = ["hide caption", "toggle caption", "show caption"]
    for bold in try doc.select("b").array() {
        let text = try bold.text().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if captionToggles.contains(text) {
            try bold.remove()
        }
    }
}

// MARK: - Helper: extract OpenGraph image

/// Extracts the OpenGraph image URL (`og:image`) from the document's
/// `<meta>` tags. Falls back to `twitter:image` if og:image is absent.
func extractOpenGraphImage(from doc: Document, baseURL: URL) throws -> String? {
    if let ogMeta = try doc.select("meta[property=og:image]").first() {
        let content = try ogMeta.attr("content")
        if !content.isEmpty, let url = URL(string: content, relativeTo: baseURL) {
            // Upgrade http to https so ATS doesn't block the download
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            if components?.scheme == "http" { components?.scheme = "https" }
            return components?.url?.absoluteString ?? url.absoluteString
        }
    }
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

// MARK: - Helper: escape HTML

func escapeHTML(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
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
            let unwrapChildTags: Set<String> = [
                "div", "img", "picture", "figure"
            ]
            guard unwrapChildTags.contains(childTag) else { continue }
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

// MARK: - Helper: merge standalone images into paragraphs

/// Wraps standalone <img> elements (direct children of block containers) in
/// their own <p> tags so they're valid block-level content for Readability.
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

// MARK: - Post-Readability image recovery

/// Recovers article images that Readability dropped during extraction.
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
        guard !existingSrcs.contains(src) else { continue }
        if let hero = heroImageURL, src == hero { continue }

        let anchor = img.parent()?.tagName() == "p" ? img.parent()! : img
        guard let container = anchor.parent() else { continue }
        let siblings = container.children().array()
        guard let anchorIndex = siblings.firstIndex(where: { $0 === anchor }) else { continue }

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

// MARK: - Helper: strip byline images

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

/// Regex matching dimension suffixes like -640x426, -1024x648,
/// plus an optional trailing CDN hash like -1774644559
let dimensionSuffixPattern = try! NSRegularExpression(pattern: #"-\d+x\d+(-\d+)?"#)

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

// MARK: - Helper: strip interstitials

func stripAriaHiddenFromContent(in doc: Document) throws {
    let contentSelector = "p[aria-hidden], h1[aria-hidden], h2[aria-hidden], h3[aria-hidden], h4[aria-hidden], h5[aria-hidden], h6[aria-hidden], blockquote[aria-hidden], li[aria-hidden], td[aria-hidden], th[aria-hidden]"
    for el in try doc.select(contentSelector) {
        try el.removeAttr("aria-hidden")
    }
}

func stripInterstitials(in doc: Document) throws {
    let interstitialPhrases: Set<String> = [
        "article continues below",
        "continue reading below",
        "story continues below",
        "loading...",
        "loading\u{2026}",
    ]

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

// MARK: - Helper: extract __NEXT_DATA__ article content

/// Extracts article HTML from a Next.js `__NEXT_DATA__` script element,
/// but only if the body doesn't already contain the article text (i.e.
/// the site relies on client-side rendering rather than SSR).
func extractNextDataContent(from doc: Document) -> String? {
    guard let scriptEl = try? doc.select("script#__NEXT_DATA__").first(),
          let jsonText = try? scriptEl.data(),
          let jsonData = jsonText.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) else {
        return nil
    }

    var bestHTML: String?
    var bestLength = 200

    func walk(_ value: Any) {
        switch value {
        case let str as String:
            if str.count > bestLength && str.contains("<p>") {
                bestHTML = str
                bestLength = str.count
            }
        case let dict as [String: Any]:
            for v in dict.values { walk(v) }
        case let arr as [Any]:
            for v in arr { walk(v) }
        default:
            break
        }
    }

    walk(json)

    // Only inject if the body doesn't already contain the article text.
    guard let articleHTML = bestHTML else { return nil }

    if let articleDoc = try? SwiftSoup.parseBodyFragment(articleHTML),
       let articleText = try? articleDoc.body()?.text(),
       articleText.count > 200 {
        let midStart = articleText.index(articleText.startIndex, offsetBy: 100)
        let midEnd = articleText.index(midStart, offsetBy: min(60, articleText.distance(from: midStart, to: articleText.endIndex)))
        let snippet = String(articleText[midStart..<midEnd])

        if let bodyText = try? doc.body()?.text(), bodyText.contains(snippet) {
            return nil // Content already server-rendered
        }
    }

    return bestHTML
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

    // Extract __NEXT_DATA__ article HTML before stripping scripts
    let nextDataContent = extractNextDataContent(from: doc)

    // Strip CSP
    let cspMetas = try doc.select("meta[http-equiv=Content-Security-Policy]")
    try cspMetas.remove()

    // Ensure a white background fallback. Many sites rely on browser
    // defaults or don't set an explicit background-color, which makes
    // text illegible when the WebView has a transparent/dark background.
    if let head = doc.head() {
        try head.append("<style>html, body { background-color: #fff !important; }</style>")
    }

    // If __NEXT_DATA__ had article HTML, inject it into the body
    if let nextContent = nextDataContent, let body = doc.body() {
        try body.append("<article id=\"next-data-article\">\(nextContent)</article>")
        print("  -> Injected __NEXT_DATA__ article content into DOM")
    }

    // Strip scripts and noscript fallbacks
    let scripts = try doc.select("script")
    try scripts.remove()
    try promoteNoscriptImages(in: doc)
    try doc.select("noscript").remove()

    // Strip navigation
    try doc.select("nav").remove()
    try doc.select("[role=navigation]").remove()
    try doc.select("header[id*=navigation], header[class*=navigation]").remove()

    // Strip comment sections
    try doc.select("#comments, .comments, #disqus_thread").remove()

    // Strip tooltip elements, non-content markers, newsletter containers, interstitials
    try doc.select("[role=tooltip]").remove()
    try doc.select("[data-nosnippet]").remove()
    try doc.select("[class*=newsletter], [id*=newsletter]").remove()
    try stripInterstitials(in: doc)

    // Strip interactive elements that rely on JS
    try doc.select("button").remove()
    try doc.select("dialog").remove()
    try doc.select("svg").remove()
    try doc.select("form").remove()
    try doc.select("input").remove()
    try doc.select("select").remove()
    try doc.select("textarea").remove()

    // Strip aria-hidden from content elements so JS-toggled text remains visible
    try stripAriaHiddenFromContent(in: doc)
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

    // Extract __NEXT_DATA__ article HTML before stripping scripts
    let nextDataContent = extractNextDataContent(from: preDoc)

    try preDoc.select("script").remove()
    try promoteNoscriptImages(in: preDoc)
    try preDoc.select("noscript").remove()

    // If __NEXT_DATA__ had article HTML, inject it into the body.
    // The <article> tag gives Readability a strong content signal.
    if let nextContent = nextDataContent, let body = preDoc.body() {
        try body.append("<article id=\"next-data-article\">\(nextContent)</article>")
        print("  -> Injected __NEXT_DATA__ article content into DOM")
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

    // Strip aria-hidden from content elements so JS-toggled text is visible
    try stripAriaHiddenFromContent(in: preDoc)

    // Strip tiny images (badges, tracking pixels, decorative icons)
    stripTinyImages(in: preDoc, maxDimension: 30)

    // Strip badge clusters (rows of linked images with no text)
    try stripBadgeClusters(in: preDoc)

    try stripImageLayoutStyles(in: preDoc)
    try constrainAvatarImages(in: preDoc)

    // Strip comment sections — user-generated comments can outweigh article
    // text and confuse Readability's scoring.
    try preDoc.select("#comments, .comments, #disqus_thread").remove()

    // Strip tooltip elements, non-content markers, newsletter containers, interstitials
    try preDoc.select("[role=tooltip]").remove()
    try preDoc.select("[data-nosnippet]").remove()
    try preDoc.select("[class*=newsletter], [id*=newsletter]").remove()
    try stripInterstitials(in: preDoc)

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
    try stripEmptyElements(in: preDoc)
    try wrapStandaloneImages(in: preDoc)

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
            // Skip images too small to be a meaningful hero (avatars, icons)
            let w = Int((try? img.attr("width")) ?? "") ?? Int.max
            let h = Int((try? img.attr("height")) ?? "") ?? Int.max
            if w < 120 || h < 120 { return false }
            // Small images (both dims ≤ 250) are avatars, sidebar thumbs, etc.
            if w != Int.max, h != Int.max, w <= 250, h <= 250 { return false }
            // Narrow portrait images (w ≤ 200, taller than wide) are author photos
            if w != Int.max, h != Int.max, w < h, w <= 200 { return false }
            // Also check URL resize parameters (e.g. ?w=150)
            if let urlComps = URLComponents(string: src),
               let wParam = urlComps.queryItems?.first(where: { $0.name == "w" })?.value,
               let urlWidth = Int(wParam), urlWidth <= 150 {
                return false
            }
            let srcLower = src.lowercased()
            let imgId = (try? img.attr("id"))?.lowercased() ?? ""
            let alt = (try? img.attr("alt"))?.lowercased() ?? ""
            if srcLower.contains(".svg") { return false }
            // Schema.org site logos are never article content
            if (try? img.attr("itemprop")) == "logo" { return false }
            // WordPress theme assets are always site-wide decoration, never article content
            if srcLower.contains("/wp-content/themes/") { return false }
            let chromeWords = [
                "logo", "flag", "icon", "badge", "spinner",
                "facebook", "twitter", "instagram", "pinterest", "tiktok",
                "furniture", "share", "follow", "comment", "thumbnail",
                "banner", "bkgd", "reactions", "headshot"
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

        var heroImageURL: String?

        if let scoped = scopedImg {
            let src = (try? scoped.attr("src")) ?? ""
            if !heroAlreadyPresent(src) {
                heroImageURL = src
                let heroTag = (try? scoped.outerHtml()) ?? ""
                if !heroTag.isEmpty {
                    print("  -> Hero image re-injected (first image, dropped by Readability)")
                    contentHTML = heroTag + contentHTML
                }
            } else {
                heroImageURL = src
                print("  -> Hero image already in extracted content — no injection needed")
            }
        } else {
            // No scoped image found — fall back to page-level search
            if let pageFirst = try? preDoc.select("img[src]").first(where: isHeroCandidate) {
                let src = (try? pageFirst.attr("src")) ?? ""
                heroImageURL = src
                if !heroAlreadyPresent(src) {
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

        // If no hero image was found from <img> elements, fall back to
        // the OpenGraph image (og:image meta tag).
        if heroImageURL == nil {
            if let ogImage = try extractOpenGraphImage(from: preDoc, baseURL: pageURL) {
                heroImageURL = ogImage
                print("  -> Hero image from og:image meta tag: \(ogImage)")
                contentHTML = "<img src=\"\(escapeHTML(ogImage))\" />" + contentHTML
            }
        }

        print("  -> Readability title: \(title)")

        // Recover article images dropped by Readability
        contentHTML = try recoverDroppedImages(
            contentHTML: contentHTML,
            preDoc: preDoc,
            heroImageURL: heroImageURL,
            pageURL: pageURL
        )

        // Post-processing
        let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)

        // Deduplicate images — exact src match, then base-URL match
        // (strips query params so crop/size variants of the same image
        // are recognised as duplicates, e.g. The Verge product cards),
        // then host+filename match (catches CDN resize variants with
        // different path hashes, e.g. CNET /a/img/resize/{hash}/.../file.jpg).
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
                // CDN proxy URLs aren't falsely deduped.
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
                ]
                if !filename.isEmpty, filename != "/", !genericFilenames.contains(filename.lowercased()) {
                    let hostFilename = "\(host)/\(filename)"
                    if !seenHostFilenames.insert(hostFilename).inserted {
                        try img.remove()
                    }
                }
            }
        }

        // Deduplicate sibling images with same base URL but different dimension suffixes
        try deduplicateSiblingImages(in: contentDoc)

        try stripBylineImages(in: contentDoc)
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
