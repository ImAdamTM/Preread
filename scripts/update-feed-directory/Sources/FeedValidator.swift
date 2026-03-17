import Foundation
import SwiftSoup

/// Validates feed URLs, extracts site URLs, and parses feed items for quality checks.
enum FeedValidator {

    struct ValidationResult {
        let feedURL: String
        let siteURL: String?
        let isValid: Bool
        let newestItemDate: Date?   // Most recent item publish date (nil if no dates found)
        let articleURLs: [String]   // Up to 10 item URLs from the feed
        let issue: Issue?           // Why the feed was invalid (nil if valid)

        enum Issue: CustomStringConvertible {
            case unreachable(String)        // Network error or non-2xx status
            case notAFeed                   // Response doesn't look like XML/RSS/Atom
            case redirectsToHTTP(String)    // Final URL is HTTP (ATS blocks on iOS)

            var description: String {
                switch self {
                case .unreachable(let reason): return "unreachable: \(reason)"
                case .notAFeed: return "response is not a feed"
                case .redirectsToHTTP(let url): return "redirects to HTTP: \(url)"
                }
            }
        }
    }

    /// Validates a feed URL by fetching it and checking for valid XML content.
    /// Also extracts the site URL, newest item date, and article URLs.
    static func validate(feedURL: String, session: URLSession) async -> ValidationResult {
        await validate(feedURL: feedURL, session: session, checkATSRedirects: false)
    }

    /// Validates a feed URL with optional ATS redirect detection.
    /// When `checkATSRedirects` is true, follows the redirect chain manually and rejects
    /// feeds whose final URL is HTTP (since iOS ATS blocks plain HTTP requests).
    static func validate(feedURL: String, session: URLSession,
                         checkATSRedirects: Bool) async -> ValidationResult {
        guard let url = URL(string: feedURL) else {
            return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false,
                                    newestItemDate: nil, articleURLs: [],
                                    issue: .unreachable("invalid URL"))
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false,
                                        newestItemDate: nil, articleURLs: [],
                                        issue: .unreachable("HTTP \(status)"))
            }

            // If ATS checking is on, verify the final URL is HTTPS
            if checkATSRedirects,
               let finalURL = httpResponse.url,
               finalURL.scheme?.lowercased() == "http" {
                return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false,
                                        newestItemDate: nil, articleURLs: [],
                                        issue: .redirectsToHTTP(finalURL.absoluteString))
            }

            // Check that the response looks like XML/RSS/Atom
            let prefix = String(data: data.prefix(1000), encoding: .utf8)?.lowercased() ?? ""
            let looksLikeFeed = prefix.contains("<?xml") ||
                                prefix.contains("<rss") ||
                                prefix.contains("<feed") ||
                                prefix.contains("<opml")

            guard looksLikeFeed else {
                return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false,
                                        newestItemDate: nil, articleURLs: [],
                                        issue: .notAFeed)
            }

            // Extract site URL from feed content
            let siteURL = extractSiteURL(from: data)

            // Extract item dates and URLs from feed content
            let itemInfo = extractFeedItems(from: data)

            return ValidationResult(
                feedURL: feedURL,
                siteURL: siteURL,
                isValid: true,
                newestItemDate: itemInfo.newestDate,
                articleURLs: itemInfo.urls,
                issue: nil
            )
        } catch {
            return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false,
                                    newestItemDate: nil, articleURLs: [],
                                    issue: .unreachable(error.localizedDescription))
        }
    }

    // MARK: - Feed Autodiscovery

    /// Attempts to find a working feed URL for a site using multiple strategies:
    /// 1. HTML `<link rel="alternate">` discovery on the site homepage
    /// 2. Common feed path guessing (/feed, /rss, /rss.xml, etc.)
    /// 3. Feeds subdomain fallback
    ///
    /// Returns the first valid feed URL found, or nil if none work.
    static func discoverFeed(siteURL: String?, feedURL: String,
                             session: URLSession) async -> String? {
        // Determine the base site URL to probe
        let baseURL: URL
        if let site = siteURL, let url = URL(string: site) {
            baseURL = url
        } else if let url = URL(string: feedURL),
                  let scheme = url.scheme, let host = url.host {
            baseURL = URL(string: "\(scheme)://\(host)")!
        } else {
            return nil
        }

        // Strategy 1: HTML <link rel="alternate"> discovery
        if let discovered = await discoverFromHTML(baseURL: baseURL, session: session) {
            let result = await validate(feedURL: discovered, session: session,
                                        checkATSRedirects: true)
            if result.isValid { return discovered }
        }

        // Strategy 2: Common feed paths
        let commonPaths = [
            "/feed", "/rss", "/rss.xml", "/atom.xml", "/feed.xml",
            "/index.xml", "/feeds/all", "/feeds/rss", "/feeds.xml",
            "/news/rss.xml", "/news/feed", "/blog/feed", "/blog/rss.xml",
        ]

        guard let scheme = baseURL.scheme, let host = baseURL.host else { return nil }
        let siteBase = "\(scheme)://\(host)"

        for path in commonPaths {
            let candidate = siteBase + path
            // Skip if it's the same as the original broken feed URL
            if candidate.lowercased() == feedURL.lowercased() { continue }

            let result = await validate(feedURL: candidate, session: session,
                                        checkATSRedirects: true)
            if result.isValid { return candidate }
        }

        // Strategy 3: feeds. subdomain
        let feedsHost = "feeds." + host.replacingOccurrences(of: "www.", with: "")
        let feedsBase = "\(scheme)://\(feedsHost)"
        let subdomainPaths = ["", "/rss.xml", "/news/rss.xml"]

        for path in subdomainPaths {
            let candidate = feedsBase + path
            let result = await validate(feedURL: candidate, session: session,
                                        checkATSRedirects: true)
            if result.isValid { return candidate }
        }

        return nil
    }

    /// Fetches an HTML page and looks for <link rel="alternate" type="application/rss+xml">
    /// or atom+xml tags.
    private static func discoverFromHTML(baseURL: URL, session: URLSession) async -> String? {
        do {
            var request = URLRequest(url: baseURL, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                           forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            guard let html = String(data: data, encoding: .utf8) else { return nil }

            let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
            let links = try doc.select("link[rel=alternate]")

            for link in links {
                let type = try link.attr("type").lowercased()
                guard type.contains("rss") || type.contains("atom") else { continue }

                let href = try link.attr("abs:href")
                guard !href.isEmpty else { continue }

                // Ensure it's HTTPS
                var feedCandidate = href
                if feedCandidate.lowercased().hasPrefix("http://") {
                    feedCandidate = "https://" + feedCandidate.dropFirst("http://".count)
                }

                return feedCandidate
            }
        } catch {
            // HTML fetch/parse failed — fall through to other strategies
        }
        return nil
    }

    /// Extracts the site/homepage URL from feed XML.
    /// Looks for `<link>` in RSS channels or `<link rel="alternate">` in Atom feeds.
    private static func extractSiteURL(from data: Data) -> String? {
        let parser = SiteURLExtractor()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.siteURL
    }

    /// Extracts item dates and URLs from the feed XML.
    private static func extractFeedItems(from data: Data) -> (newestDate: Date?, urls: [String]) {
        let extractor = FeedItemExtractor()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = extractor
        xmlParser.parse()
        return (extractor.newestDate, extractor.articleURLs)
    }
}

// MARK: - Site URL Extractor

private final class SiteURLExtractor: NSObject, XMLParserDelegate {
    var siteURL: String?
    private var currentElement = ""
    private var currentText = ""
    private var isInsideChannel = false
    private var foundSiteURL = false
    private var isAtomFeed = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {

        guard !foundSiteURL else { return }

        let element = elementName.lowercased()
        currentElement = element

        if element == "channel" {
            isInsideChannel = true
        } else if element == "feed" {
            isAtomFeed = true
        }

        // Atom: <link rel="alternate" href="..."/>
        if element == "link" && isAtomFeed {
            let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
            if rel == "alternate", let href = attributeDict["href"], !href.isEmpty {
                siteURL = href.trimmingCharacters(in: .whitespacesAndNewlines)
                foundSiteURL = true
                parser.abortParsing()
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !foundSiteURL else { return }
        if currentElement == "link" && isInsideChannel {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard !foundSiteURL else { return }

        let element = elementName.lowercased()

        // RSS: <channel><link>https://example.com</link></channel>
        if element == "link" && isInsideChannel {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.hasPrefix("http") {
                siteURL = trimmed
                foundSiteURL = true
                parser.abortParsing()
            }
        }

        if element == "channel" {
            isInsideChannel = false
        }

        currentText = ""
        currentElement = ""
    }
}

// MARK: - Feed Item Extractor

/// Parses feed XML to extract item dates and URLs (up to 10 items).
private final class FeedItemExtractor: NSObject, XMLParserDelegate {
    var newestDate: Date?
    var articleURLs: [String] = []

    private let maxItems = 10
    private var itemCount = 0

    // State tracking
    private var isAtomFeed = false
    private var isInsideItem = false       // RSS <item> or Atom <entry>
    private var isInsideChannel = false    // RSS <channel> (skip channel-level link)
    private var currentElement = ""
    private var currentText = ""

    // Per-item state
    private var currentItemURL: String?
    private var currentItemDate: Date?

    // Date formatters (lazily initialized once)
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let rfc822Formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "EEE, dd MMM yyyy HH:mm Z",
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {

        guard itemCount < maxItems else {
            parser.abortParsing()
            return
        }

        let element = elementName.lowercased()
        currentElement = element
        currentText = ""

        switch element {
        case "feed":
            isAtomFeed = true
        case "channel":
            isInsideChannel = true
        case "item", "entry":
            isInsideItem = true
            currentItemURL = nil
            currentItemDate = nil
        case "link":
            if isInsideItem {
                if isAtomFeed {
                    // Atom: <link rel="alternate" href="..."/>
                    let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
                    if rel == "alternate" || attributeDict["rel"] == nil,
                       let href = attributeDict["href"],
                       !href.isEmpty,
                       href.hasPrefix("http") {
                        currentItemURL = href.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()

        switch element {
        case "channel":
            isInsideChannel = false

        case "item", "entry":
            // Finalize current item
            if let url = currentItemURL {
                articleURLs.append(url)
            }
            if let date = currentItemDate {
                if newestDate == nil || date > newestDate! {
                    newestDate = date
                }
            }
            itemCount += 1
            isInsideItem = false

        case "link":
            // RSS: <item><link>https://...</link></item>
            if isInsideItem && !isAtomFeed {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.hasPrefix("http") {
                    currentItemURL = trimmed
                }
            }

        case "guid":
            // RSS fallback: use <guid> as URL if no <link> found
            if isInsideItem && currentItemURL == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("http") {
                    currentItemURL = trimmed
                }
            }

        case "pubdate":
            // RSS: <pubDate>
            if isInsideItem {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = Self.parseDate(trimmed) {
                    currentItemDate = date
                }
            }

        case "published", "updated":
            // Atom: <published> or <updated>
            if isInsideItem && currentItemDate == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = Self.parseDate(trimmed) {
                    currentItemDate = date
                }
            }

        case "date":
            // Dublin Core: <dc:date> (element name after namespace stripping)
            if isInsideItem && currentItemDate == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = Self.parseDate(trimmed) {
                    currentItemDate = date
                }
            }

        default:
            break
        }

        currentText = ""
        currentElement = ""
    }

    /// Tries multiple date formats: ISO 8601, then RFC 822 variants.
    private static func parseDate(_ string: String) -> Date? {
        if let date = iso8601.date(from: string) { return date }
        if let date = iso8601NoFrac.date(from: string) { return date }
        for formatter in rfc822Formatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

