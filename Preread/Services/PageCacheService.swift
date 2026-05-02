import Foundation
import UIKit
import SwiftSoup
import SwiftReadability
import CryptoKit
import GRDB
import WebKit

/// Result of running the standard-mode HTML pipeline (cleaning, Readability
/// extraction, hero re-injection, post-processing). Used by unit tests to
/// verify pipeline behaviour against saved HTML fixtures.
struct PipelineResult {
    let title: String
    let contentHTML: String
    let imageCount: Int
    let heroImageURL: String?
    let wordCount: Int
}

/// Result of running the full-mode HTML cleaning pipeline. Used by unit tests
/// to verify that interactive elements are stripped without breaking page layout.
struct FullPipelineResult {
    let cleanedHTML: String
    let heroImageURL: String?
    let wordCount: Int
}

actor PageCacheService {
    static let shared = PageCacheService()

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    var session: URLSession = PageCacheService.makeSession()

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }

    let maxTotalAssetBytes = 8 * 1024 * 1024  // 8 MB per article
    let maxSingleAssetBytes = 2 * 1024 * 1024 // 2 MB per individual asset
    let maxHeroAssetBytes = 3 * 1024 * 1024   // 3 MB for hero images
    let maxConcurrentDownloads = 8

    /// Shared asset pool directory — assets are stored once here and hardlinked into article dirs.
    var sharedAssetsURL: URL {
        ContainerPaths.sharedAssetsURL
    }

    /// Fetches data with retry on QUIC/HTTP3 failures.
    /// On QUIC failure, invalidates the session and creates a fresh one to reset connection state.
    func resilientData(for request: URLRequest, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
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
        throw lastError ?? URLError(.unknown)
    }

    /// Returns true if the URL is a Google News redirect that needs resolution.
    static func isGoogleNewsURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "news.google.com",
              url.path.contains("articles") || url.path.contains("read") else {
            return false
        }
        return true
    }

    /// Resolves a Google News redirect URL to the real article URL.
    /// Google News RSS feeds return URLs like `news.google.com/rss/articles/CBMi...`
    /// that use JS-based redirects. This method extracts the real URL by fetching
    /// decoding parameters from the page and calling Google's batchexecute API.
    /// Returns the original URL unchanged if it's not a Google News URL or resolution fails.
    func resolveGoogleNewsURL(_ url: URL) async -> URL {
        guard let host = url.host?.lowercased(),
              host == "news.google.com",
              url.path.contains("articles") || url.path.contains("read") else {
            return url
        }

        // Extract the base64 article ID from the URL path
        let pathComponents = url.path.split(separator: "/")
        guard let base64ID = pathComponents.last.map(String.init), !base64ID.isEmpty else {
            return url
        }

        do {
            // Step 1: Fetch the Google News page to get decoding parameters
            var pageRequest = URLRequest(url: url)
            pageRequest.assumesHTTP3Capable = false
            let (pageData, _) = try await session.data(for: pageRequest)
            let pageHTML = String(data: pageData, encoding: .utf8) ?? ""

            // Extract data-n-a-ts (timestamp) and data-n-a-sg (signature)
            guard let tsRange = pageHTML.range(of: #"data-n-a-ts="([^"]+)""#, options: .regularExpression),
                  let sgRange = pageHTML.range(of: #"data-n-a-sg="([^"]+)""#, options: .regularExpression) else {
                print("[PageCacheService] Google News: could not find decoding params")
                return url
            }

            let tsMatch = pageHTML[tsRange]
            let sgMatch = pageHTML[sgRange]
            let timestamp = String(tsMatch.split(separator: "\"")[1])
            let signature = String(sgMatch.split(separator: "\"")[1])

            // Step 2: Call batchexecute to resolve the real URL
            let bq = "\\\""
            let inner = "[\(bq)garturlreq\(bq),[[\(bq)en\(bq),\(bq)US\(bq),[\(bq)FINANCE_TOP_INDICES\(bq),\(bq)WEB_TEST_1_0_0\(bq)],null,null,1,1,\(bq)US:en\(bq),null,180,null,null,null,null,null,0,null,null,[1608992183,723341000]],\(bq)en\(bq),\(bq)US\(bq),1,[2,3,4,8],1,1,null,0,0,null,0],\(bq)\(base64ID)\(bq),\(bq)\(timestamp)\(bq),\(bq)\(signature)\(bq)]"
            let reqPayload = "[[[\"Fbv4je\",\"\(inner)\",\"generic\"]]]"

            var batchRequest = URLRequest(url: URL(string: "https://news.google.com/_/DotsSplashUi/data/batchexecute")!)
            batchRequest.httpMethod = "POST"
            batchRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            batchRequest.assumesHTTP3Capable = false

            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "f.req", value: reqPayload)]
            batchRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)

            let (batchData, _) = try await session.data(for: batchRequest)
            let batchResponse = String(data: batchData, encoding: .utf8) ?? ""

            // Parse the response — find "garturlres" then extract the URL after it
            if let garRange = batchResponse.range(of: "garturlres") {
                let afterGar = String(batchResponse[garRange.upperBound...])
                if let httpsRange = afterGar.range(of: "https://[^\"\\\\]+", options: .regularExpression) {
                    let realURLString = String(afterGar[httpsRange])
                    if let realURL = URL(string: realURLString) {
                        print("[PageCacheService] Google News resolved: \(realURL.absoluteString)")
                        return realURL
                    }
                }
            }

            print("[PageCacheService] Google News: could not parse batchexecute response")
            return url
        } catch {
            print("[PageCacheService] Google News resolution failed: \(error.localizedDescription)")
            return url
        }
    }

    var articlesBaseURL: URL {
        ContainerPaths.articlesBaseURL
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
    /// Result of a cacheArticle call, indicating whether content was actually updated.
    enum CacheResult {
        /// New content was fetched and written to disk.
        case contentUpdated
        /// Server returned 304 — content unchanged, only timestamp updated.
        case notModified
        /// Caching failed (network error, validation error, etc.).
        case failed
    }

    @discardableResult
    func cacheArticle(_ article: Article, cacheLevel: CacheLevel, forceReprocess: Bool = false) async throws -> CacheResult {
        var article = article
        let wasPreviouslyCached = article.fetchStatus == .cached

        // Mark as fetching
        article.fetchStatus = .fetching
        try updateArticle(&article)

        do {
            let result = try await performCacheArticle(&article, cacheLevel: cacheLevel, wasPreviouslyCached: wasPreviouslyCached, forceReprocess: forceReprocess)
            return result
        } catch {
            // Ensure we never leave an article stuck at .fetching
            if article.fetchStatus == .fetching {
                if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                    article.fetchStatus = .cached
                } else {
                    article.fetchStatus = .failed
                    article.retryCount += 1
                }
                try? updateArticle(&article)
            }
            return .failed
        }
    }

    // MARK: - Cache article

    private func performCacheArticle(_ article: inout Article, cacheLevel: CacheLevel, wasPreviouslyCached: Bool, forceReprocess: Bool = false) async throws -> CacheResult {
        // Build conditional request
        guard var pageURL = URL(string: article.articleURL) else {
            if !wasPreviouslyCached {
                article.fetchStatus = .failed
                article.retryCount += 1
                try updateArticle(&article)
            }
            return .failed
        }

        // Resolve Google News redirect URLs to real article URLs
        if Self.isGoogleNewsURL(pageURL) {
            let resolvedURL = await resolveGoogleNewsURL(pageURL)
            if resolvedURL != pageURL {
                pageURL = resolvedURL
                article.articleURL = resolvedURL.absoluteString
                try? updateArticle(&article)
            } else {
                // Resolution failed — don't try to cache the Google News
                // redirect page (it's JS-only and produces garbage content)
                article.fetchStatus = .failed
                article.retryCount += 1
                try updateArticle(&article)
                return .failed
            }
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
                article.retryCount += 1
            }
            try updateArticle(&article)
            return .failed
        }

        // Update pageURL to the final URL after redirects, so relative
        // URLs in the HTML resolve correctly against the actual page location.
        if let responseURL = response.url, responseURL != pageURL {
            pageURL = responseURL
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
                article.retryCount += 1
            }
            try updateArticle(&article)
            return .failed
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
                article.retryCount += 1
                try updateArticle(&article)
            }
            return .notModified
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
        let httpValidationPassed = httpResponse.statusCode == 200
            && contentType.contains("text/html")
            && data.count > 1000

        if !httpValidationPassed {
            print("[PageCacheService] Validation failed for \(article.articleURL): status=\(httpResponse.statusCode), contentType=\(contentType), dataSize=\(data.count)")
            article.lastHTTPStatus = httpResponse.statusCode

            // If RSS content is available, let the pipeline run on empty HTML —
            // it will throw, and the catch block will fall back to RSS content.
            if article.rssContentHTML == nil || article.rssContentHTML!.isEmpty {
                if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                    article.fetchStatus = .cached
                } else {
                    article.fetchStatus = .failed
                    article.retryCount += 1
                }
                try updateArticle(&article)
                return .failed
            }
            print("[PageCacheService] HTTP \(httpResponse.statusCode) for \(article.articleURL), will try RSS content fallback")
        }

        // Parse HTML from HTTP response (empty when HTTP failed but RSS fallback exists)
        let html: String
        if httpValidationPassed {
            html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
                ?? ""
            if html.isEmpty {
                // Empty body — try RSS fallback if available, otherwise fail
                if article.rssContentHTML == nil || article.rssContentHTML!.isEmpty {
                    if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                        article.fetchStatus = .cached
                    } else {
                        article.fetchStatus = .failed
                        article.retryCount += 1
                    }
                    try updateArticle(&article)
                    return .failed
                }
                print("[PageCacheService] Empty HTML body for \(article.articleURL), will try RSS content fallback")
            }
        } else {
            html = ""
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
        var pipelineHeroImageURL: String?
        var readingMinutes: Int?
        var usedRSSFallback = false

        if cacheLevel == .full {
            // FULL: Save the complete page with all assets
            do {
                let fullResult = try runFullPipeline(html: html, pageURL: pageURL)

                // Quality gate: if cleaned page has very little text (SPA shell),
                // throw to trigger RSS fallback below.
                if fullResult.wordCount < 50, let rssHTML = article.rssContentHTML, !rssHTML.isEmpty {
                    throw NSError(domain: "PageCacheService", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Full-mode content too thin (\(fullResult.wordCount) words) — falling back to RSS"
                    ])
                }

                pipelineHeroImageURL = fullResult.heroImageURL
                readingMinutes = ReadingTimeFormatter.estimateMinutes(wordCount: fullResult.wordCount)
                let doc = try SwiftSoup.parse(fullResult.cleanedHTML, pageURL.absoluteString)

                let assetURLs = try extractAssetURLs(from: doc, baseURL: pageURL, cacheLevel: cacheLevel)

                let downloadResults = await downloadAssets(
                    urls: assetURLs,
                    to: assetsDir,
                    baseURL: pageURL,
                    heroImageURL: pipelineHeroImageURL
                )

                for result in downloadResults {
                    switch result {
                    case .success(let mapping):
                        try rewriteURL(in: doc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                    case .failure:
                        anyFailed = true
                    }
                }

                // Fallback: try src attribute for images whose srcset download failed
                let fallbackResults = try await downloadSrcFallbackImages(in: doc, assetsDir: assetsDir, baseURL: pageURL)
                for result in fallbackResults {
                    if case .success(let mapping) = result {
                        try rewriteURL(in: doc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                    }
                }

                // Fallback: try parent <a> href for images that still failed (e.g. oversized originals)
                let anchorFallbackResults = try await downloadAnchorFallbackImages(in: doc, assetsDir: assetsDir, baseURL: pageURL)

                // Clean up remaining remote image references that weren't rewritten.
                try stripRemoteImageReferences(in: doc)

                // Inline CSS stylesheets directly into the HTML so the page is
                // fully self-contained for offline viewing.
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
                        let placeholder = "/*PREREAD_CSS_\(UUID().uuidString)*/"
                        let styleTag = try doc.createElement("style")
                        try styleTag.append(placeholder)
                        try link.replaceWith(styleTag)
                        cssInlineReplacements[placeholder] = cssText
                    }
                }

                // Remove remaining <link rel=stylesheet> that weren't inlined.
                let remainingCSS = try doc.select("link[rel=stylesheet]")
                try remainingCSS.remove()

                var finalHTML = try doc.outerHtml()
                for (placeholder, css) in cssInlineReplacements {
                    finalHTML = finalHTML.replacingOccurrences(of: placeholder, with: css)
                }
                htmlData = Data(finalHTML.utf8)

                let allFullResults = downloadResults + fallbackResults + anchorFallbackResults
                assetFilenames = allFullResults.compactMap { result -> String? in
                    if case .success(let mapping) = result { return mapping.filename }
                    return nil
                }
                totalSize = htmlData.count + allFullResults.reduce(0) { sum, result in
                    if case .success(let mapping) = result { return sum + mapping.size }
                    return sum
                }
                isTruncated = allFullResults.contains { result in
                    if case .success(let mapping) = result { return mapping.wasTruncated }
                    return false
                }
            } catch {
                // Full pipeline failed (content too short / SPA page).
                // Fall back to RSS content in reader template (downgrade to standard).
                guard let rssHTML = article.rssContentHTML, !rssHTML.isEmpty else {
                    throw error
                }
                print("[PageCacheService] Full pipeline failed, falling back to RSS content for \(article.articleURL)")
                usedRSSFallback = true
                let rssResult = try cleanRSSContent(html: rssHTML, baseURL: pageURL)
                pipelineHeroImageURL = rssResult.heroImageURL
                readingMinutes = ReadingTimeFormatter.estimateMinutes(wordCount: rssResult.wordCount)

                var rssContentHTML = rssResult.contentHTML

                let rssContentDoc = try SwiftSoup.parseBodyFragment(rssContentHTML, pageURL.absoluteString)
                let rssImageURLs = try extractAssetURLs(from: rssContentDoc, baseURL: pageURL, cacheLevel: .standard)
                let rssDownloadResults = await downloadAssets(urls: rssImageURLs, to: assetsDir, baseURL: pageURL, heroImageURL: pipelineHeroImageURL)
                for result in rssDownloadResults {
                    switch result {
                    case .success(let mapping):
                        try rewriteURL(in: rssContentDoc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                    case .failure:
                        anyFailed = true
                    }
                }

                // Fallback: try src attribute for images whose srcset download failed
                let rssFallbackResults = try await downloadSrcFallbackImages(in: rssContentDoc, assetsDir: assetsDir, baseURL: pageURL)
                for result in rssFallbackResults {
                    if case .success(let mapping) = result {
                        try rewriteURL(in: rssContentDoc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                    }
                }
                // Fallback: try parent <a> href for images that still failed
                let rssAnchorFallbackResults = try await downloadAnchorFallbackImages(in: rssContentDoc, assetsDir: assetsDir, baseURL: pageURL)
                try stripRemoteImageReferences(in: rssContentDoc)

                rssContentHTML = (try? rssContentDoc.body()?.html()) ?? rssContentHTML

                let allRssResults = rssDownloadResults + rssFallbackResults + rssAnchorFallbackResults
                assetFilenames = allRssResults.compactMap { result -> String? in
                    if case .success(let mapping) = result { return mapping.filename }
                    return nil
                }

                let templatedHTML = readerTemplate
                    .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(article.title))
                    .replacingOccurrences(of: "{{BODY_HTML}}", with: rssContentHTML)
                htmlData = Data(templatedHTML.utf8)
                let assetSize = allRssResults.reduce(0) { sum, result in
                    if case .success(let mapping) = result { return sum + mapping.size }
                    return sum
                }
                totalSize = htmlData.count + assetSize
                isTruncated = false
            }
        } else {
            // STANDARD: Extract article content with Readability,
            // then template into reader_template.html

            var pipelineResult: PipelineResult

            do {
                pipelineResult = try runStandardPipeline(html: html, pageURL: pageURL)

                // Quality gate: if Readability extracted very little text (e.g. SPA shell
                // footer), prefer RSS content if available, otherwise fail rather than
                // caching garbage content.
                if pipelineResult.wordCount < 50 {
                    if let rssHTML = article.rssContentHTML, !rssHTML.isEmpty {
                        print("[PageCacheService] Extracted content too thin (\(pipelineResult.wordCount) words), falling back to RSS content for \(article.articleURL)")
                        pipelineResult = try cleanRSSContent(html: rssHTML, baseURL: pageURL)
                        usedRSSFallback = true
                    } else {
                        throw NSError(domain: "PageCacheService", code: 3, userInfo: [
                            NSLocalizedDescriptionKey: "Extracted content too thin (\(pipelineResult.wordCount) words) and no RSS fallback available — page may require JavaScript"
                        ])
                    }
                }
            } catch {
                // Standard pipeline failed (Readability returned nil or content too short).
                // Fall back to RSS content:encoded if available.
                guard let rssHTML = article.rssContentHTML, !rssHTML.isEmpty else {
                    throw error
                }
                print("[PageCacheService] Standard pipeline failed, falling back to RSS content for \(article.articleURL)")
                pipelineResult = try cleanRSSContent(html: rssHTML, baseURL: pageURL)
                usedRSSFallback = true
            }

            pipelineHeroImageURL = pipelineResult.heroImageURL
            readingMinutes = ReadingTimeFormatter.estimateMinutes(wordCount: pipelineResult.wordCount)
            let articleTitle = usedRSSFallback ? article.title : pipelineResult.title
            var contentHTML = pipelineResult.contentHTML

            // Re-parse for asset extraction and URL rewriting
            let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
            guard let contentBody = contentDoc.body() else {
                throw NSError(domain: "PageCacheService", code: 1, userInfo: nil)
            }

            let imageURLs = try extractAssetURLs(from: contentDoc, baseURL: pageURL, cacheLevel: .standard)

            let downloadResults = await downloadAssets(
                urls: imageURLs,
                to: assetsDir,
                baseURL: pageURL,
                heroImageURL: pipelineHeroImageURL
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

            // Fallback: try src attribute for images whose srcset download failed
            let fallbackResults = try await downloadSrcFallbackImages(in: contentDoc, assetsDir: assetsDir, baseURL: pageURL)
            for result in fallbackResults {
                if case .success(let mapping) = result {
                    try rewriteURL(in: contentDoc, original: mapping.originalURL, replacement: "./assets/\(mapping.filename)")
                }
            }

            // Fallback: try parent <a> href for images that still failed (e.g. oversized originals)
            let anchorFallbackResults = try await downloadAnchorFallbackImages(in: contentDoc, assetsDir: assetsDir, baseURL: pageURL)

            // Clean up remaining remote images to prevent dead boxes offline
            try stripRemoteImageReferences(in: contentDoc)

            contentHTML = (try? contentBody.html()) ?? contentHTML

            let allResults = downloadResults + fallbackResults + anchorFallbackResults
            let allFilenames = allResults.compactMap { result -> String? in
                if case .success(let mapping) = result { return mapping.filename }
                return nil
            }
            assetFilenames = allFilenames

            let assetSize = allResults.reduce(0) { sum, result in
                if case .success(let mapping) = result { return sum + mapping.size }
                return sum
            }
            isTruncated = allResults.contains { result in
                if case .success(let mapping) = result { return mapping.wasTruncated }
                return false
            }

            // If the article has no images but a thumbnail was cached from the
            // RSS feed, inject it as a hero below the title so the reader
            // isn't purely text.
            if pipelineResult.imageCount == 0 {
                let thumbnailPath = articleDir.appendingPathComponent("thumbnail.jpg")
                if FileManager.default.fileExists(atPath: thumbnailPath.path) {
                    contentHTML = "<img src=\"./thumbnail.jpg\" />" + contentHTML
                }
            }

            // Build templated HTML and calculate total size
            let templatedHTML = readerTemplate
                .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(articleTitle))
                .replacingOccurrences(of: "{{BODY_HTML}}", with: contentHTML)
            htmlData = Data(templatedHTML.utf8)
            totalSize = htmlData.count + assetSize
        }

        // Always prefer the pipeline hero over the RSS feed thumbnail.
        // The pipeline applies full cleaning (banner stripping, readability
        // extraction, hero candidate filtering) while the RSS thumbnail is
        // just the first image in raw feed content — often a promotional
        // banner or logo.
        if let heroSrc = pipelineHeroImageURL,
           let heroURL = URL(string: heroSrc, relativeTo: pageURL) {
            let resolved = heroURL.absoluteString
            if article.thumbnailURL != resolved {
                article.thumbnailURL = resolved
                await cacheThumbnail(url: heroURL, to: articleDir)
                ThumbnailCache.shared.removeRowThumbnail(for: article.id)
                ThumbnailCache.shared.removeCardThumbnail(for: article.id)
            }
        }

        // Cache a per-article favicon extracted from the page's HTML.
        // This is useful for multi-source feeds (e.g. Google News keyword feeds)
        // where each article comes from a different site.
        let articleFaviconPath = articleDir.appendingPathComponent("favicon.png")
        if !FileManager.default.fileExists(atPath: articleFaviconPath.path) {
            if let rawDoc = try? SwiftSoup.parse(html, pageURL.absoluteString) {
                await cacheArticleFavicon(for: article.id, fromDoc: rawDoc, baseURL: pageURL)
            }
        }

        let indexPath = articleDir.appendingPathComponent("index.html")
        try htmlData.write(to: indexPath)

        // Upsert CachedPage
        let cachedPage = CachedPage(
            articleID: article.id,
            htmlPath: indexPath.path,
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
        article.readingMinutes = readingMinutes
        article.fetchStatus = anyFailed ? .partial : .cached
        article.lastHTTPStatus = 200
        if !usedRSSFallback {
            article.rssContentHTML = nil  // Free DB space — page pipeline succeeded without RSS fallback
        }
        try updateArticle(&article)
        return .contentUpdated
    }

    /// Removes all cached files for an article.
    func deleteCachedArticle(_ articleID: UUID) throws {
        let articleDir = articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: articleDir.path) {
            try fm.removeItem(at: articleDir)
        }
        _ = try DatabaseManager.shared.dbPool.write { db in
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

    // MARK: - Database & disk utilities

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

    /// Verifies that cached HTML actually contains meaningful article text.
    /// More expensive than hasCachedContentOnDisk — reads and parses the file.
    /// Used to detect articles that were cached before the empty-content guard
    /// was added (e.g. JS-rendered SPAs that produced empty templates).
    private func cachedContentHasMeaningfulText(for article: Article) -> Bool {
        let indexPath = articlesBaseURL
            .appendingPathComponent(article.id.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")
        guard let data = try? Data(contentsOf: indexPath),
              let html = String(data: data, encoding: .utf8),
              let doc = try? SwiftSoup.parse(html),
              let bodyText = try? doc.body()?.text().trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return bodyText.count >= 50
    }

    /// Public wrapper for external callers (e.g. FetchCoordinator, ArticleListView)
    /// to verify cached content exists and has meaningful text.
    func hasCachedContent(for article: Article) -> Bool {
        guard hasCachedContentOnDisk(for: article) else { return false }
        return cachedContentHasMeaningfulText(for: article)
    }

    /// Returns the current on-disk URL for an article's cached HTML.
    /// Always builds the path dynamically so it survives container path changes
    /// (e.g. simulator rebuilds).
    func cachedHTMLURL(for articleID: UUID) -> URL {
        articlesBaseURL
            .appendingPathComponent(articleID.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")
    }

    /// Deletes all cached data for a source (favicon, etc).
    func deleteSourceCache(_ sourceID: UUID) throws {
        let sourceDir = ContainerPaths.sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceDir.path) {
            try FileManager.default.removeItem(at: sourceDir)
        }
    }

    /// Escapes HTML special characters for safe insertion into HTML attributes/text.
    func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}
