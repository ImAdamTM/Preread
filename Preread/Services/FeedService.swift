import Foundation
import SwiftSoup
import GRDB

// MARK: - Types

struct DiscoveredFeed {
    let feedURL: URL
    let title: String
    let siteURL: URL?
    let items: [FeedItem]
}

struct FeedItem {
    let title: String
    let url: URL
    let publishedAt: Date?
    let thumbnailURL: URL?
    let sourceName: String?
}

enum FeedError: Error, LocalizedError {
    case noFeedFound
    case invalidFeed
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noFeedFound: "No feed found at that address."
        case .invalidFeed: "The feed could not be read."
        case .networkError(let error): "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - FeedService

actor FeedService {
    static let shared = FeedService()

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private var session: URLSession = FeedService.makeSession()

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Discovery

    /// Discovers a feed from a website URL by checking HTML link tags, then fallback paths.
    func discoverFeed(from url: URL) async throws -> DiscoveredFeed {
        // Fetch the page, following redirects
        let (data, response) = try await fetchData(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FeedError.noFeedFound
        }

        let resolvedURL = httpResponse.url ?? url

        // If the URL itself is a valid feed, use it directly
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let xmlTypes = ["xml", "rss", "atom"]
        if xmlTypes.contains(where: { contentType.contains($0) }) {
            let parser = FeedXMLParser(feedURL: resolvedURL, siteURL: nil)
            if parser.parse(data: data), !parser.items.isEmpty {
                return DiscoveredFeed(
                    feedURL: resolvedURL,
                    title: parser.feedTitle ?? resolvedURL.host ?? "Untitled",
                    siteURL: parser.siteURL,
                    items: parser.items
                )
            }
        }

        let html = String(data: data, encoding: .utf8) ?? ""

        // Try <link rel="alternate"> discovery
        if let feedURL = try discoverFeedLink(in: html, baseURL: resolvedURL) {
            return try await parseFeed(from: feedURL, siteURL: resolvedURL)
        }

        // Fallback: try common feed paths
        let fallbackPaths = [
            "/feed", "/rss", "/rss.xml", "/atom.xml", "/feed.xml", "/index.xml",
            "/news/rss.xml", "/news/feed", "/blog/feed", "/blog/rss.xml",
        ]
        for path in fallbackPaths {
            guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true) else { continue }
            components.path = path
            components.query = nil
            components.fragment = nil
            guard let candidateURL = components.url else { continue }

            if let feed = try? await tryParseFeed(from: candidateURL, siteURL: resolvedURL) {
                return feed
            }
        }

        // Try feeds subdomain (common for large sites)
        if let host = resolvedURL.host {
            let feedsHost = "feeds.\(host.replacingOccurrences(of: "www.", with: ""))"
            let feedsSubdomainPaths = ["/rss.xml", "/news/rss.xml"]
            for path in feedsSubdomainPaths {
                guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true) else { continue }
                components.host = feedsHost
                components.path = path
                components.query = nil
                components.fragment = nil
                guard let candidateURL = components.url else { continue }

                if let feed = try? await tryParseFeed(from: candidateURL, siteURL: resolvedURL) {
                    return feed
                }
            }
        }

        // Last resort: try Google News RSS for this domain
        if let host = resolvedURL.host {
            let domain = host.replacingOccurrences(of: "www.", with: "")
            let googleQuery = "site:\(domain)"
            var components = URLComponents(string: "https://news.google.com/rss/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: googleQuery),
                URLQueryItem(name: "hl", value: "en-US"),
                URLQueryItem(name: "gl", value: "US"),
                URLQueryItem(name: "ceid", value: "US:en"),
            ]
            if let googleFeedURL = components.url,
               let feed = try? await tryParseFeed(from: googleFeedURL, siteURL: resolvedURL) {
                return feed
            }
        }

        throw FeedError.noFeedFound
    }

    // MARK: - Topic search

    /// Searches Google News RSS for a topic/keyword (not a URL).
    func searchGoogleNews(query: String) async throws -> DiscoveredFeed {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en"),
        ]

        guard let googleFeedURL = components.url else {
            throw FeedError.noFeedFound
        }

        let (data, response) = try await fetchData(from: googleFeedURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FeedError.noFeedFound
        }

        let parser = FeedXMLParser(feedURL: googleFeedURL, siteURL: nil)
        guard parser.parse(data: data), !parser.items.isEmpty else {
            throw FeedError.noFeedFound
        }

        return DiscoveredFeed(
            feedURL: googleFeedURL,
            title: parser.feedTitle ?? query,
            siteURL: nil,
            items: parser.items
        )
    }

    // MARK: - Parsing

    /// Parses an RSS 2.0 or Atom feed from a URL.
    func parseFeed(from feedURL: URL, siteURL: URL? = nil) async throws -> DiscoveredFeed {
        let (data, response) = try await fetchData(from: feedURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FeedError.invalidFeed
        }

        let parser = FeedXMLParser(feedURL: feedURL, siteURL: siteURL)
        guard parser.parse(data: data) else {
            throw FeedError.invalidFeed
        }

        return DiscoveredFeed(
            feedURL: feedURL,
            title: parser.feedTitle ?? feedURL.host ?? "Untitled",
            siteURL: parser.siteURL ?? siteURL,
            items: parser.items
        )
    }

    // MARK: - Duplicate check

    /// Returns true if a Source with the given feedURL already exists.
    func checkForDuplicate(feedURL: String) throws -> Bool {
        try DatabaseManager.shared.dbPool.read { db in
            try Source.filter(Column("feedURL") == feedURL).fetchCount(db) > 0
        }
    }

    // MARK: - Private helpers

    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.assumesHTTP3Capable = false

        var lastError: Error?
        for attempt in 0...2 {
            do {
                return try await session.data(for: request)
            } catch {
                let nsError = error as NSError
                let isQUICError = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == -1017 || nsError.code == -1005)
                if isQUICError && attempt < 2 {
                    lastError = error
                    // Kill the poisoned session and create a fresh one
                    session.invalidateAndCancel()
                    session = Self.makeSession()
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    continue
                }
                throw FeedError.networkError(error)
            }
        }
        throw FeedError.networkError(lastError ?? URLError(.unknown))
    }

    /// Looks for <link rel="alternate" type="application/rss+xml"> or atom+xml in HTML.
    private func discoverFeedLink(in html: String, baseURL: URL) throws -> URL? {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        let links = try doc.select("link[rel=alternate]")

        for link in links {
            let type = try link.attr("type").lowercased()
            guard type.contains("rss") || type.contains("atom") else { continue }

            let href = try link.attr("abs:href")
            guard !href.isEmpty, let feedURL = URL(string: href) else { continue }
            return feedURL
        }

        return nil
    }

    /// Attempts to parse a feed URL, returning nil on failure instead of throwing.
    private func tryParseFeed(from url: URL, siteURL: URL?) async throws -> DiscoveredFeed? {
        let (data, response) = try await fetchData(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        // Quick content-type check
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let xmlTypes = ["xml", "rss", "atom"]
        guard xmlTypes.contains(where: { contentType.contains($0) }) else {
            return nil
        }

        let parser = FeedXMLParser(feedURL: url, siteURL: siteURL)
        guard parser.parse(data: data), !parser.items.isEmpty else {
            return nil
        }

        return DiscoveredFeed(
            feedURL: url,
            title: parser.feedTitle ?? url.host ?? "Untitled",
            siteURL: parser.siteURL ?? siteURL,
            items: parser.items
        )
    }
}

// MARK: - XML Parser

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    let feedURL: URL
    private(set) var feedTitle: String?
    private(set) var siteURL: URL?
    private(set) var items: [FeedItem] = []

    private var currentElement = ""
    private var currentText = ""
    private var isInsideItem = false

    // Per-item state
    private var itemTitle = ""
    private var itemURL = ""
    private var itemDateString = ""
    private var itemThumbnailURL = ""
    private var itemContentHTML = ""
    private var itemSourceName = ""

    // Feed type detection
    private var isAtom = false
    private var isInFeedHeader = true

    init(feedURL: URL, siteURL: URL?) {
        self.feedURL = feedURL
        self.siteURL = siteURL
        super.init()
    }

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        return parser.parse() && (feedTitle != nil || !items.isEmpty)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""

        switch currentElement {
        case "feed":
            isAtom = true

        case "item":
            // RSS item
            isInsideItem = true
            isInFeedHeader = false
            resetItemState()

        case "entry":
            // Atom entry
            isInsideItem = true
            isInFeedHeader = false
            resetItemState()

        case "link":
            if isAtom {
                let rel = attributes["rel"] ?? "alternate"
                let href = attributes["href"] ?? ""

                if isInsideItem && rel == "alternate" {
                    itemURL = href
                } else if isInFeedHeader && rel == "alternate" && siteURL == nil {
                    siteURL = resolveURL(href)
                }
            }

        case "media:thumbnail", "media:content":
            if isInsideItem {
                if let url = attributes["url"], !url.isEmpty {
                    itemThumbnailURL = url
                }
            }

        case "enclosure":
            if isInsideItem, itemThumbnailURL.isEmpty {
                let type = attributes["type"] ?? ""
                if type.hasPrefix("image/"), let url = attributes["url"] {
                    itemThumbnailURL = url
                }
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isInsideItem && isInFeedHeader {
            switch element {
            case "title":
                if feedTitle == nil { feedTitle = decodeHTMLEntities(text) }
            case "link":
                if !isAtom && siteURL == nil && !text.isEmpty {
                    siteURL = resolveURL(text)
                }
            default:
                break
            }
        }

        if isInsideItem {
            switch element {
            case "title":
                itemTitle = text
            case "link":
                if !isAtom { itemURL = text }
            case "guid":
                if itemURL.isEmpty { itemURL = text }
            case "pubdate", "published", "updated", "dc:date":
                if itemDateString.isEmpty { itemDateString = text }
            case "content", "content:encoded", "description":
                if itemContentHTML.isEmpty { itemContentHTML = text }
            case "source":
                if itemSourceName.isEmpty { itemSourceName = text }
            default:
                break
            }
        }

        // End of item/entry
        if element == "item" || element == "entry" {
            isInsideItem = false
            finishItem()
        }

        currentText = ""
    }

    // MARK: - Helpers

    private func resetItemState() {
        itemTitle = ""
        itemURL = ""
        itemDateString = ""
        itemThumbnailURL = ""
        itemContentHTML = ""
        itemSourceName = ""
    }

    private func finishItem() {
        guard let url = resolveURL(itemURL) else {
            print("[FeedService] Skipping item with no valid URL: \(itemTitle)")
            return
        }

        let date = parseDate(itemDateString)
        var thumbnail = resolveURL(itemThumbnailURL)

        // Fallback: extract first <img> from HTML content if no dedicated thumbnail
        if thumbnail == nil, !itemContentHTML.isEmpty {
            thumbnail = extractFirstImageURL(from: itemContentHTML)
        }

        let cleanTitle = itemTitle.isEmpty ? url.absoluteString : decodeHTMLEntities(itemTitle)

        items.append(FeedItem(
            title: cleanTitle,
            url: url,
            publishedAt: date,
            thumbnailURL: thumbnail,
            sourceName: itemSourceName.isEmpty ? nil : decodeHTMLEntities(itemSourceName)
        ))
    }

    /// Extracts the first image URL from HTML content using a lightweight regex.
    private func extractFirstImageURL(from html: String) -> URL? {
        // Match <img ... src="..." ...> — handles both single and double quotes
        let pattern = #"<img\s[^>]*?src\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let urlRange = Range(match.range(at: 1), in: html) else { return nil }
        let urlString = String(html[urlRange])
        guard !urlString.hasPrefix("data:") else { return nil }
        return resolveURL(urlString)
    }

    private func resolveURL(_ string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        if let absolute = URL(string: string), absolute.scheme != nil {
            return absolute
        }
        return URL(string: string, relativeTo: feedURL)?.absoluteURL
    }

    private func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }

        // ISO 8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        // RFC 822 (common in RSS)
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        let rfc822Formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
        ]
        for format in rfc822Formats {
            rfc822.dateFormat = format
            if let date = rfc822.date(from: string) { return date }
        }

        return nil
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        // Fast path: no entities to decode
        guard string.contains("&") else { return string }

        guard let data = string.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return string
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
