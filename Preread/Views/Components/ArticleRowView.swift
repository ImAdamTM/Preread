import SwiftUI

struct ArticleRowView: View {
    let article: Article
    let namespace: Namespace.ID
    let onTap: () -> Void
    let onToggleRead: () -> Void
    let onToggleSave: () -> Void
    let onRefetch: () -> Void
    let onDelete: () -> Void
    var sourceName: String? = nil
    var showUnsaveInsteadOfSave: Bool = false

    @State private var cachedThumbnailImage: UIImage?
    @State private var isFaviconFallback = false
    @State private var thumbnailLoaded = false

    /// Seed image provided by the parent (pre-warmed from ThumbnailCache).
    /// When set, the row skips its own disk load on first appearance.
    var preloadedThumbnail: UIImage? = nil
    var preloadedIsFavicon: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Thumbnail or favicon fallback
                thumbnailView

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(Theme.scaledFont(size: 17, weight: .medium))
                        .foregroundColor(Theme.textPrimary.opacity(article.isRead ? 0.5 : 0.85))
                        .lineLimit(2)
                        .matchedGeometryEffect(id: article.id.uuidString + "-title", in: namespace)

                    HStack(spacing: 0) {
                        if let sourceName {
                            Text(sourceName)
                                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                                .foregroundColor(Theme.textSecondary.opacity(0.7))
                                .lineLimit(1)
                        }

                        if let published = article.publishedAt {
                            if sourceName != nil {
                                Text(" · ")
                                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                            }
                            Text(RelativeTimeFormatter.string(from: published))
                                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                                .foregroundColor(Theme.textSecondary.opacity(0.7))
                        }

                        if let status = statusLabel {
                            if article.publishedAt != nil || sourceName != nil {
                                Text(" · ")
                                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                            }
                            Text(status.text)
                                .font(Theme.scaledFont(size: 13, weight: .medium, relativeTo: .footnote))
                                .foregroundColor(status.color)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Right indicator: read/unread icon or fetching spinner
                ZStack {
                    Color.clear
                    if article.fetchStatus == .fetching {
                        fetchingSpinner
                            .accessibilityLabel("Saving")
                    } else {
                        Circle()
                            .fill(article.isRead ? Theme.textSecondary.opacity(0.2) : Theme.accent)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 24)
            }
            .contentShape(Rectangle())
            .padding(.leading, 20)
            .padding(.trailing, 15)
            .padding(.vertical, 14)
            .frame(minHeight: 96)
            .overlay(alignment: .bottom) {
                Theme.borderProminent
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                HapticManager.modeToggle()
                onToggleRead()
            } label: {
                Label(
                    article.isRead ? "Unread" : "Read",
                    systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                )
            }
            .tint(Theme.accent)

            Button {
                HapticManager.pullToRefresh()
                onRefetch()
            } label: {
                Label("Re-fetch", systemImage: "arrow.clockwise")
            }
            .tint(Theme.teal)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if showUnsaveInsteadOfSave {
                Button(role: .destructive) {
                    onToggleSave()
                } label: {
                    Label("Remove", systemImage: "bookmark.slash")
                }
                .tint(Theme.danger)
            } else {
                Button {
                    onToggleSave()
                } label: {
                    Label(
                        article.isSaved ? "Unsave" : "Save",
                        systemImage: article.isSaved ? "bookmark.slash" : "bookmark"
                    )
                }
                .tint(Theme.teal)
            }
        }
        .onChange(of: article.fetchStatus) { _, newStatus in
            if newStatus == .cached || newStatus == .partial {
                // Article just finished caching — a real thumbnail is now on
                // disk. Invalidate the cached entry (which may be a stale
                // favicon fallback) and re-load from disk unconditionally.
                ThumbnailCache.shared.removeRowThumbnail(for: article.id)
                Task {
                    await loadLocalThumbnail()
                }
            }
        }
        .onChange(of: article.cachedAt) { _, _ in
            // Reload thumbnail when cachedAt is touched (e.g. after favicon caching)
            if isFaviconFallback || cachedThumbnailImage == nil {
                Task {
                    await loadLocalThumbnail()
                }
            }
        }
        .contextMenu {
            Button {
                onToggleRead()
            } label: {
                Label(
                    article.isRead ? "Mark as unread" : "Mark as read",
                    systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                )
            }

            if !showUnsaveInsteadOfSave {
                Button {
                    onToggleSave()
                } label: {
                    Label(
                        article.isSaved ? "Unsave" : "Save",
                        systemImage: article.isSaved ? "bookmark.slash" : "bookmark"
                    )
                }
            }

            Button {
                onRefetch()
            } label: {
                Label("Re-fetch article", systemImage: "arrow.clockwise")
            }

            if let url = URL(string: article.articleURL) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Link(destination: url) {
                    Label("Open in Safari", systemImage: "safari")
                }
            }

            if showUnsaveInsteadOfSave {
                Divider()

                Button(role: .destructive) {
                    onToggleSave()
                } label: {
                    Label("Remove from Saved", systemImage: "bookmark.slash")
                }
            }
        }
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        Group {
            if let uiImage = cachedThumbnailImage, isFaviconFallback {
                // Favicon: centered on material background
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemFill))
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .saturation(1)
                        .opacity(0.7)
                }
                .frame(width: 80, height: 80)
            } else if let uiImage = cachedThumbnailImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if thumbnailLoaded {
                gradientPlaceholder
            } else if let cached = synchronousCacheHit {
                // Synchronous cache hit — render immediately without a frame delay.
                // The onAppear below writes the values into @State so subsequent
                // renders go through the branches above instead of re-checking.
                thumbnailImage(cached.image, isFavicon: cached.isFavicon)
                    .onAppear {
                        cachedThumbnailImage = cached.image
                        isFaviconFallback = cached.isFavicon
                        thumbnailLoaded = true
                    }
            } else {
                // No cache hit — show gradient placeholder while loading from disk
                gradientPlaceholder
                    .task {
                        // Use preloaded image from parent if available
                        if let preloaded = preloadedThumbnail {
                            cachedThumbnailImage = preloaded
                            isFaviconFallback = preloadedIsFavicon
                            thumbnailLoaded = true
                            return
                        }
                        await loadLocalThumbnail()
                    }
            }
        }
    }

    /// Checks the LRU cache synchronously during body evaluation.
    /// This avoids the one-frame flash from the async `.task` path.
    private var synchronousCacheHit: CachedThumbnail? {
        if let preloaded = preloadedThumbnail {
            return CachedThumbnail(image: preloaded, isFavicon: preloadedIsFavicon)
        }
        return ThumbnailCache.shared.rowThumbnail(for: article.id)
    }

    /// Renders a thumbnail image in either favicon or full-bleed style.
    @ViewBuilder
    private func thumbnailImage(_ uiImage: UIImage, isFavicon: Bool) -> some View {
        if isFavicon {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemFill))
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .saturation(1)
                    .opacity(0.7)
            }
            .frame(width: 80, height: 80)
        } else {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Loads the locally cached thumbnail off the main thread.
    /// Prefers the small downsampled `thumb.jpg` for performance, falling back
    /// to the full-size thumbnail, then the source's cached favicon.
    private func loadLocalThumbnail() async {
        let articleID = article.id.uuidString
        let sourceID = article.sourceID.uuidString
        let result: (UIImage?, Bool) = await Task.detached(priority: .utility) {
            let articleDir = ContainerPaths.articlesBaseURL.appendingPathComponent(articleID, isDirectory: true)

            // 1. Prefer the small downsampled thumbnail
            let thumbPath = articleDir.appendingPathComponent("thumb.jpg")
            if FileManager.default.fileExists(atPath: thumbPath.path),
               let data = try? Data(contentsOf: thumbPath),
               let img = UIImage(data: data) {
                return (img, false)
            }

            // 2. Fall back to the full-size thumbnail (for articles cached before downsampling was added)
            //    Use ImageIO to downsample on load instead of decoding the full bitmap.
            for ext in ["jpg", "jpeg", "png", "webp", "gif", "avif"] {
                let path = articleDir.appendingPathComponent("thumbnail.\(ext)")
                if FileManager.default.fileExists(atPath: path.path) {
                    if let img = Self.downsampledImage(at: path, maxPixels: 240) {
                        return (img, false)
                    }
                }
            }

            // 3. Fall back to article-level favicon (saved pages)
            let articleFaviconPath = articleDir.appendingPathComponent("favicon.png")
            if FileManager.default.fileExists(atPath: articleFaviconPath.path),
               let data = try? Data(contentsOf: articleFaviconPath),
               let img = UIImage(data: data) {
                return (img, true)
            }

            // 4. Fall back to source's cached favicon
            let faviconPath = ContainerPaths.sourcesBaseURL.appendingPathComponent("\(sourceID)/favicon.png")
            if FileManager.default.fileExists(atPath: faviconPath.path),
               let data = try? Data(contentsOf: faviconPath),
               let img = UIImage(data: data) {
                return (img, true)
            }

            return (nil, false)
        }.value
        cachedThumbnailImage = result.0
        isFaviconFallback = result.1
        thumbnailLoaded = true
        // Populate shared cache for future use
        if let image = result.0 {
            ThumbnailCache.shared.setRowThumbnail(image, isFavicon: result.1, for: article.id)
        }
    }

    /// Efficiently loads and downsamples an image using ImageIO without
    /// decoding the full bitmap into memory.
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

    private var gradientPlaceholder: some View {
        let label = sourceName ?? article.title
        let letter = String(label.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.avatarGradient(for: label))
            Text(letter)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 80, height: 80)
    }

    // MARK: - Status label

    private var statusLabel: (text: String, color: Color)? {
        switch article.fetchStatus {
        case .cached, .partial:
            return ("Saved", Theme.textSecondary.opacity(0.7))
        case .fetching:
            return ("Saving", Theme.textSecondary.opacity(0.7))
        case .pending:
            return ("Pending", Theme.warning.opacity(0.5))
        case .failed:
            return ("Failed", Theme.danger.opacity(0.5))
        }
    }

    private var fetchingSpinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
            ZStack {
                Circle()
                    .stroke(Theme.borderProminent, lineWidth: 1.5)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent.opacity(0.6), Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 16, height: 16)
        }
    }

    // MARK: - Accessibility

    private var rowAccessibilityLabel: String {
        var parts: [String] = [article.title]

        if let published = article.publishedAt {
            parts.append(RelativeTimeFormatter.string(from: published))
        }

        parts.append(article.isRead ? "Read" : "Unread")

        if let status = statusLabel {
            parts.append(status.text)
        }

        return parts.joined(separator: ", ")
    }

}
