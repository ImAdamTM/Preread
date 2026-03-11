import UIKit
import LRUCache

/// A cached thumbnail entry that records whether the image is a favicon fallback.
struct CachedThumbnail: Sendable {
    let image: UIImage
    let isFavicon: Bool
}

/// A shared in-memory cache for article thumbnail images.
///
/// Two separate caches are maintained:
/// - **Row thumbnails** (80px `thumb.jpg`) — used by `ArticleRowView`
/// - **Card thumbnails** (full-size `thumbnail.jpg`) — used by carousel cards
///
/// Both are LRU-evicting and bounded by count, so memory stays
/// predictable regardless of how many sources/articles exist.
final class ThumbnailCache: Sendable {
    static let shared = ThumbnailCache()

    /// Small thumbnails for list rows (thumb.jpg, ~80px).
    /// Capacity 150 covers ~6 sources × 25 articles each.
    private let rowCache = LRUCache<UUID, CachedThumbnail>(countLimit: 150)

    /// Large thumbnails for carousel cards (thumbnail.jpg, ~600px).
    private let cardCache = LRUCache<UUID, UIImage>(countLimit: 80)

    /// Source favicons keyed by source ID.
    /// Bounded at 50 — one per source, so this covers most users easily.
    private let faviconCache = LRUCache<UUID, UIImage>(countLimit: 50)

    private init() {}

    // MARK: - Row thumbnails

    /// Returns a cached row thumbnail, or nil if not in cache.
    func rowThumbnail(for articleID: UUID) -> CachedThumbnail? {
        rowCache.value(forKey: articleID)
    }

    /// Stores a row thumbnail in the cache.
    func setRowThumbnail(_ image: UIImage, isFavicon: Bool, for articleID: UUID) {
        rowCache.setValue(CachedThumbnail(image: image, isFavicon: isFavicon), forKey: articleID)
    }

    /// Removes a specific entry (e.g. after re-fetch or when a real thumbnail replaces a favicon).
    func removeRowThumbnail(for articleID: UUID) {
        rowCache.removeValue(forKey: articleID)
    }

    // MARK: - Card thumbnails

    /// Returns a cached card thumbnail, or nil if not in cache.
    func cardThumbnail(for articleID: UUID) -> UIImage? {
        cardCache.value(forKey: articleID)
    }

    /// Stores a card thumbnail in the cache.
    func setCardThumbnail(_ image: UIImage, for articleID: UUID) {
        cardCache.setValue(image, forKey: articleID)
    }

    /// Removes a specific card entry.
    func removeCardThumbnail(for articleID: UUID) {
        cardCache.removeValue(forKey: articleID)
    }

    // MARK: - Source favicons

    /// Returns a cached source favicon, or nil if not in cache.
    func favicon(for sourceID: UUID) -> UIImage? {
        faviconCache.value(forKey: sourceID)
    }

    /// Stores a source favicon in the cache.
    func setFavicon(_ image: UIImage, for sourceID: UUID) {
        faviconCache.setValue(image, forKey: sourceID)
    }

    /// Loads a source favicon from disk and populates the cache.
    /// Returns the image if found, nil otherwise.
    @discardableResult
    static func loadFaviconFromDisk(for sourceID: UUID) -> UIImage? {
        let path = ContainerPaths.sourcesBaseURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("favicon.png")
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let img = UIImage(data: data) else { return nil }
        shared.setFavicon(img, for: sourceID)
        return img
    }

    // MARK: - Bulk operations

    /// Removes all cached images (e.g. on memory warning).
    func removeAll() {
        rowCache.removeAll()
        cardCache.removeAll()
        faviconCache.removeAll()
    }

    // MARK: - Pre-warming

    /// Pre-loads row thumbnails for the given article IDs off the main thread.
    /// Skips any articles already in the cache. Returns when all loads complete.
    static func prewarmRowThumbnails(for articles: [Article]) async {
        let articlesToLoad = articles.filter { shared.rowThumbnail(for: $0.id) == nil }
        guard !articlesToLoad.isEmpty else { return }

        await withTaskGroup(of: (UUID, UIImage, Bool)?.self) { group in
            for article in articlesToLoad {
                let articleID = article.id
                let sourceID = article.sourceID
                group.addTask {
                    await Task.detached(priority: .utility) {
                        Self.loadRowThumbnailFromDisk(articleID: articleID, sourceID: sourceID)
                    }.value
                }
            }
            for await result in group {
                if let (id, image, isFavicon) = result {
                    shared.setRowThumbnail(image, isFavicon: isFavicon, for: id)
                }
            }
        }
    }

    /// Loads a single row thumbnail from disk. Returns (articleID, image, isFavicon)
    /// or nil if nothing found. Same lookup chain as ArticleRowView.
    static func loadRowThumbnailFromDisk(articleID: UUID, sourceID: UUID) -> (UUID, UIImage, Bool)? {
        let articleDir = ContainerPaths.articlesBaseURL
            .appendingPathComponent(articleID.uuidString, isDirectory: true)

        // 1. Small downsampled thumb
        let thumbPath = articleDir.appendingPathComponent("thumb.jpg")
        if FileManager.default.fileExists(atPath: thumbPath.path),
           let data = try? Data(contentsOf: thumbPath),
           let img = UIImage(data: data) {
            return (articleID, img, false)
        }

        // 2. Full-size thumbnail, downsampled via ImageIO
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "avif"] {
            let path = articleDir.appendingPathComponent("thumbnail.\(ext)")
            if FileManager.default.fileExists(atPath: path.path),
               let img = downsampledImage(at: path, maxPixels: 240) {
                return (articleID, img, false)
            }
        }

        // 3. Article-level favicon
        let articleFaviconPath = articleDir.appendingPathComponent("favicon.png")
        if FileManager.default.fileExists(atPath: articleFaviconPath.path),
           let data = try? Data(contentsOf: articleFaviconPath),
           let img = UIImage(data: data) {
            return (articleID, img, true)
        }

        // 4. Source favicon
        let faviconPath = ContainerPaths.sourcesBaseURL
            .appendingPathComponent("\(sourceID.uuidString)/favicon.png")
        if FileManager.default.fileExists(atPath: faviconPath.path),
           let data = try? Data(contentsOf: faviconPath),
           let img = UIImage(data: data) {
            return (articleID, img, true)
        }

        return nil
    }

    private static func downsampledImage(at url: URL, maxPixels: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
