import Foundation
import UIKit
import SwiftSoup

// MARK: - Favicon management

extension PageCacheService {

    private var sourcesBaseURL: URL {
        ContainerPaths.sourcesBaseURL
    }

    /// Discovers the best favicon URL from an HTML document.
    /// Prefers apple-touch-icon (high-res PNG), then icon links sorted by
    /// size descending, then falls back to /favicon.ico at the domain root.
    private func discoverFaviconURL(in html: String, baseURL: URL) -> URL? {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return nil }
        return discoverFaviconURL(in: doc, baseURL: baseURL)
    }

    /// Discovers the best favicon URL from a parsed SwiftSoup Document.
    func discoverFaviconURL(in doc: Document, baseURL: URL) -> URL? {
        // 1. apple-touch-icon — pick the largest raster icon, skipping SVGs
        //    (UIImage can't render SVGs; some sites list SVG first with sizes="any")
        if let touchIcons = try? doc.select("link[rel=apple-touch-icon], link[rel=apple-touch-icon-precomposed]") {
            var best: (url: URL, size: Int)?
            for icon in touchIcons {
                guard let href = try? icon.attr("abs:href"),
                      !href.isEmpty,
                      let url = URL(string: href) else { continue }
                // Skip SVG icons — UIImage(data:) can't load them
                if url.pathExtension.lowercased() == "svg" { continue }
                let sizes = (try? icon.attr("sizes")) ?? ""
                if sizes.lowercased() == "any" { continue }
                let size = sizes.split(separator: "x").first.flatMap { Int($0) } ?? 0
                if best == nil || size > best!.size {
                    best = (url, size)
                }
            }
            if let best { return best.url }
        }

        // 2. <link rel="icon"> — pick the largest raster icon available
        if let icons = try? doc.select("link[rel~=icon]") {
            var best: (url: URL, size: Int)?
            for icon in icons {
                guard let href = try? icon.attr("abs:href"),
                      !href.isEmpty,
                      let url = URL(string: href) else { continue }
                // Skip SVG icons — UIImage(data:) can't load them
                if url.pathExtension.lowercased() == "svg" { continue }
                // Parse sizes attribute (e.g. "96x96", "32x32")
                let sizes = (try? icon.attr("sizes")) ?? ""
                let size = sizes.split(separator: "x").first.flatMap { Int($0) } ?? 0
                if best == nil || size > best!.size {
                    best = (url, size)
                }
            }
            if let best { return best.url }
        }

        // 3. Fallback to /favicon.ico
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.path = "/favicon.ico"
        return components.url
    }

    /// Discovers and caches a favicon for a source by fetching the site's HTML
    /// and extracting the best icon link. Falls back to /favicon.ico.
    /// Handles feed subdomains (e.g. feeds.foxnews.com → foxnews.com).
    func discoverAndCacheFavicon(for sourceID: UUID, siteURL: URL) async {
        guard let image = await fetchFaviconImage(siteURL: siteURL) else { return }
        await saveFavicon(image, for: sourceID)
    }

    /// Downloads a favicon from a URL and saves it as favicon.png in the given directory.
    private func downloadFavicon(from url: URL, to directory: URL) async {
        do {
            var request = URLRequest(url: url)
            request.assumesHTTP3Capable = false
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty else { return }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let faviconPath = directory.appendingPathComponent("favicon.png")
            try data.write(to: faviconPath)
        } catch {
            // Non-critical — favicon will fall back to letter avatar
        }
    }

    /// Downloads and caches the favicon for a source from a direct URL.
    /// Used as a fallback when siteURL is unavailable.
    func cacheFavicon(for sourceID: UUID, from iconURL: String) async {
        guard let url = URL(string: iconURL) else { return }
        await downloadFavicon(from: url, to: sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true))
    }

    /// Downloads and caches a favicon into an article's directory from a direct URL.
    func cacheArticleFavicon(for articleID: UUID, from iconURL: String) async {
        guard let url = URL(string: iconURL) else { return }
        await downloadFavicon(from: url, to: articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true))
    }

    /// Discovers and caches a per-article favicon from already-parsed HTML.
    /// Extracts the best icon link from the document without an extra network request.
    func cacheArticleFavicon(for articleID: UUID, fromDoc doc: Document, baseURL: URL) async {
        guard let faviconURL = discoverFaviconURL(in: doc, baseURL: baseURL) else { return }
        await downloadFavicon(from: faviconURL, to: articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true))
    }

    /// Returns the locally cached favicon image for a source, if it exists.
    func cachedFavicon(for sourceID: UUID) -> UIImage? {
        let path = sourcesBaseURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("favicon.png")
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    /// Generates and saves a gradient bookmark favicon for the Saved Pages source.
    /// No-op if the favicon already exists on disk.
    func generateSavedPagesFavicon() {
        let sourceDir = sourcesBaseURL
            .appendingPathComponent(Source.savedPagesID.uuidString, isDirectory: true)
        let faviconPath = sourceDir.appendingPathComponent("favicon.png")
        guard !FileManager.default.fileExists(atPath: faviconPath.path) else { return }

        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Gradient background matching Theme.accentGradient
            let colors = [
                UIColor(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0xF0/255.0, alpha: 1).cgColor,
                UIColor(red: 0xA8/255.0, green: 0x55/255.0, blue: 0xF7/255.0, alpha: 1).cgColor
            ]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 1]
            ) else { return }
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )

            // Draw bookmark.fill SF Symbol centered
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 56, weight: .medium)
            if let symbol = UIImage(systemName: "bookmark.fill", withConfiguration: symbolConfig) {
                let symbolSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2
                )
                symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(at: origin)
            }
        }

        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        if let pngData = image.pngData() {
            try? pngData.write(to: faviconPath)
        }
    }

    /// Fetches a favicon from a site URL and returns it as a UIImage without
    /// saving to disk. Used for previewing favicons before a source is added.
    func fetchFaviconImage(siteURL: URL) async -> UIImage? {
        // Try the provided URL first, then fall back to the root domain
        // if the host is a feed subdomain (e.g. feeds.foxnews.com → foxnews.com)
        var urlsToTry = [siteURL]
        if let host = siteURL.host?.lowercased() {
            let feedPrefixes = ["feeds.", "feed.", "rss.", "xml."]
            for prefix in feedPrefixes {
                if host.hasPrefix(prefix) {
                    let rootHost = String(host.dropFirst(prefix.count))
                    var components = URLComponents()
                    components.scheme = siteURL.scheme ?? "https"
                    components.host = rootHost
                    if let rootURL = components.url {
                        urlsToTry.append(rootURL)
                    }
                    break
                }
            }
        }

        for url in urlsToTry {
            if let image = await fetchFaviconFromPage(url) {
                return image
            }
        }
        return nil
    }

    /// Attempts to fetch a favicon from a single page URL.
    private func fetchFaviconFromPage(_ pageURL: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: pageURL)
            request.assumesHTTP3Capable = false
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            let html = String(data: data, encoding: .utf8) ?? ""

            guard let faviconURL = discoverFaviconURL(in: html, baseURL: pageURL) else { return nil }

            var iconRequest = URLRequest(url: faviconURL)
            iconRequest.assumesHTTP3Capable = false
            let (iconData, iconResponse) = try await session.data(for: iconRequest)
            guard let iconHTTP = iconResponse as? HTTPURLResponse,
                  iconHTTP.statusCode == 200,
                  !iconData.isEmpty else { return nil }
            return UIImage(data: iconData)
        } catch {
            return nil
        }
    }

    /// Saves a UIImage as the favicon for a source.
    /// Used when the favicon was already fetched for preview purposes.
    func saveFavicon(_ image: UIImage, for sourceID: UUID) async {
        guard let data = image.pngData() else { return }
        let directory = sourcesBaseURL.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let faviconPath = directory.appendingPathComponent("favicon.png")
            try data.write(to: faviconPath)
        } catch {
            // Non-critical
        }
    }
}
