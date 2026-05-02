import Foundation
import UIKit
import SwiftSoup
import CryptoKit

// MARK: - Asset extraction, downloading, and URL rewriting

extension PageCacheService {

    // MARK: - Asset mapping type

    struct AssetMapping {
        let originalURL: String
        let filename: String
        let size: Int
        let wasTruncated: Bool
    }

    // MARK: - Asset extraction

    func extractAssetURLs(from doc: Document, baseURL: URL, cacheLevel: CacheLevel) throws -> [URL] {
        var urls: [URL] = []

        switch cacheLevel {
        case .standard:
            // Images from <img> tags
            let images = try doc.select("img")
            for img in images {
                if let url = try resolveImageURL(img, baseURL: baseURL) {
                    urls.append(url)
                }
            }
            // Images from <picture><source srcset="..."> tags
            let pictureSources = try doc.select("picture > source[srcset]")
            for source in pictureSources {
                if let url = try resolveSourceSrcsetURL(source, baseURL: baseURL) {
                    urls.append(url)
                }
            }

        case .full:
            // Images from <img> tags — this covers both standalone <img> and
            // <picture><img> fallbacks. We skip <source srcset> variants to avoid
            // downloading multiple sizes of the same image.
            let images = try doc.select("img")
            for img in images {
                if let url = try resolveImageURL(img, baseURL: baseURL) {
                    urls.append(url)
                }
            }
            // Stylesheets
            let stylesheets = try doc.select("link[href][rel=stylesheet]")
            for link in stylesheets {
                let href = try link.attr("abs:href")
                if let url = URL(string: href) { urls.append(url) }
            }
            // Note: video/audio elements are stripped during cleaning,
            // so we don't collect their source URLs.
        }

        // Deduplicate while preserving order
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Target width in CSS pixels for srcset selection.
    /// 2x retina on a ~390pt-wide iPhone ≈ 780px, but article content areas are
    /// typically narrower than full screen. ~1000px gives sharp images on any
    /// current device without downloading unnecessarily large variants.
    private var srcsetTargetWidth: Int { 1000 }

    /// Maximum width to select from srcset. Images above this are likely to
    /// exceed the 2 MB per-asset download limit and produce dead image boxes.
    private var srcsetMaxWidth: Int { 1500 }

    /// Splits a srcset attribute value into individual entries, handling commas
    /// that appear inside URL paths or query parameters.
    ///
    /// Srcset entries are separated by commas, but commas also appear inside URLs:
    /// - Query parameters: `?resize=1200,800`
    /// - Cloudinary-style path transforms: `/w_640,c_limit/image.jpg`
    ///
    /// Two signals indicate a new entry after a comma:
    /// 1. The current accumulated text already ends with a width/density
    ///    descriptor (`300w`, `2x`), meaning the entry is complete.
    /// 2. The next fragment starts with a URL-like prefix (`http(s)://`, `//`,
    ///    `/`, `data:`).
    ///
    /// If neither condition holds, the comma is part of the URL itself.
    func parseSrcsetEntries(_ srcset: String) -> [String] {
        let rawParts = srcset.components(separatedBy: ",")
        var entries: [String] = []
        var current = ""

        for part in rawParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if current.isEmpty {
                current = trimmed
            } else {
                // Check if the accumulated text already forms a complete entry
                // (ends with a descriptor like "300w" or "2x").
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                let lastToken = currentTrimmed.components(separatedBy: .whitespaces).last ?? ""
                let hasDescriptor = lastToken.hasSuffix("w") || lastToken.hasSuffix("x")

                // Check if this fragment starts a new URL.
                let lc = trimmed.lowercased()
                let isNewURL = lc.hasPrefix("http://") || lc.hasPrefix("https://")
                    || lc.hasPrefix("//") || lc.hasPrefix("data:")
                    || lc.hasPrefix("/")

                if hasDescriptor || isNewURL {
                    // New srcset entry
                    entries.append(current)
                    current = trimmed
                } else {
                    // Continuation of previous URL (comma was inside the URL)
                    current += "," + trimmed
                }
            }
        }
        if !current.isEmpty {
            entries.append(current)
        }
        return entries
    }

    /// Parses a srcset attribute value and returns the best URL for our target width.
    /// Handles width descriptors (e.g. "img-300.jpg 300w, img-600.jpg 600w") and
    /// pixel-density descriptors (e.g. "img.jpg 1x, img@2x.jpg 2x").
    /// Falls back to the first entry when no descriptors are present.
    private func bestURLFromSrcset(_ srcset: String, baseURL: URL) -> URL? {
        let entries = parseSrcsetEntries(srcset)
        var candidates: [(url: String, width: Int)] = []

        for entry in entries {
            let parts = entry.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard let urlPart = parts.first, !urlPart.isEmpty, !urlPart.hasPrefix("data:") else { continue }

            if parts.count >= 2 {
                let descriptor = parts.last!.lowercased()
                if descriptor.hasSuffix("w"), let w = Int(descriptor.dropLast()) {
                    candidates.append((urlPart, w))
                } else if descriptor.hasSuffix("x"), let x = Double(descriptor.dropLast()) {
                    // Treat pixel-density as a rough width estimate
                    candidates.append((urlPart, Int(x * 600)))
                } else {
                    // Unknown descriptor — treat as no-descriptor
                    candidates.append((urlPart, 0))
                }
            } else {
                candidates.append((urlPart, 0))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // If we have width descriptors, pick the best fit within size limits.
        // Prefer the smallest variant >= target that's also <= max (avoids
        // downloading multi-MB originals that exceed the per-asset limit).
        let withWidths = candidates.filter { $0.width > 0 }
        let chosen: String
        if !withWidths.isEmpty {
            let inRange = withWidths.filter { $0.width >= srcsetTargetWidth && $0.width <= srcsetMaxWidth }
                .sorted { $0.width < $1.width }
            if let best = inRange.first {
                chosen = best.url
            } else {
                // Nothing in the ideal range — pick the largest that's <= max
                let underMax = withWidths.filter { $0.width <= srcsetMaxWidth }
                    .sorted { $0.width > $1.width }
                if let best = underMax.first {
                    chosen = best.url
                } else {
                    // All variants exceed max — pick the smallest available
                    chosen = withWidths.sorted { $0.width < $1.width }.first!.url
                }
            }
        } else {
            // No width descriptors — pick the first entry
            chosen = candidates.first!.url
        }

        return URL(string: chosen, relativeTo: baseURL)?.absoluteURL
    }

    /// Resolves an image URL from src, data-src, or srcset attributes.
    /// When srcset contains width descriptors, picks the best size for the device.
    private func resolveImageURL(_ img: Element, baseURL: URL) throws -> URL? {
        // Check srcset first — if it has width descriptors we can pick the right size
        let srcset = try img.attr("srcset")
        if !srcset.isEmpty {
            if let url = bestURLFromSrcset(srcset, baseURL: baseURL), !isPlaceholderImage(url) {
                return url
            }
        }
        // Prefer src
        let src = try img.attr("src")
        if !src.isEmpty, !src.hasPrefix("data:") {
            let absSrc = try img.attr("abs:src")
            if let url = URL(string: absSrc), !isPlaceholderImage(url) { return url }
        }
        // Fall back to data-src / data-lazy-src
        for attr in ["data-src", "data-lazy-src", "data-original"] {
            let value = try img.attr(attr)
            if !value.isEmpty, !value.hasPrefix("data:") {
                if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL, !isPlaceholderImage(url) { return url }
            }
        }
        return nil
    }

    /// Returns true for URLs that are known placeholder/tracking pixel images not worth downloading.
    private func isPlaceholderImage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        // Grey placeholder images
        if path.contains("grey-placeholder") || path.contains("placeholder") {
            return true
        }
        // Lazy-load fallback images
        if path.contains("lazyload-fallback") || path.contains("spacer") {
            return true
        }
        // Common tracking pixels (1x1 images)
        if path.hasSuffix("/pixel.gif") || path.hasSuffix("/pixel.png") || path.hasSuffix("/blank.gif") {
            return true
        }
        // Known tracking/analytics domains
        let trackingHosts = ["sb.scorecardresearch.com", "pixel.quantserve.com", "b.scorecardresearch.com"]
        if trackingHosts.contains(host) {
            return true
        }
        return false
    }

    /// Resolves a URL from a <picture><source srcset="..."> element.
    /// Picks the best size for the device using width descriptors when available.
    private func resolveSourceSrcsetURL(_ source: Element, baseURL: URL) throws -> URL? {
        let srcset = try source.attr("srcset")
        guard !srcset.isEmpty else { return nil }
        return bestURLFromSrcset(srcset, baseURL: baseURL)
    }

    // MARK: - Asset downloading

    func downloadAssets(urls: [URL], to assetsDir: URL, baseURL: URL, heroImageURL: String? = nil) async -> [Result<AssetMapping, Error>] {
        guard !urls.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, Result<AssetMapping, Error>).self) { group in
            var results = [Result<AssetMapping, Error>?](repeating: nil, count: urls.count)
            var cumulativeSize = 0
            var sizeLimitReached = false

            for (index, url) in urls.enumerated() {
                group.addTask { [self] in
                    do {
                        let isHero = heroImageURL != nil && url.absoluteString == heroImageURL
                        let mapping = try await self.downloadAsset(url: url, to: assetsDir, maxBytes: isHero ? self.maxHeroAssetBytes : nil)
                        return (index, .success(mapping))
                    } catch {
                        return (index, .failure(error))
                    }
                }

                // Throttle: wait if we've launched maxConcurrentDownloads
                if (index + 1) % maxConcurrentDownloads == 0 {
                    for await (idx, result) in group.prefix(maxConcurrentDownloads) {
                        if case .success(let mapping) = result {
                            cumulativeSize += mapping.size
                            if cumulativeSize >= maxTotalAssetBytes {
                                sizeLimitReached = true
                            }
                        }
                        results[idx] = result
                    }
                    if sizeLimitReached { break }
                }
            }

            // Collect remaining results
            for await (idx, result) in group {
                if case .success(let mapping) = result {
                    cumulativeSize += mapping.size
                    if cumulativeSize >= maxTotalAssetBytes {
                        let truncated = AssetMapping(
                            originalURL: mapping.originalURL,
                            filename: mapping.filename,
                            size: mapping.size,
                            wasTruncated: true
                        )
                        results[idx] = .success(truncated)
                        continue
                    }
                }
                results[idx] = result
            }

            return results.compactMap { $0 }
        }
    }

    func downloadAsset(url: URL, to assetsDir: URL, maxBytes: Int? = nil) async throws -> AssetMapping {
        let fm = FileManager.default
        let sharedDir = sharedAssetsURL
        try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        // Check shared pool first — if we already downloaded this asset for another article,
        // hardlink it instead of re-downloading.
        let preliminaryFilename = hashedFilename(for: url)
        let sharedPath = sharedDir.appendingPathComponent(preliminaryFilename)

        if fm.fileExists(atPath: sharedPath.path) {
            let attrs = try fm.attributesOfItem(atPath: sharedPath.path)
            let size = (attrs[.size] as? Int) ?? 0
            let filePath = assetsDir.appendingPathComponent(preliminaryFilename)
            try? fm.removeItem(at: filePath)
            try fm.linkItem(at: sharedPath, to: filePath)
            return AssetMapping(
                originalURL: url.absoluteString,
                filename: preliminaryFilename,
                size: size,
                wasTruncated: false
            )
        }

        var request = URLRequest(url: url)
        request.assumesHTTP3Capable = false

        let (data, response) = try await resilientData(for: request)

        // Validate HTTP status — reject 4xx/5xx so we don't save error pages as assets
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        // Reject responses that are too large
        if data.count > (maxBytes ?? maxSingleAssetBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        // Validate content type — reject HTML error pages saved as images
        let responseContentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased()
        if let contentType = responseContentType {
            let validPrefixes = ["image/", "text/css", "font/", "application/font", "application/x-font",
                                 "image/svg+xml", "application/octet-stream"]
            let isValid = validPrefixes.contains { contentType.hasPrefix($0) }
            if !isValid {
                throw URLError(.cannotDecodeContentData)
            }
        }

        // Compute final filename — use Content-Type to derive extension for extensionless URLs
        let filename = hashedFilename(for: url, contentType: responseContentType)
        let finalSharedPath = sharedDir.appendingPathComponent(filename)
        let filePath = assetsDir.appendingPathComponent(filename)

        // Write to shared pool, then hardlink into article dir
        try data.write(to: finalSharedPath)
        try? fm.removeItem(at: filePath)
        try fm.linkItem(at: finalSharedPath, to: filePath)

        return AssetMapping(
            originalURL: url.absoluteString,
            filename: filename,
            size: data.count,
            wasTruncated: false
        )
    }

    // MARK: - Thumbnails

    /// Downloads the article thumbnail and saves two downsampled versions:
    /// - `thumbnail.jpg` — 600px, for hero backdrops, cards, and larger displays
    /// - `thumb.jpg` — 240px, for 80pt list row thumbnails
    /// The original full-size image is not kept on disk.
    func cacheThumbnail(url: URL, to articleDir: URL) async {
        do {
            // Upgrade http to https so ATS doesn't block the download
            var downloadURL = url
            if downloadURL.scheme == "http",
               var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: true) {
                components.scheme = "https"
                if let upgraded = components.url { downloadURL = upgraded }
            }
            var request = URLRequest(url: downloadURL)
            request.assumesHTTP3Capable = false
            let (data, response) = try await resilientData(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) { return }
            guard data.count > 100 else { return } // skip tiny/broken images

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }

            // Regular size (600px) for hero backdrops, cards, etc.
            if let regular = downsampleCGImage(source: source, maxPixels: 600),
               let jpegData = UIImage(cgImage: regular).jpegData(compressionQuality: 0.8) {
                try jpegData.write(to: articleDir.appendingPathComponent("thumbnail.jpg"))
            }

            // Small size (240px = 80pt × 3x) for list row thumbnails
            if let small = downsampleCGImage(source: source, maxPixels: 240),
               let jpegData = UIImage(cgImage: small).jpegData(compressionQuality: 0.7) {
                try jpegData.write(to: articleDir.appendingPathComponent("thumb.jpg"))
            }
        } catch {
            // Thumbnail caching is best-effort; don't fail the article cache
        }
    }

    /// Checks if a cached thumbnail is below a pixel-width threshold
    /// without fully decoding the image, using ImageIO properties.
    func isThumbnailLowRes(at url: URL, threshold: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int else {
            return true // No thumbnail or unreadable — treat as low-res
        }
        return width < threshold
    }

    /// Downsamples using ImageIO without decoding the full bitmap into memory.
    private func downsampleCGImage(source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// For full cache level: after downloading a CSS file, parse it for @font-face URLs.
    func extractFontURLs(from cssData: Data, baseURL: URL) -> [URL] {
        guard let css = String(data: cssData, encoding: .utf8) else { return [] }
        var urls: [URL] = []

        // Simple regex to find url() references in @font-face blocks
        let pattern = #"@font-face\s*\{[^}]*url\(\s*['"]?([^'"\)]+)['"]?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(css.startIndex..., in: css)
        let matches = regex.matches(in: css, range: range)
        for match in matches {
            if let urlRange = Range(match.range(at: 1), in: css) {
                let urlString = String(css[urlRange])
                if let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    // MARK: - HTML rewriting

    func rewriteURL(in doc: Document, original: String, replacement: String) throws {
        let originalURL = URL(string: original)

        // Rewrite img src, data-src, and srcset
        let images = try doc.select("img")
        for img in images {
            // Check src
            let src = try img.attr("abs:src")
            if src == original {
                try img.attr("src", replacement)
                // Remove srcset/sizes so the browser uses our local src
                // Remove both cases: React SSR emits camelCase "srcSet" which
                // SwiftSoup treats as a separate attribute from lowercase "srcset"
                try img.removeAttr("srcset")
                try img.removeAttr("srcSet")
                try img.removeAttr("sizes")
                try img.removeAttr("loading")
                try img.removeAttr("decoding")
                continue
            }
            // Check data-src (resolve relative to page base, not to original)
            let dataSrc = try img.attr("data-src")
            if !dataSrc.isEmpty, !dataSrc.hasPrefix("data:") {
                let resolvedDataSrc = URL(string: dataSrc)?.absoluteString ?? dataSrc
                if dataSrc == original || resolvedDataSrc == original {
                    try img.attr("src", replacement)
                    try img.removeAttr("data-src")
                    try img.removeAttr("srcset")
                    try img.removeAttr("srcSet")
                    try img.removeAttr("sizes")
                    try img.removeAttr("loading")
                    try img.removeAttr("decoding")
                    continue
                }
            }
            // Check srcset on img
            if try rewriteSrcsetIfMatching(element: img, original: original, originalURL: originalURL, replacement: replacement) {
                try img.removeAttr("srcset")
                try img.removeAttr("srcSet")
                try img.removeAttr("sizes")
                try img.removeAttr("loading")
                try img.removeAttr("decoding")
                continue
            }
        }

        // Rewrite <picture><source srcset="..."> — if the inner <img> was already
        // rewritten to a local path, just remove the <source>. Otherwise set src on
        // the inner <img> and remove the <source> so the browser uses the local file.
        let pictureSources = try doc.select("picture > source[srcset]")
        for source in pictureSources {
            if try rewriteSrcsetIfMatching(element: source, original: original, originalURL: originalURL, replacement: replacement) {
                if let picture = source.parent(), picture.tagName() == "picture" {
                    // Rewrite the inner <img> if it hasn't been rewritten already
                    if let innerImg = try picture.select("img").first() {
                        let currentSrc = try innerImg.attr("src")
                        if !currentSrc.hasPrefix("./assets/") && !currentSrc.hasPrefix("assets/") {
                            try innerImg.attr("src", replacement)
                            try innerImg.removeAttr("srcset")
                            try innerImg.removeAttr("srcSet")
                            try innerImg.removeAttr("sizes")
                            try innerImg.removeAttr("loading")
                            try innerImg.removeAttr("decoding")
                        }
                    }
                }
                // Remove the <source> element — the <img> now has the local path
                try source.remove()
            }
        }

        // Rewrite link href (stylesheets)
        let links = try doc.select("link[href]")
        for link in links {
            let href = try link.attr("abs:href")
            if href == original {
                try link.attr("href", replacement)
            }
        }

        // Note: video/audio elements are stripped during cleaning,
        // so we don't rewrite their source URLs.
    }

    /// Checks if any entry in an element's srcset matches the original URL.
    /// If it matches, sets src to the replacement and returns true.
    private func rewriteSrcsetIfMatching(element: Element, original: String, originalURL: URL?, replacement: String) throws -> Bool {
        let srcset = try element.attr("srcset")
        guard !srcset.isEmpty else { return false }

        let entries = parseSrcsetEntries(srcset)
        for entry in entries {
            let urlPart = entry.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            guard !urlPart.isEmpty else { continue }
            // Compare raw string, absolute string, or resolved URL
            if urlPart == original {
                try element.attr("src", replacement)
                return true
            }
            if let resolved = URL(string: urlPart)?.absoluteString, resolved == original {
                try element.attr("src", replacement)
                return true
            }
            // Also compare by path if both are valid URLs (handles scheme/host normalization)
            if let resolvedURL = URL(string: urlPart), let origURL = originalURL,
               resolvedURL.host == origURL.host && resolvedURL.path == origURL.path {
                try element.attr("src", replacement)
                return true
            }
        }
        return false
    }

    // MARK: - Image download fallback

    /// Second-pass fallback for images whose srcset-based download failed.
    /// Some srcset entries with "reasonable" widths (e.g. 1333w) are actually
    /// unoptimized originals that exceed the per-asset size limit.
    /// This method finds images still pointing to remote URLs and tries downloading
    /// their `src` attribute, which is typically a smaller server-resized variant.
    func downloadSrcFallbackImages(in doc: Document, assetsDir: URL, baseURL: URL) async throws -> [Result<AssetMapping, Error>] {
        var fallbackURLs: [URL] = []
        let images = try doc.select("img")
        for img in images {
            let src = try img.attr("src")
            guard !src.isEmpty,
                  !src.hasPrefix("./assets/"),
                  !src.hasPrefix("assets/"),
                  !src.hasPrefix("data:") else { continue }
            let absSrc = try img.attr("abs:src")
            if let url = URL(string: absSrc), !isPlaceholderImage(url) {
                fallbackURLs.append(url)
            }
        }
        // Deduplicate while preserving order
        var seen = Set<URL>()
        fallbackURLs = fallbackURLs.filter { seen.insert($0).inserted }

        guard !fallbackURLs.isEmpty else { return [] }
        return await downloadAssets(urls: fallbackURLs, to: assetsDir, baseURL: baseURL)
    }

    /// Third-pass fallback for images that are still remote after src fallback.
    /// When an `<img>` download fails (e.g. oversized original) but the image
    /// is wrapped in an `<a>` linking to the same image host, tries downloading
    /// the `<a>` href instead — CDN systems often serve a smaller optimized
    /// variant at the link URL.
    func downloadAnchorFallbackImages(in doc: Document, assetsDir: URL, baseURL: URL) async throws -> [Result<AssetMapping, Error>] {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif"]
        var fallbackURLs: [(Element, URL)] = []
        let images = try doc.select("img")
        for img in images {
            let src = try img.attr("src")
            guard !src.isEmpty,
                  !src.hasPrefix("./assets/"),
                  !src.hasPrefix("assets/"),
                  !src.hasPrefix("data:") else { continue }

            // Check if parent <a> links to an image on the same host
            guard let parent = img.parent(),
                  parent.tagName() == "a" else { continue }
            let href = try parent.attr("abs:href")
            guard let hrefURL = URL(string: href),
                  let imgURL = URL(string: try img.attr("abs:src")),
                  hrefURL.host == imgURL.host,
                  hrefURL.absoluteString != imgURL.absoluteString,
                  imageExtensions.contains(hrefURL.pathExtension.lowercased()) else { continue }

            fallbackURLs.append((img, hrefURL))
        }

        guard !fallbackURLs.isEmpty else { return [] }

        let urls = fallbackURLs.map { $0.1 }
        let results = await downloadAssets(urls: urls, to: assetsDir, baseURL: baseURL)

        // Rewrite successful downloads — update both the <img> src and the <a> href
        for (i, result) in results.enumerated() {
            if case .success(let mapping) = result {
                let (img, _) = fallbackURLs[i]
                let localPath = "./assets/\(mapping.filename)"
                try img.attr("src", localPath)
                if let parent = img.parent(), parent.tagName() == "a" {
                    try parent.attr("href", localPath)
                }
            }
        }

        return results
    }

    // MARK: - Remote image cleanup

    /// Strips remaining non-local references after URL rewriting.
    /// Removes `<source>` elements inside `<picture>` that weren't rewritten to local paths,
    /// and removes `<img>` tags with non-local src to prevent dead image boxes.
    func stripRemoteImageReferences(in doc: Document) throws {
        // Remove <source> elements inside <picture> that weren't rewritten to local
        let pictureSources = try doc.select("picture > source[srcset]")
        for source in pictureSources {
            let srcset = try source.attr("srcset")
            if !srcset.hasPrefix("./assets/") && !srcset.hasPrefix("assets/") {
                try source.remove()
            }
        }

        // For <img> tags with local src: strip any remaining remote srcset
        // For <img> tags with non-local src: the download failed — remove src
        // to prevent WKWebView from trying to resolve relative paths on the filesystem
        let images = try doc.select("img[src]")
        for img in images {
            let src = try img.attr("src")
            let isLocal = src.hasPrefix("./assets/") || src.hasPrefix("assets/") || src.hasPrefix("data:")
            if isLocal {
                // Clean up any remaining srcset that points elsewhere
                let srcset = try img.attr("srcset")
                if !srcset.isEmpty && !srcset.hasPrefix("./assets/") {
                    try img.removeAttr("srcset")
                    try img.removeAttr("srcSet")
                    try img.removeAttr("sizes")
                }
            } else {
                // Image download failed — remove element to prevent dead image boxes
                try img.remove()
            }
        }
    }

    // MARK: - Helpers

    /// SHA256 hash of URL string + file extension.
    /// When the URL has no extension, falls back to the MIME content type if provided,
    /// otherwise defaults to "bin".
    func hashedFilename(for url: URL, contentType: String? = nil) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()

        var ext = url.pathExtension
        // Strip query from extension if present
        if !ext.isEmpty {
            ext = ext.components(separatedBy: "?").first ?? ext
        }

        // If URL has no extension, derive one from the Content-Type header
        if ext.isEmpty, let mime = contentType?.lowercased() {
            ext = Self.extensionFromMIME(mime)
        }

        if ext.isEmpty { ext = "bin" }
        return "\(hex).\(ext)"
    }

    /// Maps common MIME types to file extensions.
    private static func extensionFromMIME(_ mime: String) -> String {
        let base = mime.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? mime
        switch base {
        case "image/jpeg", "image/jpg":  return "jpg"
        case "image/png":                return "png"
        case "image/gif":                return "gif"
        case "image/webp":               return "webp"
        case "image/svg+xml":            return "svg"
        case "image/avif":               return "avif"
        case "image/heic":               return "heic"
        case "image/heif":               return "heif"
        case "image/tiff":               return "tiff"
        case "image/bmp":                return "bmp"
        case "image/ico",
             "image/x-icon",
             "image/vnd.microsoft.icon":  return "ico"
        case "text/css":                 return "css"
        case "application/font-woff",
             "font/woff":                return "woff"
        case "application/font-woff2",
             "font/woff2":               return "woff2"
        case "font/ttf",
             "application/x-font-ttf":   return "ttf"
        case "font/otf",
             "application/x-font-otf":   return "otf"
        default:                         return ""
        }
    }
}
