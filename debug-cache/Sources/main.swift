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

// MARK: - Helper: strip empty elements

func stripEmptyElements(in doc: Document) throws {
    let preservedTags: Set<String> = [
        "img", "br", "hr", "input", "source", "meta", "link",
        "video", "audio", "canvas", "iframe", "embed", "object",
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

    // Strip scripts and noscript fallbacks
    let scripts = try doc.select("script")
    try scripts.remove()
    try doc.select("noscript").remove()

    // Strip navigation
    try doc.select("nav").remove()

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

    // Strip tiny images (badges, tracking pixels, decorative icons)
    stripTinyImages(in: preDoc, maxDimension: 30)

    // Strip badge clusters (rows of linked images with no text)
    try stripBadgeClusters(in: preDoc)

    try stripImageLayoutStyles(in: preDoc)

    // Strip interactive/UI elements that serve no purpose in reader mode
    // and prevent image wrapper divs from being flattened.
    try preDoc.select("button").remove()
    try preDoc.select("dialog").remove()
    try preDoc.select("svg").remove()
    try preDoc.select("nav").remove()
    try preDoc.select("aside").remove()
    try preDoc.select("form").remove()
    try preDoc.select("input").remove()
    try preDoc.select("select").remove()
    try preDoc.select("textarea").remove()
    try preDoc.select("iframe").remove()

    let cleanedHTML = try preDoc.html()
    saveStep("2_cleaned.html", html: cleanedHTML)

    // Step 3: Flatten
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
        // Find the first <img> with a real src (not a data URI). If that
        // first image is an SVG or a site logo, stop — the real hero is
        // behind JS-rendered content we can't reach.
        if let firstImg = try? preDoc.select("img[src]").first(where: { img in
            guard let src = try? img.attr("src"), !src.isEmpty,
                  !src.hasPrefix("data:") else { return false }
            return true
        }) {
            let src = (try? firstImg.attr("src")) ?? ""
            let imgId = (try? firstImg.attr("id"))?.lowercased() ?? ""
            let alt = (try? firstImg.attr("alt"))?.lowercased() ?? ""
            let isSiteChrome = src.lowercased().contains(".svg")
                || imgId.contains("logo")
                || alt.contains("logo")

            if isSiteChrome {
                print("  -> First image is site chrome (SVG/logo), skipping hero injection")
            } else if !contentHTML.contains(src) {
                let heroTag = (try? firstImg.outerHtml()) ?? ""
                if !heroTag.isEmpty {
                    print("  -> Hero image re-injected (first image, dropped by Readability)")
                    contentHTML = heroTag + contentHTML
                }
            } else {
                print("  -> Hero image already in extracted content")
            }
        }

        print("  -> Readability title: \(title)")

        // Strip empty elements left behind by our cleaning passes
        let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
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
