import Foundation
import SwiftSoup
import SwiftReadability

struct ExtractedContent {
    let title: String
    let bodyHTML: String
    let imageURLs: [String]
}

enum ReaderModeExtractor {

    /// Extracts readable content from raw HTML using Mozilla's Readability algorithm
    /// via the SwiftReadability library.
    static func extract(from htmlString: String, url: URL? = nil) -> ExtractedContent {
        let baseURL = url ?? URL(string: "about:blank")!

        do {
            let readability = Readability(html: htmlString, url: baseURL)
            if let result = try readability.parse() {
                let title = result.title ?? ""
                let bodyHTML = result.contentHTML
                let imageURLs = extractImageURLs(from: bodyHTML)

                return ExtractedContent(
                    title: title,
                    bodyHTML: bodyHTML,
                    imageURLs: imageURLs
                )
            }
        } catch {
            print("[ReaderModeExtractor] Readability parse failed: \(error)")
        }

        // Fallback: return raw HTML with a basic title extraction
        let title = extractFallbackTitle(from: htmlString)
        return ExtractedContent(title: title, bodyHTML: htmlString, imageURLs: [])
    }

    // MARK: - Image extraction from content HTML

    private static func extractImageURLs(from html: String) -> [String] {
        guard let doc = try? SwiftSoup.parseBodyFragment(html),
              let body = doc.body(),
              let images = try? body.select("img") else { return [] }

        var urls: [String] = []
        for img in images {
            if let src = try? img.attr("src"), !src.isEmpty {
                urls.append(src)
            } else if let dataSrc = try? img.attr("data-src"), !dataSrc.isEmpty {
                urls.append(dataSrc)
            }
        }
        return urls
    }

    // MARK: - Fallback title

    private static func extractFallbackTitle(from htmlString: String) -> String {
        guard let doc = try? SwiftSoup.parse(htmlString) else { return "" }

        if let titleText = try? doc.title(), !titleText.isEmpty {
            let parts = titleText.components(separatedBy: " | ")
            return parts.first?.trimmingCharacters(in: .whitespaces) ?? titleText
        }

        if let h1 = try? doc.select("h1").first(), let text = try? h1.text(), !text.isEmpty {
            return text
        }

        return ""
    }
}
