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
        ContainerPaths.sharedAssetsURL
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

    private var articlesBaseURL: URL {
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
        try preDoc.select("script").remove()
        try preDoc.select("noscript").remove()
        try preDoc.select("style").remove()
        try preDoc.select("meta[http-equiv=Content-Security-Policy]").remove()

        try preDoc.select("img.hide-when-no-script").remove()
        try preDoc.select("img[src*=placeholder]").remove()

        try stripTinyImages(in: preDoc, maxDimension: 30)
        try stripBadgeClusters(in: preDoc)
        try stripImageLayoutStyles(in: preDoc)

        // Strip comment sections — these contain user-generated comments
        // that can outweigh article text and confuse Readability's scoring.
        // Uses standard ID/class conventions (WordPress, Disqus, etc.).
        try preDoc.select("#comments, .comments, #disqus_thread").remove()

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

        try stripLinkedThumbnailCards(in: preDoc, pageURL: pageURL)

        try preDoc.select("figure").unwrap()
        try flattenImageOnlyDivs(in: preDoc)
        flattenSingleChildDivs(in: preDoc)

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
            let srcLower = src.lowercased()
            let imgId = (try? img.attr("id"))?.lowercased() ?? ""
            let alt = (try? img.attr("alt"))?.lowercased() ?? ""
            // Skip site chrome: SVGs, logos, flags, icons, social widgets
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
                if !contentHTML.contains(src) {
                    let heroTag = (try? pageFirst.outerHtml()) ?? ""
                    if !heroTag.isEmpty {
                        contentHTML = heroTag + contentHTML
                    }
                }
            }
        }

        // Post-processing
        let contentDoc = try SwiftSoup.parseBodyFragment(contentHTML, pageURL.absoluteString)
        guard contentDoc.body() != nil else {
            throw NSError(domain: "PageCacheService", code: 1, userInfo: nil)
        }

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

        // Deduplicate sibling images that share the same base URL
        // but differ only in dimension suffixes (e.g. image-640x426.jpg
        // vs image-1024x648.jpg). Keeps the largest variant.
        try deduplicateSiblingImages(in: contentDoc)

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

        // Strip CSP meta tags
        try doc.select("meta[http-equiv=Content-Security-Policy]").remove()

        // Strip scripts and noscript fallbacks — we disable JS in the web
        // view, so noscript blocks render and create huge layout gaps
        // (e.g. BBC's full site-navigation tree inside <noscript>).
        try doc.select("script").remove()
        try doc.select("noscript").remove()

        // Strip navigation — site nav links are non-functional offline
        // and take up significant space above article content.
        try doc.select("nav").remove()

        // Strip comment sections — user-generated comments are non-functional
        // offline and add unnecessary weight.
        try doc.select("#comments, .comments, #disqus_thread").remove()

        // Strip interactive elements that rely on JS
        try doc.select("button").remove()
        try doc.select("dialog").remove()
        try doc.select("svg").remove()
        try doc.select("form").remove()
        try doc.select("input").remove()
        try doc.select("select").remove()
        try doc.select("textarea").remove()

        // Strip elements explicitly marked as hidden — these are popovers,
        // tooltips, and overlays that take up layout space without JS.
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
                let srcLower = src.lowercased()
                let imgId = (try? img.attr("id"))?.lowercased() ?? ""
                let alt = (try? img.attr("alt"))?.lowercased() ?? ""
                if srcLower.contains(".svg") { return false }
                let chromeWords = [
                    "logo", "flag", "icon", "badge", "avatar", "spinner",
                    "facebook", "twitter", "instagram", "pinterest", "tiktok",
                    "furniture", "share", "follow"
                ]
                for word in chromeWords {
                    if imgId.contains(word) || alt.contains(word) || srcLower.contains(word) { return false }
                }
                // Skip images inside <a> links to different pages (navigation/promo thumbnails)
                var walk: Element? = img.parent()
                for _ in 0..<5 {
                    guard let el = walk else { break }
                    if el.tagName() == "a",
                       let href = try? el.attr("href"), !href.isEmpty,
                       let linkURL = URL(string: href, relativeTo: pageURL) {
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
        guard httpResponse.statusCode == 200,
              contentType.contains("text/html"),
              data.count > 1000 else {
            print("[PageCacheService] Validation failed for \(article.articleURL): status=\(httpResponse.statusCode), contentType=\(contentType), dataSize=\(data.count)")
            article.lastHTTPStatus = httpResponse.statusCode
            if wasPreviouslyCached, hasCachedContentOnDisk(for: article) {
                article.fetchStatus = .cached
            } else {
                article.fetchStatus = .failed
                article.retryCount += 1
            }
            try updateArticle(&article)
            return .failed
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
                article.retryCount += 1
            }
            try updateArticle(&article)
            return .failed
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

        if cacheLevel == .full {
            // FULL: Save the complete page with all assets
            let fullResult = try runFullPipeline(html: html, pageURL: pageURL)
            pipelineHeroImageURL = fullResult.heroImageURL
            readingMinutes = ReadingTimeFormatter.estimateMinutes(wordCount: fullResult.wordCount)
            let doc = try SwiftSoup.parse(fullResult.cleanedHTML, pageURL.absoluteString)

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

            let pipelineResult = try runStandardPipeline(html: html, pageURL: pageURL)
            pipelineHeroImageURL = pipelineResult.heroImageURL
            readingMinutes = ReadingTimeFormatter.estimateMinutes(wordCount: pipelineResult.wordCount)
            let articleTitle = pipelineResult.title
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

            let allFilenames = downloadResults.compactMap { result -> String? in
                if case .success(let mapping) = result { return mapping.filename }
                return nil
            }
            assetFilenames = allFilenames

            let assetSize = downloadResults.reduce(0) { sum, result in
                if case .success(let mapping) = result { return sum + mapping.size }
                return sum
            }
            isTruncated = downloadResults.contains { result in
                if case .success(let mapping) = result { return mapping.wasTruncated }
                return false
            }

            // Build templated HTML and calculate total size
            let templatedHTML = readerTemplate
                .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(articleTitle))
                .replacingOccurrences(of: "{{BODY_HTML}}", with: contentHTML)
            htmlData = Data(templatedHTML.utf8)
            totalSize = htmlData.count + assetSize
        }

        // Backfill or upgrade thumbnail from hero image.
        // - Backfill: RSS feed didn't provide a thumbnail at all
        // - Upgrade: RSS thumbnail was low-resolution (< 400px wide on disk)
        if let heroSrc = pipelineHeroImageURL,
           let heroURL = URL(string: heroSrc, relativeTo: pageURL) {
            let shouldUseHero: Bool
            if article.thumbnailURL == nil {
                shouldUseHero = true
            } else {
                // Check if the cached thumbnail is low-resolution
                let thumbPath = articleDir.appendingPathComponent("thumbnail.jpg")
                shouldUseHero = isThumbnailLowRes(at: thumbPath, threshold: 400)
            }
            if shouldUseHero {
                let resolved = heroURL.absoluteString
                article.thumbnailURL = resolved
                await cacheThumbnail(url: heroURL, to: articleDir)
                // Invalidate in-memory caches so carousels pick up the new image
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
    private func parseSrcsetEntries(_ srcset: String) -> [String] {
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
        if data.count > maxSingleAssetBytes {
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

    /// Downloads the article thumbnail and saves two downsampled versions:
    /// - `thumbnail.jpg` — 600px, for hero backdrops, cards, and larger displays
    /// - `thumb.jpg` — 240px, for 80pt list row thumbnails
    /// The original full-size image is not kept on disk.
    private func cacheThumbnail(url: URL, to articleDir: URL) async {
        do {
            var request = URLRequest(url: url)
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
    private func isThumbnailLowRes(at url: URL, threshold: Int) -> Bool {
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

    // MARK: - Tiny image cleanup

    /// Strips `<img>` elements whose explicit width or height attribute is at or below the given threshold.
    /// These are almost always badges, tracking pixels, or tiny decorative icons — not article content.
    private func stripTinyImages(in doc: Document, maxDimension: Int) throws {
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

    // MARK: - Linked thumbnail card cleanup

    /// Removes "related article" cards — containers that hold a small linked thumbnail alongside
    /// a headline linking to a different page. These are sidebar/related-story widgets that
    /// Readability sometimes absorbs into the article body.
    ///
    /// A card is identified generically: a container element (`div`, `li`, `article`) that
    /// contains both (a) a small image (explicit width ≤ 240 or explicit height ≤ 160) and
    /// (b) an anchor linking to a different path on the same site or an external site.
    /// Only removes when the image is itself wrapped in an anchor to a different page.
    private func stripLinkedThumbnailCards(in doc: Document, pageURL: URL) throws {
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
    private func stripBadgeClusters(in doc: Document) throws {
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

    // MARK: - Empty element cleanup

    /// Removes elements that contain only whitespace after our cleaning passes
    /// have stripped their functional content (icons, buttons, etc.).
    /// Runs multiple passes since removing a child can leave its parent empty.
    /// Preserves void elements (img, br, hr, input) and table structure.
    private func stripEmptyElements(in doc: Document) throws {
        let preservedTags: Set<String> = [
            "img", "br", "hr", "input", "source", "meta", "link",
            "video", "audio", "canvas", "iframe", "embed", "object",
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
    private func stripStickyPositioning(in doc: Document) throws {
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
    private func stripImageLayoutStyles(in doc: Document) throws {
        let images = try doc.select("img")
        for img in images {
            try img.removeAttr("style")
            try img.removeAttr("class")
            try img.removeAttr("data-nimg")
            try img.removeAttr("data-chromatic")
        }
    }

    // MARK: - Sibling image deduplication

    /// A regex that matches dimension suffixes like `-640x426`, `-1024x648`, `-980x652`
    /// commonly used in responsive image URLs.
    private static let dimensionSuffixPattern = try! NSRegularExpression(
        pattern: #"-\d+x\d+"#
    )

    /// Strips the dimension suffix from an image URL to produce a base key for comparison.
    /// e.g. "https://cdn.example.com/image-640x426.jpg" → "https://cdn.example.com/image.jpg"
    private func imageDedupKey(for src: String) -> String {
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        return Self.dimensionSuffixPattern.stringByReplacingMatches(
            in: src, range: range, withTemplate: ""
        )
    }

    /// Removes duplicate sibling `<img>` elements that share the same base URL
    /// (differing only in dimension suffixes like `-640x426` vs `-1024x648`).
    /// Keeps the variant with the largest width. This handles responsive image
    /// patterns where sites place multiple resolution variants as sibling elements.
    private func deduplicateSiblingImages(in doc: Document) throws {
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
            // Only group if the dedup key differs from the src (i.e. there was a dimension suffix)
            guard key != src else { continue }
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

    // MARK: - Image-only div flattening

    /// Unwraps `<div>` elements that contain only images and/or other divs (no text).
    /// This promotes images trapped in deep wrapper hierarchies up to the nearest
    /// text-containing ancestor so Readability can score them as article content.
    private func flattenImageOnlyDivs(in doc: Document) throws {
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
                // Only unwrap if the single child is a <div> or <img>
                let childTag = elementChildren[0].tagName()
                guard childTag == "div" || childTag == "img" else { continue }
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

    /// SHA256 hash of URL string + file extension.
    /// When the URL has no extension, falls back to the MIME content type if provided,
    /// otherwise defaults to "bin".
    private func hashedFilename(for url: URL, contentType: String? = nil) -> String {
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

    // MARK: - Favicon caching

    private var sourcesBaseURL: URL {
        ContainerPaths.sourcesBaseURL
    }

    /// Discovers the best favicon URL from an HTML document.
    /// Prefers apple-touch-icon (high-res PNG), then icon links sorted by
    /// size descending, then falls back to /favicon.ico at the domain root.
    private func discoverFaviconURL(in html: String, baseURL: URL) -> URL? {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return nil }
        return discoverFaviconURL(in: doc, baseURL: baseURL)
    }

    /// Discovers the best favicon URL from a parsed SwiftSoup Document.
    private func discoverFaviconURL(in doc: Document, baseURL: URL) -> URL? {
        // 1. apple-touch-icon — always a high-res PNG (typically 180×180)
        if let appleTouchIcon = try? doc.select("link[rel=apple-touch-icon], link[rel=apple-touch-icon-precomposed]").first(),
           let href = try? appleTouchIcon.attr("abs:href"),
           !href.isEmpty,
           let url = URL(string: href) {
            return url
        }

        // 2. <link rel="icon"> — pick the largest available
        if let icons = try? doc.select("link[rel~=icon]") {
            var best: (url: URL, size: Int)?
            for icon in icons {
                guard let href = try? icon.attr("abs:href"),
                      !href.isEmpty,
                      let url = URL(string: href) else { continue }
                // Parse sizes attribute (e.g. "96x96", "32x32")
                let sizes = (try? icon.attr("sizes")) ?? ""
                let size = sizes.split(separator: "x").first.flatMap { Int($0) } ?? 0
                if best == nil || size > best!.size {
                    best = (url, size)
                }
            }
            if let best { return best.url }
        }

        // 3. Fallback to /favicon.ico
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.path = "/favicon.ico"
        return components.url
    }

    /// Discovers and caches a favicon for a source by fetching the site's HTML
    /// and extracting the best icon link. Falls back to /favicon.ico.
    /// Handles feed subdomains (e.g. feeds.foxnews.com → foxnews.com).
    func discoverAndCacheFavicon(for sourceID: UUID, siteURL: URL) async {
        guard let image = await fetchFaviconImage(siteURL: siteURL) else { return }
        await saveFavicon(image, for: sourceID)
    }

    /// Downloads a favicon from a URL and saves it as favicon.png in the given directory.
    private func downloadFavicon(from url: URL, to directory: URL) async {
        do {
            var request = URLRequest(url: url)
            request.assumesHTTP3Capable = false
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty else { return }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let faviconPath = directory.appendingPathComponent("favicon.png")
            try data.write(to: faviconPath)
        } catch {
            // Non-critical — favicon will fall back to letter avatar
        }
    }

    /// Downloads and caches the favicon for a source from a direct URL.
    /// Used as a fallback when siteURL is unavailable.
    func cacheFavicon(for sourceID: UUID, from iconURL: String) async {
        guard let url = URL(string: iconURL) else { return }
        await downloadFavicon(from: url, to: sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true))
    }

    /// Downloads and caches a favicon into an article's directory from a direct URL.
    func cacheArticleFavicon(for articleID: UUID, from iconURL: String) async {
        guard let url = URL(string: iconURL) else { return }
        await downloadFavicon(from: url, to: articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true))
    }

    /// Discovers and caches a per-article favicon from already-parsed HTML.
    /// Extracts the best icon link from the document without an extra network request.
    func cacheArticleFavicon(for articleID: UUID, fromDoc doc: Document, baseURL: URL) async {
        guard let faviconURL = discoverFaviconURL(in: doc, baseURL: baseURL) else { return }
        await downloadFavicon(from: faviconURL, to: articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true))
    }

    /// Returns the locally cached favicon image for a source, if it exists.
    func cachedFavicon(for sourceID: UUID) -> UIImage? {
        let path = sourcesBaseURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("favicon.png")
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    /// Generates and saves a gradient bookmark favicon for the Saved Pages source.
    /// No-op if the favicon already exists on disk.
    func generateSavedPagesFavicon() {
        let sourceDir = sourcesBaseURL
            .appendingPathComponent(Source.savedPagesID.uuidString, isDirectory: true)
        let faviconPath = sourceDir.appendingPathComponent("favicon.png")
        guard !FileManager.default.fileExists(atPath: faviconPath.path) else { return }

        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Gradient background matching Theme.accentGradient
            let colors = [
                UIColor(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0xF0/255.0, alpha: 1).cgColor,
                UIColor(red: 0xA8/255.0, green: 0x55/255.0, blue: 0xF7/255.0, alpha: 1).cgColor
            ]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 1]
            ) else { return }
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )

            // Draw bookmark.fill SF Symbol centered
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 56, weight: .medium)
            if let symbol = UIImage(systemName: "bookmark.fill", withConfiguration: symbolConfig) {
                let symbolSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2
                )
                symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(at: origin)
            }
        }

        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        if let pngData = image.pngData() {
            try? pngData.write(to: faviconPath)
        }
    }

    /// Fetches a favicon from a site URL and returns it as a UIImage without
    /// saving to disk. Used for previewing favicons before a source is added.
    func fetchFaviconImage(siteURL: URL) async -> UIImage? {
        // Try the provided URL first, then fall back to the root domain
        // if the host is a feed subdomain (e.g. feeds.foxnews.com → foxnews.com)
        var urlsToTry = [siteURL]
        if let host = siteURL.host?.lowercased() {
            let feedPrefixes = ["feeds.", "feed.", "rss.", "xml."]
            for prefix in feedPrefixes {
                if host.hasPrefix(prefix) {
                    let rootHost = String(host.dropFirst(prefix.count))
                    var components = URLComponents()
                    components.scheme = siteURL.scheme ?? "https"
                    components.host = rootHost
                    if let rootURL = components.url {
                        urlsToTry.append(rootURL)
                    }
                    break
                }
            }
        }

        for url in urlsToTry {
            if let image = await fetchFaviconFromPage(url) {
                return image
            }
        }
        return nil
    }

    /// Attempts to fetch a favicon from a single page URL.
    private func fetchFaviconFromPage(_ pageURL: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: pageURL)
            request.assumesHTTP3Capable = false
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            let html = String(data: data, encoding: .utf8) ?? ""

            guard let faviconURL = discoverFaviconURL(in: html, baseURL: pageURL) else { return nil }

            var iconRequest = URLRequest(url: faviconURL)
            iconRequest.assumesHTTP3Capable = false
            let (iconData, iconResponse) = try await session.data(for: iconRequest)
            guard let iconHTTP = iconResponse as? HTTPURLResponse,
                  iconHTTP.statusCode == 200,
                  !iconData.isEmpty else { return nil }
            return UIImage(data: iconData)
        } catch {
            return nil
        }
    }

    /// Saves a UIImage as the favicon for a source.
    /// Used when the favicon was already fetched for preview purposes.
    func saveFavicon(_ image: UIImage, for sourceID: UUID) async {
        guard let data = image.pngData() else { return }
        let directory = sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let faviconPath = directory.appendingPathComponent("favicon.png")
            try data.write(to: faviconPath)
        } catch {
            // Non-critical
        }
    }

    /// Deletes all cached data for a source (favicon, etc).
    func deleteSourceCache(_ sourceID: UUID) throws {
        let sourceDir = sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceDir.path) {
            try FileManager.default.removeItem(at: sourceDir)
        }
    }

    /// Escapes HTML special characters for safe insertion into HTML attributes/text.
    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}

