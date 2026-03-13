import Foundation
import WatchConnectivity
import GRDB

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
            let data = try JSONEncoder().encode(articles)
            try session.updateApplicationContext(["articles": data])
        } catch {
            print("[WatchConnectivity] Failed to push articles: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[WatchConnectivity] Activation failed: \(error)")
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
            return try DatabaseManager.shared.dbPool.read { db in
                let sql = """
                    SELECT article.*, source.title AS sourceName
                    FROM article
                    INNER JOIN source ON source.id = article.sourceID
                    WHERE article.fetchStatus IN ('cached', 'partial')
                    AND article.sourceID != ?
                    ORDER BY COALESCE(article.publishedAt, article.addedAt) DESC
                    LIMIT 10
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [Source.savedPagesID])
                return rows.compactMap { row in
                    guard let article = try? Article(row: row) else { return nil }
                    let sourceName: String = row["sourceName"] ?? ""
                    return WatchArticle(
                        id: article.id,
                        title: article.title,
                        sourceName: sourceName,
                        publishedAt: article.publishedAt
                    )
                }
            }
        } catch {
            print("[WatchConnectivity] Failed to fetch articles: \(error)")
            return []
        }
    }
}
