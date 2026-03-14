import Foundation

/// Validates feed URLs and extracts site URLs from feed XML.
enum FeedValidator {

    struct ValidationResult {
        let feedURL: String
        let siteURL: String?
        let isValid: Bool
    }

    /// Validates a feed URL by fetching it and checking for valid XML content.
    /// Also extracts the site URL from the feed's `<link>` element.
    static func validate(feedURL: String, session: URLSession) async -> ValidationResult {
        guard let url = URL(string: feedURL) else {
            return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false)
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false)
            }

            // Check that the response looks like XML/RSS/Atom
            let prefix = String(data: data.prefix(1000), encoding: .utf8)?.lowercased() ?? ""
            let looksLikeFeed = prefix.contains("<?xml") ||
                                prefix.contains("<rss") ||
                                prefix.contains("<feed") ||
                                prefix.contains("<opml")

            guard looksLikeFeed else {
                return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false)
            }

            // Extract site URL from feed content
            let siteURL = extractSiteURL(from: data)

            return ValidationResult(feedURL: feedURL, siteURL: siteURL, isValid: true)
        } catch {
            return ValidationResult(feedURL: feedURL, siteURL: nil, isValid: false)
        }
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
