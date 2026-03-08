import Foundation
import SwiftSoup
import SwiftReadability
import CryptoKit
import GRDB
import WebKit

actor PageCacheService {
    static let shared = PageCacheService()

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private var session: URLSession = PageCacheService.makeSession()

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }

    private let maxTotalAssetBytes = 8 * 1024 * 1024  // 8 MB per article
    private let maxSingleAssetBytes = 2 * 1024 * 1024 // 2 MB per individual asset
    private let maxConcurrentDownloads = 8

    /// Shared asset pool directory — assets are stored once here and hardlinked into article dirs.
    private var sharedAssetsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("preread/shared_assets", isDirectory: true)
    }

    /// Fetches data with retry on QUIC/HTTP3 failures.
    /// On QUIC failure, invalidates the session and creates a fresh one to reset connection state.
    private func resilientData(for request: URLRequest, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await session.data(for: request)
            } catch {
                let nsError = error as NSError
                let isQUICError = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == -1017 || nsError.code == -1005)
                if isQUICError && attempt < maxRetries {
                    lastError = error
                    // Kill the poisoned session and create a fresh one
                    session.invalidateAndCancel()
                    session = Self.makeSession()
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    continue
                }
                throw error
            }
        }
        throw lastError!
    }

    private var articlesBaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("preread/articles", isDirectory: true)
    }

    /// Loads the reader template from the app bundle once.
    private var readerTemplate: String {
        guard let url = Bundle.main.url(forResource: "reader_template", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return "<html><body><h1>{{TITLE}}</h1>{{BODY_HTML}}</body></html>"
        }
        return template
    }

    // MARK: - Public API

    /// Caches an article's page content.
    /// - Parameters:
    ///   - article: The article to cache.
    ///   - cacheLevel: How much content to cache (.textOnly, .standard, .full).
    ///   - forceReprocess: When true, skips conditional headers (ETag/If-Modified-Since)
    ///     so the server always returns fresh content. Use this when reprocessing logic
    ///     has changed and you need to regenerate the cached HTML from scratch.
    func cacheArticle(_ article: Article, cacheLevel: CacheLevel, forceReprocess: Bool = false) async throws {
        var article = article
        let wasPreviouslyCached = article.fetchStatus == .cached

        // Mark as fetching
        article.fetchStatus = .fetching
        try updateArticle(&article)

        do {
            try await performCacheArticle(&article, cacheLevel: cacheLevel, wasPreviouslyCached: wasPreviouslyCached, forceReprocess: forceReprocess)
        } catch {
            // Ensure we never leave an article stuck at .fetching
            if article.fetchStatus == .fetching {
                if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                    article.fetchStatus = .cached
                } else {
                    article.fetchStatus = .failed
                }
                try? updateArticle(&article)
            }
        }
    }

    private func performCacheArticle(_ article: inout Article, cacheLevel: CacheLevel, wasPreviouslyCached: Bool, forceReprocess: Bool = false) async throws {
        // Build conditional request
        guard let pageURL = URL(string: article.articleURL) else {
            if !wasPreviouslyCached {
                article.fetchStatus = .failed
                try updateArticle(&article)
            }
            return
        }

        var request = URLRequest(url: pageURL)
        request.assumesHTTP3Capable = false
        // Skip conditional headers when force-reprocessing so we always get fresh content
        if !forceReprocess {
            if let etag = article.etag {
                request.addValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = article.lastModified {
                request.addValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await resilientData(for: request)
        } catch {
            print("[PageCacheService] Network error for \(article.articleURL): \(error.localizedDescription)")
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
            }
            try updateArticle(&article)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
            }
            try updateArticle(&article)
            return
        }

        // 304 Not Modified — content unchanged, just update timestamp
        // Only mark as cached if we actually have content on disk
        if httpResponse.statusCode == 304 {
            let articleDir = articlesBaseURL.appendingPathComponent(article.id.uuidString, isDirectory: true)
            let indexPath = articleDir.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexPath.path) {
                article.cachedAt = Date()
                article.fetchStatus = .cached
                try updateArticle(&article)
            }
            // No content on disk despite 304 — clear conditional headers so next
            // attempt does a full fetch, and mark as failed for now.
            else {
                article.etag = nil
                article.lastModified = nil
                article.fetchStatus = .failed
                try updateArticle(&article)
            }
            return
        }

        // Store conditional request headers from response
        if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
            article.etag = etag
        }
        if let lastMod = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
            article.lastModified = lastMod
        }

        // Validate response
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard httpResponse.statusCode == 200,
              contentType.contains("text/html"),
              data.count > 1000 else {
            print("[PageCacheService] Validation failed for \(article.articleURL): status=\(httpResponse.statusCode), contentType=\(contentType), dataSize=\(data.count)")
            article.lastHTTPStatus = httpResponse.statusCode
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
            }
            try updateArticle(&article)
            return
        }

        // Parse HTML
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? ""
        guard !html.isEmpty else {
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
            }
            try updateArticle(&article)
            return
        }

        // Set up article directory — wipe any previous cache so we don't
        // leave behind artifacts from a different cache level (e.g. CSS files,
        // dark HTML variants, or extra assets from full mode).
        let articleDir = articlesBaseURL.appendingPathComponent(article.id.uuidString, isDirectory: true)
        let assetsDir = articleDir.appendingPathComponent("assets", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: articleDir.path) {
            try? fm.removeItem(at: articleDir)
        }
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // Cache thumbnail locally (all cache levels)
        if let thumbStr = article.thumbnailURL, let thumbURL = URL(string: thumbStr) {
            await cacheThumbnail(url: thumbURL, to: articleDir)
        }

        let htmlData: Data
        let assetFilenames: [String]
        let totalSize: Int
        let isTruncated: Bool
        var anyFailed = false
        var cssInlineReplacements: [String: String] = [:]

        if cacheLevel == .full {
            // FULL: Save the complete page with all assets
            let doc = try SwiftSoup.parse(html, pageURL.absoluteString)

            // Strip CSP meta tags so Dark Reader can inject styles
            let cspMetas = try doc.select("meta[http-equiv=Content-Security-Policy]")
            try cspMetas.remove()

            // Strip <script> tags — page JS is blocked in the web view anyway
            let scripts = try doc.select("script")
            try scripts.remove()

            let assetURLs = try extractAssetURLs(from: doc, baseURL: pageURL, cacheLevel: cacheLevel)

            let downloadResults = await downloadAssets(
                urls: assetURLs,
                to: assetsDir,
                baseURL: pageURL
            )

            for result in downloadResults {
                switch result {
                case .success(let mapping):
                    try rewriteURL(in: doc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                case .failure:
                    anyFailed = true
                }
            }

            // Clean up remaining remote image references that weren't rewritten.
            // The webview blocks all https?:// requests, so any remaining srcset
            // entries or <picture><source> elements pointing to remote URLs will
            // fail to load. Strip them so the browser falls through to local src.
            try stripRemoteImageReferences(in: doc)

            // Inline CSS stylesheets directly into the HTML.
            // Dark Reader can't fetch() file:// URLs due to CORS, so it can't read
            // external <link> stylesheets. Inlining lets it access rules via the DOM.
            let cssLinks = try doc.select("link[rel=stylesheet][href]")
            for link in cssLinks {
                let href = try link.attr("href")
                let cssFileURL: URL
                if href.hasPrefix("./") {
                    cssFileURL = articleDir.appendingPathComponent(String(href.dropFirst(2)))
                } else {
                    cssFileURL = articleDir.appendingPathComponent(href)
                }
                if let cssData = try? Data(contentsOf: cssFileURL),
                   let cssText = String(data: cssData, encoding: .utf8) {
                    // Use a placeholder that we'll replace in the final HTML string,
                    // because SwiftSoup escapes content inside .text()
                    let placeholder = "/*PREREAD_CSS_\(UUID().uuidString)*/"
                    let styleTag = try doc.createElement("style")
                    try styleTag.append(placeholder)
                    try link.replaceWith(styleTag)
                    // Store for post-processing
                    cssInlineReplacements[placeholder] = cssText
                }
            }

            // Remove ALL remaining <link rel=stylesheet> that weren't inlined.
            // Successfully inlined links were already replaced with <style> tags above.
            // Any still present either failed to download or failed to read — they can't
            // be loaded from a local file:// webview and cause WebContent process crashes.
            let remainingCSS = try doc.select("link[rel=stylesheet]")
            try remainingCSS.remove()

            var finalHTML = try doc.outerHtml()
            // Replace CSS placeholders with actual CSS content
            for (placeholder, css) in cssInlineReplacements {
                finalHTML = finalHTML.replacingOccurrences(of: placeholder, with: css)
            }
            htmlData = Data(finalHTML.utf8)

            assetFilenames = downloadResults.compactMap { result -> String? in
                if case .success(let mapping) = result { return mapping.filename }
                return nil
            }
            totalSize = htmlData.count + downloadResults.reduce(0) { sum, result in
                if case .success(let mapping) = result { return sum + mapping.size }
                return sum
            }
            isTruncated = downloadResults.contains { result in
                if case .success(let mapping) = result { return mapping.wasTruncated }
                return false
            }
        } else {
            // STANDARD: Extract article content with Readability,
            // then template into reader_template.html

            // Clean HTML before feeding to Readability
            let preDoc = try SwiftSoup.parse(html, pageURL.absoluteString)
            try preDoc.select("script").remove()
            try preDoc.select("noscript").remove()
            try preDoc.select("style").remove()
            try preDoc.select("meta[http-equiv=Content-Security-Policy]").remove()

            // Remove placeholder images that JS-heavy sites (e.g. BBC) render
            // alongside real images. These have a no-JS fallback class and point
            // to a generic grey placeholder, cluttering the extracted content.
            try preDoc.select("img.hide-when-no-script").remove()
            try preDoc.select("img[src*=placeholder]").remove()

            // Unwrap <figure> elements so their children (img, figcaption, etc.)
            // become direct content nodes. Readability's cleanConditionally phase
            // removes figures with low text density, which drops legitimate images.
            try preDoc.select("figure").unwrap()

            // Flatten single-child wrapper <div>s so Readability can find the full article.
            // Many sites (e.g. ArsTechnica) wrap article paragraphs in deeply nested grid
            // layout containers. Readability scores nodes bottom-up and picks the highest-
            // scoring container, but deep nesting dilutes ancestor scores, causing it to
            // grab one fragment instead of the full article. Unwrapping pure structural
            // wrappers (divs with exactly one element child and no direct text) collapses
            // the nesting so content nodes share a closer common ancestor.
            flattenSingleChildDivs(in: preDoc)

            let cleanedHTML = try preDoc.html()

            let readability = Readability(html: cleanedHTML, url: pageURL)
            let extracted = try readability.parse()

            let articleTitle = extracted?.title ?? ""
            var contentHTML = extracted?.contentHTML ?? html

            // Download hero image from the feed thumbnail if available
            var heroImageHTML = ""
            var heroAssetFilename: String?
            var heroAssetSize = 0
            if let thumbStr = article.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                if let heroMapping = try? await downloadAsset(url: thumbURL, to: assetsDir) {
                    heroImageHTML = "<img class=\"reader-hero\" src=\"./assets/\(heroMapping.filename)\" alt=\"\">"
                    heroAssetFilename = heroMapping.filename
                    heroAssetSize = heroMapping.size
                }
            }

            // Parse the cleaned content to extract image URLs
            let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
            guard let contentBody = contentDoc.body() else {
                throw NSError(domain: "PageCacheService", code: 1, userInfo: nil)
            }

            // Remove any image in the content that matches the hero thumbnail
            // to avoid a duplicate hero stacked on top of the same image
            if let thumbStr = article.thumbnailURL {
                let contentImages = try contentDoc.select("img")
                for img in contentImages {
                    let src = try img.attr("abs:src")
                    let dataSrc = try img.attr("data-src")
                    if src == thumbStr || dataSrc == thumbStr {
                        try img.remove()
                    }
                }
            }

            let imageURLs = try extractAssetURLs(from: contentDoc, baseURL: pageURL, cacheLevel: .standard)

            let downloadResults = await downloadAssets(
                urls: imageURLs,
                to: assetsDir,
                baseURL: pageURL
            )

            // Rewrite image URLs in the content to local paths
            for result in downloadResults {
                switch result {
                case .success(let mapping):
                    try rewriteURL(in: contentDoc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                case .failure:
                    anyFailed = true
                }
            }

            contentHTML = (try? contentBody.html()) ?? contentHTML

            var allFilenames = downloadResults.compactMap { result -> String? in
                if case .success(let mapping) = result { return mapping.filename }
                return nil
            }
            if let heroFile = heroAssetFilename { allFilenames.append(heroFile) }
            assetFilenames = allFilenames

            let assetSize = downloadResults.reduce(0) { sum, result in
                if case .success(let mapping) = result { return sum + mapping.size }
                return sum
            } + heroAssetSize
            isTruncated = downloadResults.contains { result in
                if case .success(let mapping) = result { return mapping.wasTruncated }
                return false
            }

            // Build templated HTML and calculate total size
            let templatedHTML = readerTemplate
                .replacingOccurrences(of: "{{HERO_IMAGE}}", with: heroImageHTML)
                .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(articleTitle))
                .replacingOccurrences(of: "{{BODY_HTML}}", with: contentHTML)
            htmlData = Data(templatedHTML.utf8)
            totalSize = htmlData.count + assetSize
        }

        let indexPath = articleDir.appendingPathComponent("index.html")
        try htmlData.write(to: indexPath)

        // Generate pre-darkened variant for full-page caches
        var darkHtmlPath: String?
        if cacheLevel == .full {
            darkHtmlPath = await generateDarkVariant(articleDir: articleDir)
        }

        // Upsert CachedPage
        let cachedPage = CachedPage(
            articleID: article.id,
            htmlPath: indexPath.path,
            darkHtmlPath: darkHtmlPath,
            assetManifest: assetFilenames,
            cachedAt: Date(),
            totalSizeBytes: totalSize,
            isTruncated: isTruncated,
            cacheLevelUsed: cacheLevel
        )
        try await DatabaseManager.shared.dbPool.write { db in
            try cachedPage.save(db)
        }

        // Update article
        article.cachedAt = Date()
        article.cacheSizeBytes = totalSize
        article.fetchStatus = anyFailed ? .partial : .cached
        article.lastHTTPStatus = 200
        try updateArticle(&article)
    }

    /// Removes all cached files for an article.
    func deleteCachedArticle(_ articleID: UUID) throws {
        let articleDir = articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: articleDir.path) {
            try fm.removeItem(at: articleDir)
        }
        try DatabaseManager.shared.dbPool.write { db in
            try CachedPage.filter(Column("articleID") == articleID).deleteAll(db)
        }
    }

    /// Removes shared assets that are no longer hardlinked by any article.
    /// On APFS, a file with linkCount == 1 means only the shared pool copy remains.
    func cleanupOrphanedSharedAssets() {
        let fm = FileManager.default
        let sharedDir = sharedAssetsURL
        guard let files = try? fm.contentsOfDirectory(at: sharedDir, includingPropertiesForKeys: [.linkCountKey]) else { return }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.linkCountKey]),
                  let linkCount = values.linkCount,
                  linkCount <= 1 else { continue }
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Asset extraction

    private func extractAssetURLs(from doc: Document, baseURL: URL, cacheLevel: CacheLevel) throws -> [URL] {
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
            // Source elements for video/audio
            let mediaSources = try doc.select("video > source[src], audio > source[src]")
            for source in mediaSources {
                let src = try source.attr("abs:src")
                if let url = URL(string: src) { urls.append(url) }
            }
        }

        // Deduplicate while preserving order
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Target width in CSS pixels for srcset selection.
    /// 2x retina on a ~390pt-wide iPhone ≈ 780px, but article content areas are
    /// typically narrower than full screen. ~1200px gives sharp images on any
    /// current device without downloading unnecessarily large variants.
    private let srcsetTargetWidth = 1200

    /// Parses a srcset attribute value and returns the best URL for our target width.
    /// Handles width descriptors (e.g. "img-300.jpg 300w, img-600.jpg 600w") and
    /// pixel-density descriptors (e.g. "img.jpg 1x, img@2x.jpg 2x").
    /// Falls back to the first entry when no descriptors are present.
    private func bestURLFromSrcset(_ srcset: String, baseURL: URL) -> URL? {
        let entries = srcset.components(separatedBy: ",")
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

        // If we have width descriptors, pick the smallest one >= target, or the largest available
        let withWidths = candidates.filter { $0.width > 0 }
        let chosen: String
        if !withWidths.isEmpty {
            let atOrAbove = withWidths.filter { $0.width >= srcsetTargetWidth }
                .sorted { $0.width < $1.width }
            if let best = atOrAbove.first {
                chosen = best.url
            } else {
                // All smaller than target — pick the largest
                chosen = withWidths.sorted { $0.width > $1.width }.first!.url
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
        // Fall back to data-src
        let dataSrc = try img.attr("data-src")
        if !dataSrc.isEmpty, !dataSrc.hasPrefix("data:") {
            if let url = URL(string: dataSrc, relativeTo: baseURL)?.absoluteURL, !isPlaceholderImage(url) { return url }
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

    private struct AssetMapping {
        let originalURL: String
        let filename: String
        let size: Int
        let wasTruncated: Bool
    }

    private func downloadAssets(urls: [URL], to assetsDir: URL, baseURL: URL) async -> [Result<AssetMapping, Error>] {
        guard !urls.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, Result<AssetMapping, Error>).self) { group in
            var results = [Result<AssetMapping, Error>?](repeating: nil, count: urls.count)
            var cumulativeSize = 0
            var sizeLimitReached = false

            for (index, url) in urls.enumerated() {
                group.addTask { [self] in
                    do {
                        let mapping = try await self.downloadAsset(url: url, to: assetsDir)
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

    private func downloadAsset(url: URL, to assetsDir: URL) async throws -> AssetMapping {
        let filename = hashedFilename(for: url)
        let filePath = assetsDir.appendingPathComponent(filename)
        let fm = FileManager.default

        // Check shared pool first — if we already downloaded this asset for another article,
        // hardlink it instead of re-downloading
        let sharedDir = sharedAssetsURL
        try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let sharedPath = sharedDir.appendingPathComponent(filename)

        if fm.fileExists(atPath: sharedPath.path) {
            let attrs = try fm.attributesOfItem(atPath: sharedPath.path)
            let size = (attrs[.size] as? Int) ?? 0
            // Remove existing file at destination (e.g. from a previous cache)
            // before hardlinking, since linkItem throws if destination exists
            try? fm.removeItem(at: filePath)
            try fm.linkItem(at: sharedPath, to: filePath)
            return AssetMapping(
                originalURL: url.absoluteString,
                filename: filename,
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
        if data.count > maxSingleAssetBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }

        // Validate content type — reject HTML error pages saved as images
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            let validPrefixes = ["image/", "text/css", "font/", "application/font", "application/x-font",
                                 "image/svg+xml", "application/octet-stream"]
            let isValid = validPrefixes.contains { contentType.hasPrefix($0) }
            if !isValid {
                throw URLError(.cannotDecodeContentData)
            }
        }

        // Write to shared pool, then hardlink into article dir
        try data.write(to: sharedPath)
        // Remove existing file at destination before hardlinking
        try? fm.removeItem(at: filePath)
        try fm.linkItem(at: sharedPath, to: filePath)

        return AssetMapping(
            originalURL: url.absoluteString,
            filename: filename,
            size: data.count,
            wasTruncated: false
        )
    }

    /// Downloads the article thumbnail to a predictable local path for offline display.
    private func cacheThumbnail(url: URL, to articleDir: URL) async {
        do {
            var request = URLRequest(url: url)
            request.assumesHTTP3Capable = false
            let (data, response) = try await resilientData(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) { return }
            guard data.count > 100 else { return } // skip tiny/broken images

            let ext = url.pathExtension.lowercased()
            let fileExt = ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext) ? ext : "jpg"
            let thumbPath = articleDir.appendingPathComponent("thumbnail.\(fileExt)")
            try data.write(to: thumbPath)
        } catch {
            // Thumbnail caching is best-effort; don't fail the article cache
        }
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

    private func rewriteURL(in doc: Document, original: String, replacement: String) throws {
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

        // Rewrite video/audio source src
        let mediaSources = try doc.select("video > source[src], audio > source[src]")
        for source in mediaSources {
            let src = try source.attr("abs:src")
            if src == original {
                try source.attr("src", replacement)
            }
        }
    }

    /// Checks if any entry in an element's srcset matches the original URL.
    /// If it matches, sets src to the replacement and returns true.
    private func rewriteSrcsetIfMatching(element: Element, original: String, originalURL: URL?, replacement: String) throws -> Bool {
        let srcset = try element.attr("srcset")
        guard !srcset.isEmpty else { return false }

        let entries = srcset.components(separatedBy: ",")
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

    // MARK: - Remote image cleanup

    /// Strips remaining non-local references after URL rewriting.
    /// Removes `<source>` elements inside `<picture>` that weren't rewritten to local paths,
    /// and strips non-local srcset/src from `<img>` tags to prevent WKWebView sandbox errors.
    private func stripRemoteImageReferences(in doc: Document) throws {
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
                // Image download failed — clear src to avoid sandbox errors
                try img.attr("src", "")
                try img.removeAttr("srcset")
                try img.removeAttr("srcSet")
                try img.removeAttr("sizes")
            }
        }
    }

    // MARK: - DOM flattening

    /// Unwraps `<div>` elements that serve purely as layout wrappers — those with exactly
    /// one element child and no meaningful direct text. Runs multiple passes until no more
    /// wrappers can be collapsed. This is critical for Readability to work correctly on
    /// sites that nest article content inside deep grid/flex layout structures.
    private func flattenSingleChildDivs(in doc: Document) {
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
                // Only unwrap if the single child is also a <div>
                guard elementChildren[0].tagName() == "div" else { continue }
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

    // MARK: - Helpers

    /// SHA256 hash of URL string + original extension.
    private func hashedFilename(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        // Strip query from extension if present
        let cleanExt = ext.components(separatedBy: "?").first ?? ext
        return "\(hex).\(cleanExt)"
    }

    private func updateArticle(_ article: inout Article) throws {
        try DatabaseManager.shared.dbPool.write { db in
            try article.update(db)
        }
    }

    /// Checks whether an article has actual cached HTML content on disk.
    private func hasCachedContentOnDisk(for article: Article) -> Bool {
        let indexPath = articlesBaseURL
            .appendingPathComponent(article.id.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: indexPath.path)
    }

    /// Public wrapper for external callers (e.g. FetchCoordinator) to verify cached content exists.
    func hasCachedContent(for article: Article) -> Bool {
        hasCachedContentOnDisk(for: article)
    }

    /// Escapes HTML special characters for safe insertion into HTML attributes/text.
    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Dark variant generation

    /// Generates a pre-darkened version of a full-page cached article using Dark Reader
    /// in a headless WKWebView. Saves the result as `index-dark.html` alongside the original.
    /// Returns the file path on success, nil on failure.
    func generateDarkVariant(articleDir: URL) async -> String? {
        let indexURL = articleDir.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }

        guard let drURL = Bundle.main.url(forResource: "darkreader.min", withExtension: "js"),
              let drSource = try? String(contentsOf: drURL, encoding: .utf8) else {
            return nil
        }

        let darkURL = articleDir.appendingPathComponent("index-dark.html")

        do {
            let darkHTML = try await DarkVariantRenderer.render(
                htmlFileURL: indexURL,
                articleDirectory: articleDir,
                darkReaderSource: drSource
            )
            try Data(darkHTML.utf8).write(to: darkURL)
            return darkURL.path
        } catch {
            print("[PageCacheService] Dark variant generation failed: \(error)")
            return nil
        }
    }
}

// MARK: - Headless Dark Reader renderer

/// Runs Dark Reader in a headless WKWebView to produce pre-darkened HTML.
/// Must be called from the main actor since WKWebView requires the main thread.
@MainActor
private final class DarkVariantRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private let darkReaderSource: String

    private init(darkReaderSource: String) {
        self.darkReaderSource = darkReaderSource
        super.init()
    }

    static func render(
        htmlFileURL: URL,
        articleDirectory: URL,
        darkReaderSource: String
    ) async throws -> String {
        let renderer = DarkVariantRenderer(darkReaderSource: darkReaderSource)
        return try await renderer.process(htmlFileURL: htmlFileURL, articleDirectory: articleDirectory)
    }

    private func process(htmlFileURL: URL, articleDirectory: URL) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation

                    let config = WKWebViewConfiguration()
                    config.defaultWebpagePreferences.allowsContentJavaScript = true

                    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
                    webView.navigationDelegate = self
                    self.webView = webView

                    webView.loadFileURL(htmlFileURL, allowingReadAccessTo: articleDirectory)
                }
            }

            // Timeout task — 15 seconds is more than enough for Dark Reader
            group.addTask { @MainActor in
                try await Task.sleep(for: .seconds(15))
                throw NSError(domain: "DarkVariantRenderer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Dark variant generation timed out"])
            }

            // Return whichever finishes first; cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await self.injectDarkReaderAndSnapshot(webView: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.finish(with: .failure(NSError(domain: "DarkVariantRenderer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "WebContent process crashed during dark variant rendering"])))
        }
    }

    // MARK: - Dark Reader injection

    private func injectDarkReaderAndSnapshot(webView: WKWebView) async {
        // Step 1: Cleanup — remove CSP, scripts, noscript, inline remaining stylesheets
        let cleanupJS = """
        (function() {
            document.querySelectorAll('meta[http-equiv="Content-Security-Policy"]').forEach(function(el) { el.remove(); });
            document.querySelectorAll('script').forEach(function(el) { el.remove(); });
            document.querySelectorAll('noscript').forEach(function(el) { el.remove(); });
            var remaining = document.querySelectorAll('link[rel="stylesheet"]');
            remaining.forEach(function(link) {
                try {
                    var xhr = new XMLHttpRequest();
                    xhr.open('GET', link.href, false);
                    xhr.send();
                    if (xhr.status === 200 || xhr.status === 0) {
                        var style = document.createElement('style');
                        style.textContent = xhr.responseText;
                        link.parentNode.replaceChild(style, link);
                    }
                } catch(e) {}
            });
        })();
        """

        // Step 2: Inject Dark Reader and enable with same config as CachedWebView
        let enableJS = cleanupJS + darkReaderSource + """
        \nDarkReader.enable({
            brightness: 100,
            contrast: 95,
            sepia: 0
        }, {
            css: 'html, body { background-color: #000000 !important; } a { color: #7B7BEE !important; } pre, code { background-color: #1C1C28 !important; }'
        });
        """

        do {
            try await webView.evaluateJavaScript(enableJS)
        } catch {
            finish(with: .failure(error))
            return
        }

        // Step 3: Wait for Dark Reader's MutationObserver-based processing to finish
        try? await Task.sleep(for: .seconds(2))

        // Step 4: Snapshot the DOM
        let snapshotJS = "document.documentElement.outerHTML;"
        do {
            let result = try await webView.evaluateJavaScript(snapshotJS)
            if let html = result as? String {
                let fullHTML = "<!DOCTYPE html>\n" + html
                finish(with: .success(fullHTML))
            } else {
                finish(with: .failure(NSError(domain: "DarkVariantRenderer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to extract HTML from DOM"])))
            }
        } catch {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.webView?.navigationDelegate = nil
        self.webView = nil
        continuation.resume(with: result)
    }
}
