import Foundation
import UIKit
import WatchConnectivity
import GRDB
import SwiftSoup

/// Manages Watch Connectivity session on the iPhone side.
/// Pushes lightweight article metadata to the paired Apple Watch via `updateApplicationContext`.
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Pushes the latest articles to the watch via application context.
    /// Safe to call at any time — silently no-ops if watch is unavailable.
    func pushArticlesToWatch() {
        let session = WCSession.default
        guard WCSession.isSupported(),
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }

        let articles = fetchArticlesForWatch()
        guard !articles.isEmpty else { return }

        do {
            let encoder = JSONEncoder()
            var data = try encoder.encode(articles)

            // updateApplicationContext has a ~262KB limit.
            // JSON encodes Data as base64 (~33% inflation), so check at 250KB
            // and strip thumbnails as a last resort.
            if data.count > 250_000 {
                let stripped = articles.map {
                    WatchArticle(
                        id: $0.id, title: $0.title, sourceName: $0.sourceName,
                        publishedAt: $0.publishedAt, readingMinutes: $0.readingMinutes,
                        isRead: $0.isRead, excerpt: $0.excerpt, thumbnailData: nil
                    )
                }
                data = try encoder.encode(stripped)
            }

            try session.updateApplicationContext(["articles": data])
        } catch {
            print("[WatchConnectivity] Failed to push articles: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[WatchConnectivity] Activation failed: \(error)")
        } else if activationState == .activated {
            // Push current articles on activation — ensures newly installed
            // watch apps and fresh launches get data immediately
            pushArticlesToWatch()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = message["action"] as? String,
              let idString = message["articleID"] as? String,
              let articleID = UUID(uuidString: idString) else { return }

        switch action {
        case "markRead":
            markArticleAsRead(articleID)
        case "openOnPhone":
            openArticleOnPhone(articleID)
        default:
            break
        }
    }

    private func markArticleAsRead(_ id: UUID) {
        do {
            try DatabaseManager.shared.dbPool.write { db in
                try db.execute(sql: "UPDATE article SET isRead = 1 WHERE id = ?", arguments: [id])
            }
            // Push updated list back to watch
            pushArticlesToWatch()
        } catch {
            print("[WatchConnectivity] Failed to mark article as read: \(error)")
        }
    }

    private func openArticleOnPhone(_ id: UUID) {
        DispatchQueue.main.async {
            guard let url = URL(string: "preread://article/\(id.uuidString)") else { return }
            UIApplication.shared.open(url)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) { }

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for the new watch when user switches watches
        session.activate()
    }

    // MARK: - Private

    private func fetchArticlesForWatch() -> [WatchArticle] {
        do {
            // Phase 1: DB read — fetch articles with cache level info
            let rows: [(Article, String, String?)] = try DatabaseManager.shared.dbPool.read { db in
                let sql = """
                    SELECT article.*, source.title AS sourceName,
                           cachedPage.cacheLevelUsed AS cacheLevelUsed
                    FROM article
                    INNER JOIN source ON source.id = article.sourceID
                    LEFT JOIN cachedPage ON cachedPage.articleID = article.id
                    WHERE article.fetchStatus IN ('cached', 'partial')
                    AND article.sourceID != ?
                    ORDER BY COALESCE(article.publishedAt, article.addedAt) DESC
                    LIMIT 5
                    """
                let dbRows = try Row.fetchAll(db, sql: sql, arguments: [Source.savedPagesID])
                return dbRows.compactMap { row in
                    guard let article = try? Article(row: row) else { return nil }
                    let sourceName: String = row["sourceName"] ?? ""
                    let cacheLevelRaw: String? = row["cacheLevelUsed"]
                    return (article, sourceName, cacheLevelRaw)
                }
            }

            // Phase 2: Extract excerpts and thumbnails outside DB connection
            return rows.map { article, sourceName, cacheLevelRaw in
                let excerpt = extractExcerpt(articleID: article.id, cacheLevelRaw: cacheLevelRaw)
                let thumbnail = loadThumbnailData(articleID: article.id)
                return WatchArticle(
                    id: article.id,
                    title: article.title,
                    sourceName: sourceName,
                    publishedAt: article.publishedAt,
                    readingMinutes: article.readingMinutes,
                    isRead: article.isRead,
                    excerpt: excerpt,
                    thumbnailData: thumbnail
                )
            }
        } catch {
            print("[WatchConnectivity] Failed to fetch articles: \(error)")
            return []
        }
    }

    /// Extracts a plain-text excerpt from a standard-mode cached article.
    /// Returns nil for full-mode articles or if the HTML can't be read/parsed.
    private func extractExcerpt(articleID: UUID, cacheLevelRaw: String?) -> String? {
        guard cacheLevelRaw == CacheLevel.standard.rawValue else { return nil }

        let indexURL = ContainerPaths.articlesBaseURL
            .appendingPathComponent(articleID.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")

        guard let data = try? Data(contentsOf: indexURL),
              let html = String(data: data, encoding: .utf8),
              let doc = try? SwiftSoup.parse(html),
              let container = try? doc.select(".reader-container").first(),
              let paragraphs = try? container.select("p") else {
            return nil
        }

        var parts: [String] = []
        var totalLength = 0
        let maxLength = 1500
        let maxParagraphs = 5

        for p in paragraphs {
            guard let text = try? p.text().trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }

            // Skip very short paragraphs at the start (bylines, datelines)
            if text.count < 20 && parts.isEmpty { continue }

            if totalLength + text.count > maxLength && !parts.isEmpty {
                let remaining = maxLength - totalLength
                if remaining > 50 {
                    let truncated = String(text.prefix(remaining))
                    if let lastPeriod = truncated.lastIndex(of: ".") {
                        parts.append(String(truncated[...lastPeriod]))
                    } else if let lastSpace = truncated.lastIndex(of: " ") {
                        parts.append(String(truncated[...lastSpace]) + "…")
                    }
                }
                break
            }

            parts.append(text)
            totalLength += text.count

            if parts.count >= maxParagraphs { break }
        }

        let result = parts.joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }

    /// Loads and compresses a thumbnail for watch transfer.
    /// Prefers the full thumbnail, falls back to the small thumb.
    private func loadThumbnailData(articleID: UUID) -> Data? {
        let articleDir = ContainerPaths.articlesBaseURL
            .appendingPathComponent(articleID.uuidString, isDirectory: true)

        // Try full thumbnail first, then small thumb
        let candidates = ["thumbnail.jpg", "thumb.jpg"]
        for name in candidates {
            let url = articleDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { continue }

            // Resize to 200px wide for watch display.
            // With 5 articles, this keeps total payload well under the
            // 262KB updateApplicationContext limit (even with base64 inflation).
            let targetWidth: CGFloat = 150
            let scale = targetWidth / image.size.width
            guard scale < 1 else {
                return image.jpegData(compressionQuality: 0.5)
            }
            let targetSize = CGSize(width: targetWidth, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            return resized.jpegData(compressionQuality: 0.5)
        }
        return nil
    }
}
