import Foundation
import SwiftSoup

// MARK: - SPA / framework support (Next.js, Apollo)

extension PageCacheService {

    // MARK: - Next.js __NEXT_DATA__ extraction

    /// Extracts article HTML from a Next.js `__NEXT_DATA__` script element,
    /// but only if the body doesn't already contain the article text (i.e.
    /// the site relies on client-side rendering rather than SSR).
    ///
    /// Many Next.js sites embed their article content as JSON inside this script.
    /// Sites with proper SSR also have the content in the visible DOM, so we
    /// skip injection to avoid confusing Readability with duplicate content.
    func extractNextDataContent(from doc: Document) -> String? {
        guard let scriptEl = try? doc.select("script#__NEXT_DATA__").first(),
              let jsonText = try? scriptEl.data(),
              let jsonData = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) else {
            return nil
        }

        // Recursively find the longest string value containing HTML paragraph tags.
        var bestHTML: String?
        var bestLength = 200 // Minimum threshold — skip short fragments

        func walk(_ value: Any) {
            switch value {
            case let str as String:
                if str.count > bestLength && str.contains("<p>") {
                    bestHTML = str
                    bestLength = str.count
                }
            case let dict as [String: Any]:
                for v in dict.values { walk(v) }
            case let arr as [Any]:
                for v in arr { walk(v) }
            default:
                break
            }
        }

        walk(json)

        // Only inject if the body doesn't already contain the article text.
        // Extract a distinctive snippet from the middle of the content and
        // check if it appears in the body text (excluding scripts).
        guard let articleHTML = bestHTML else { return nil }

        // Get plain text from the extracted HTML
        if let articleDoc = try? SwiftSoup.parseBodyFragment(articleHTML),
           let articleText = try? articleDoc.body()?.text(),
           articleText.count > 200 {
            // Use a snippet from the middle to avoid matching meta descriptions
            let midStart = articleText.index(articleText.startIndex, offsetBy: 100)
            let midEnd = articleText.index(midStart, offsetBy: min(60, articleText.distance(from: midStart, to: articleText.endIndex)))
            let snippet = String(articleText[midStart..<midEnd])

            // Check against the body text (scripts still present at this point,
            // but the snippet is from mid-article so it won't match JSON keys)
            if let bodyText = try? doc.body()?.text(), bodyText.contains(snippet) {
                return nil // Content already server-rendered — skip injection
            }
        }

        return bestHTML
    }

    /// Extracts a balanced JSON object starting at the given index.
    /// Uses brace counting with proper string-literal handling to find
    /// the matching closing `}`.
    private func extractBalancedJSON(from text: String, startingAt startIndex: String.Index) -> Substring? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = startIndex

        while index < text.endIndex {
            let char = text[index]

            if escaped {
                escaped = false
            } else if char == "\\" && inString {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return text[startIndex...index]
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    /// Hydrates empty image placeholders with URLs extracted from an Apollo
    /// Client serialized cache (`window.__APOLLO_STATE__`).
    ///
    /// Apollo-based pages server-render placeholder elements with CSS
    /// aspect-ratio hacks (`padding-top: XX%`) but store the actual image URLs
    /// in the Apollo cache JSON embedded in a `<script>` tag. Since we strip
    /// scripts, the client-side hydration never runs and images are lost. This
    /// method performs the same hydration the JS client would do.
    ///
    /// Must be called **before** script removal.
    /// Returns the number of images injected.
    func hydrateApolloImages(in doc: Document) -> Int {
        // 1. Find script tag containing Apollo state
        guard let scripts = try? doc.select("script").array() else { return 0 }

        var apolloJSON: [String: Any]?
        for script in scripts {
            let text = script.data()
            guard let markerRange = text.range(of: "__APOLLO_STATE__") else { continue }

            // Scan forward from marker to find the opening brace
            var searchIndex = markerRange.upperBound
            while searchIndex < text.endIndex && text[searchIndex] != "{" {
                searchIndex = text.index(after: searchIndex)
            }
            guard searchIndex < text.endIndex else { continue }

            // Extract balanced JSON
            guard let jsonSubstring = extractBalancedJSON(from: text, startingAt: searchIndex),
                  let jsonData = String(jsonSubstring).data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            apolloJSON = parsed
            break
        }

        guard let apollo = apolloJSON else { return 0 }

        // 2. Find article entry in ROOT_QUERY
        guard let rootQuery = apollo["ROOT_QUERY"] as? [String: Any] else { return 0 }

        var articleDict: [String: Any]?
        for (_, value) in rootQuery {
            guard let dict = value as? [String: Any] else { continue }
            // Primary: match __typename == "Article"
            if let typename = dict["__typename"] as? String, typename == "Article" {
                articleDict = dict
                break
            }
        }

        // Fallback: any ROOT_QUERY value with a "segments" key
        if articleDict == nil {
            for (_, value) in rootQuery {
                guard let dict = value as? [String: Any] else { continue }
                let hasSegments = dict.keys.contains { $0.hasPrefix("segments") }
                if hasSegments {
                    articleDict = dict
                    break
                }
            }
        }

        guard let article = articleDict else { return 0 }

        // 3. Extract ordered image URLs from segments
        var imageURLs: [String] = []

        // Find the segments key (may have parameters, e.g. "segments({...})")
        let segmentsKey = article.keys.first { $0.hasPrefix("segments") }
        guard let key = segmentsKey,
              let segments = article[key] as? [[String: Any]] else { return 0 }

        // Helper: resolve an Image:* ref to a URL
        func resolveImageRef(_ refID: String) -> String? {
            guard refID.hasPrefix("Image:"),
                  let imageEntry = apollo[refID] as? [String: Any] else { return nil }
            let url = (imageEntry["uri"] as? String)
                ?? (imageEntry["url"] as? String)
                ?? (imageEntry["src"] as? String)
            guard let url = url, !url.isEmpty else { return nil }
            return url.replacingOccurrences(of: "\\u002F", with: "/")
        }

        // Helper: extract image ref from a dict's image-prefixed field
        func extractImageURL(from dict: [String: Any]) -> String? {
            for (fieldKey, fieldValue) in dict {
                guard fieldKey.hasPrefix("image"),
                      let ref = fieldValue as? [String: Any],
                      let refID = ref["__ref"] as? String else { continue }
                return resolveImageRef(refID)
            }
            return nil
        }

        for segment in segments {
            // Skip CALL_TO_ACTION segments — these reference separate
            // galleries unrelated to the article's own image placeholders.
            let segType = (segment["type"] as? String) ?? ""
            if segType == "CALL_TO_ACTION" { continue }

            // Direct image ref on the segment
            if let url = extractImageURL(from: segment) {
                imageURLs.append(url)
            }

            // Gallery ref — walk gallery items for their images
            for (fieldKey, fieldValue) in segment {
                guard fieldKey.hasPrefix("gallery"),
                      let ref = fieldValue as? [String: Any],
                      let galleryID = ref["__ref"] as? String,
                      let galleryEntry = apollo[galleryID] as? [String: Any] else { continue }

                // Find the galleryitems field (may have parameters)
                for (gKey, gValue) in galleryEntry {
                    guard gKey.hasPrefix("galleryitems"),
                          let itemsData = gValue as? [String: Any],
                          let nodes = itemsData["nodes"] as? [[String: Any]] else { continue }

                    for node in nodes {
                        if let url = extractImageURL(from: node) {
                            imageURLs.append(url)
                        }
                    }
                }
            }
        }

        guard !imageURLs.isEmpty else { return 0 }

        // 4. Find empty placeholder elements (CSS aspect-ratio hack)
        guard let placeholders = try? doc.select("[style*=padding-top]").array() else { return 0 }

        let emptyPlaceholders = placeholders.filter { el in
            // Must have no <img> descendant already
            guard let imgs = try? el.select("img"), imgs.isEmpty() else { return false }
            // Must be a leaf element (no child elements) — true aspect-ratio
            // placeholders are empty tags like <span style="padding-top:74%"></span>.
            // Elements with child elements (e.g. video dockable containers with
            // nested <div>s) are structural, not image placeholders.
            guard let children = try? el.children(), children.isEmpty() else { return false }
            // Style must contain a percentage (the aspect-ratio hack)
            guard let style = try? el.attr("style"),
                  style.range(of: #"padding-top\s*:\s*[\d.]+%"#, options: .regularExpression) != nil else {
                return false
            }
            // Element text should be empty or very short (e.g. whitespace only)
            let text = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.count < 10
        }

        guard !emptyPlaceholders.isEmpty else { return 0 }

        // 5. Inject images positionally
        var injected = 0
        let count = min(imageURLs.count, emptyPlaceholders.count)
        for i in 0..<count {
            let placeholder = emptyPlaceholders[i]
            let url = imageURLs[i]
            do {
                // Remove the padding-top hack and inject an <img> tag
                try placeholder.attr("style", "")
                try placeholder.append("<img src=\"\(url)\" loading=\"lazy\">")
                injected += 1
            } catch {
                continue
            }
        }

        return injected
    }
}
