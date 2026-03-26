import Foundation
import SwiftSoup
import SwiftReadability

/// Checks content quality of a feed by fetching a sample of its articles,
/// running them through the same Readability pipeline as the main app,
/// and measuring extracted word/image counts.
enum ContentQualityChecker {

    struct QualityResult {
        let feedURL: String
        let medianWordCount: Int
        let medianImageCount: Int
        let sampledArticles: Int
        let isAcceptable: Bool
        let reason: String
    }

    /// Fetches up to 5 article pages from the feed and assesses content quality
    /// using Readability-based article extraction (same pipeline as the main app).
    ///
    /// A feed is **thin** if the median extracted article has < 200 words AND < 3 images.
    /// This catches paywalled sites and link-aggregators while preserving
    /// image-heavy feeds (e.g. photography blogs).
    ///
    /// Returns acceptable if fewer than 2 articles could be fetched (benefit of the doubt).
    static func check(
        feedURL: String,
        articleURLs: [String],
        session: URLSession
    ) async -> QualityResult {
        let urls = Array(articleURLs.prefix(5))
        guard !urls.isEmpty else {
            return QualityResult(
                feedURL: feedURL, medianWordCount: 0, medianImageCount: 0,
                sampledArticles: 0, isAcceptable: true,
                reason: "No article URLs to check"
            )
        }

        var wordCounts: [Int] = []
        var imageCounts: [Int] = []
        var paywallScores: [Int] = []

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }

            do {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.assumesHTTP3Capable = false

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else { continue }

                guard let html = String(data: data, encoding: .utf8) ??
                      String(data: data, encoding: .isoLatin1) else { continue }

                let signals = extractSignals(from: html, pageURL: url)
                wordCounts.append(signals.wordCount)
                imageCounts.append(signals.imageCount)
                paywallScores.append(signals.paywallScore)
            } catch {
                // Skip failed fetches
            }
        }

        let sampledCount = wordCounts.count

        // If zero articles could be fetched, the site blocks scraping entirely
        // — the app won't be able to cache articles either.
        guard sampledCount >= 1 else {
            return QualityResult(
                feedURL: feedURL, medianWordCount: 0, medianImageCount: 0,
                sampledArticles: 0, isAcceptable: false,
                reason: "Site blocks article fetches (0 of \(urls.count) succeeded)"
            )
        }

        // With only 1 article sampled, give benefit of the doubt — one
        // failure could be intermittent.
        guard sampledCount >= 2 else {
            return QualityResult(
                feedURL: feedURL, medianWordCount: 0, medianImageCount: 0,
                sampledArticles: sampledCount, isAcceptable: true,
                reason: "Too few articles fetched (\(sampledCount)) to assess"
            )
        }

        let medianWords = median(wordCounts)
        let medianImages = median(imageCounts)
        let medianPaywall = median(paywallScores)

        // A feed is thin if:
        // 1. Very low text (< 100 words) regardless of images — no real article has < 100 words, OR
        // 2. Very low text AND few images (original check), OR
        // 3. Low text AND paywall indicators detected — the images are just page chrome
        let isThin: Bool
        if medianWords < 100 {
            isThin = true  // Floor: < 100 words is never a real article
        } else if medianWords < 200 && medianImages < 3 {
            isThin = true  // Original thin content check
        } else if medianWords < 200 && medianPaywall >= 3 {
            isThin = true  // Low text + paywall signals = paywalled content
        } else {
            isThin = false
        }

        let reason: String
        if medianWords < 100 {
            reason = "Very thin content (median: \(medianWords) words)"
        } else if medianWords < 200 && medianPaywall >= 3 {
            reason = "Paywalled content (median: \(medianWords) words, \(medianPaywall) paywall signals)"
        } else if isThin {
            reason = "Thin content (median: \(medianWords) words, \(medianImages) images)"
        } else if medianWords < 200 {
            reason = "Low text but image-rich (median: \(medianWords) words, \(medianImages) images)"
        } else {
            reason = "OK (median: \(medianWords) words, \(medianImages) images)"
        }

        return QualityResult(
            feedURL: feedURL,
            medianWordCount: medianWords,
            medianImageCount: medianImages,
            sampledArticles: sampledCount,
            isAcceptable: !isThin,
            reason: reason
        )
    }

    // MARK: - Signal extraction (Readability pipeline)

    private struct PageSignals {
        let wordCount: Int
        let imageCount: Int
        let paywallScore: Int
    }

    /// Extracts content signals using the same Readability pipeline as the main app.
    /// Cleans the HTML, runs Readability extraction, then counts words and images
    /// from the extracted article content rather than the full page.
    private static func extractSignals(from html: String, pageURL: URL) -> PageSignals {
        // Count paywall indicators in the raw HTML before any processing
        let paywallTerms = ["paywall", "regwall", "subscribe-wall", "metered-content",
                            "paid-content", "premium-content"]
        var paywallHits = 0
        let htmlLower = html.lowercased()
        for term in paywallTerms {
            paywallHits += countOccurrences(of: term, in: htmlLower)
        }

        // Run through Readability pipeline (same as PageCacheService.runStandardPipeline)
        do {
            // Step 1: Parse and clean — remove noise elements
            let doc = try SwiftSoup.parse(html, pageURL.absoluteString)
            try doc.select("script").remove()
            try doc.select("noscript").remove()
            try doc.select("style").remove()
            try doc.select("meta[http-equiv=Content-Security-Policy]").remove()
            try doc.select("button").remove()
            try doc.select("dialog").remove()
            try doc.select("svg").remove()
            try doc.select("nav").remove()
            try doc.select("aside").remove()
            try doc.select("form").remove()
            try doc.select("input").remove()
            try doc.select("select").remove()
            try doc.select("textarea").remove()
            try doc.select("iframe").remove()

            let cleanedHTML = try doc.html()

            // Step 2: Readability extraction
            let readability = Readability(html: cleanedHTML, url: pageURL)
            guard let extracted = try readability.parse() else {
                // Readability couldn't extract anything — likely JS-rendered or completely paywalled
                return PageSignals(wordCount: 0, imageCount: 0, paywallScore: paywallHits)
            }

            // Step 3: Count words from extracted article text
            let contentDoc = try SwiftSoup.parseBodyFragment(extracted.contentHTML, pageURL.absoluteString)
            let plainText = (try? contentDoc.body()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count

            // Step 4: Count images in extracted content
            let imageCount = (try? contentDoc.select("img"))?.size() ?? 0

            return PageSignals(wordCount: wordCount, imageCount: imageCount, paywallScore: paywallHits)
        } catch {
            // If parsing fails entirely, return zero signals
            return PageSignals(wordCount: 0, imageCount: 0, paywallScore: paywallHits)
        }
    }

    // MARK: - Helpers

    /// Counts case-insensitive occurrences of a substring.
    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        let lower = haystack.lowercased()
        let target = needle.lowercased()
        var count = 0
        var searchRange = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<lower.endIndex
        }
        return count
    }

    /// Returns the median of a sorted integer array.
    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
