import Foundation

/// Parses OPML files from the awesome-rss-feeds repo.
/// Expects nested outlines: parent outline has the category, children have feed details.
final class OPMLParser: NSObject, XMLParserDelegate {

    struct RawFeed {
        let name: String
        let feedURL: String
        let description: String
        let category: String
        let country: String?
        var siteURL: String?
    }

    private(set) var feeds: [RawFeed] = []

    /// Category name for "recommended" OPMLs (extracted from parent outline).
    /// For country OPMLs, the category is the country name passed externally.
    private var currentCategory: String = ""
    private var isCountryMode: Bool = false
    private var countryName: String?

    /// Depth tracking: 0 = body, 1 = category outline, 2 = feed outline
    private var outlineDepth = 0

    func parse(data: Data, category: String? = nil, country: String? = nil) -> [RawFeed] {
        feeds = []
        currentCategory = category ?? ""
        countryName = country
        isCountryMode = country != nil
        outlineDepth = 0

        // Fix unescaped ampersands in OPML attributes (common in these files)
        let cleanedData = Self.fixUnescapedAmpersands(in: data)

        let parser = XMLParser(data: cleanedData)
        parser.delegate = self
        parser.parse()
        return feeds
    }

    /// Replaces bare `&` (not part of `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`) with `&amp;`.
    private static func fixUnescapedAmpersands(in data: Data) -> Data {
        guard let string = String(data: data, encoding: .utf8) else { return data }
        // Match & not followed by amp; lt; gt; quot; apos; or #
        // Use a simple iterative approach
        var result = ""
        var i = string.startIndex
        while i < string.endIndex {
            if string[i] == "&" {
                let remaining = string[i...]
                if remaining.hasPrefix("&amp;") || remaining.hasPrefix("&lt;") ||
                   remaining.hasPrefix("&gt;") || remaining.hasPrefix("&quot;") ||
                   remaining.hasPrefix("&apos;") || remaining.hasPrefix("&#") {
                    result.append("&")
                } else {
                    result.append("&amp;")
                }
            } else {
                result.append(string[i])
            }
            i = string.index(after: i)
        }
        return Data(result.utf8)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {

        guard elementName.lowercased() == "outline" else { return }

        outlineDepth += 1

        // Check if this outline has an xmlUrl — if so, it's a feed entry
        if let xmlUrl = attributeDict["xmlUrl"], !xmlUrl.isEmpty {
            let name = attributeDict["text"] ?? attributeDict["title"] ?? "Untitled"
            let description = attributeDict["description"] ?? ""

            let category: String
            if isCountryMode, let country = countryName {
                category = country  // Country feeds use country name as category
            } else {
                category = currentCategory
            }

            feeds.append(RawFeed(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                feedURL: xmlUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category,
                country: countryName
            ))
        } else {
            // No xmlUrl — this is a category/grouping outline
            if let text = attributeDict["text"] ?? attributeDict["title"], !isCountryMode {
                currentCategory = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "outline" {
            outlineDepth = max(0, outlineDepth - 1)
        }
    }
}
