import SwiftUI

struct ArticleRowView: View {
    let article: Article
    let namespace: Namespace.ID
    let onTap: () -> Void
    let onToggleRead: () -> Void
    let onToggleSave: () -> Void
    let onRefetch: () -> Void
    let onDelete: () -> Void

    @State private var appearTime = Date()
    @State private var unreadDotScale: CGFloat = 1.0
    @State private var cachedThumbnailImage: UIImage?
    @State private var thumbnailLoaded = false

    private var hasThumbnail: Bool {
        article.thumbnailURL != nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // New article left border
                newArticleBorder

                // Thumbnail or gradient placeholder
                if hasThumbnail {
                    thumbnailView
                }

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(Theme.scaledFont(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .matchedGeometryEffect(id: article.id.uuidString + "-title", in: namespace)

                    HStack(spacing: 6) {
                        // Timestamp
                        if let published = article.publishedAt {
                            Text(RelativeTimeFormatter.string(from: published))
                                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                                .foregroundColor(Theme.textSecondary)
                        }

                        // Unread dot
                        if !article.isRead {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 5, height: 5)
                                .scaleEffect(unreadDotScale)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Cache status + timestamp
                VStack(alignment: .trailing, spacing: 2) {
                    cacheStatusIcon
                        .frame(width: 20, height: 20)
                        .accessibilityLabel(cacheStatusAccessibilityLabel)

                    if let cachedAt = article.cachedAt {
                        Text(RelativeTimeFormatter.string(from: cachedAt))
                            .font(Theme.scaledFont(size: 10, relativeTo: .caption2))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, hasThumbnail ? 12 : 8)
            .frame(minHeight: hasThumbnail ? 80 : 64)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                HapticManager.deleteConfirm()
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                onRefetch()
            } label: {
                Label("Re-fetch", systemImage: "arrow.clockwise")
            }
            .tint(Theme.accent)

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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if Theme.reduceMotion {
                    unreadDotScale = article.isRead ? 1.0 : 0
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        unreadDotScale = article.isRead ? 1.0 : 1.2
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                            unreadDotScale = article.isRead ? 1.0 : 0
                        }
                    }
                }
                onToggleRead()
            } label: {
                Label(
                    article.isRead ? "Mark unread" : "Mark read",
                    systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                )
            }
            .tint(Theme.teal)
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

            Button {
                onToggleSave()
            } label: {
                Label(
                    article.isSaved ? "Unsave" : "Save",
                    systemImage: article.isSaved ? "bookmark.slash" : "bookmark"
                )
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

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        Group {
            if let uiImage = cachedThumbnailImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if thumbnailLoaded {
                // Local load finished with no result — fall back to remote
                if let thumbURL = article.thumbnailURL, let url = URL(string: thumbURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            gradientPlaceholder
                        }
                    }
                    .frame(width: 56, height: 56)
                } else {
                    gradientPlaceholder
                }
            } else {
                // Placeholder while loading from disk
                gradientPlaceholder
                    .task {
                        await loadLocalThumbnail()
                    }
            }
        }
    }

    /// Loads the locally cached thumbnail off the main thread.
    private func loadLocalThumbnail() async {
        let articleID = article.id.uuidString
        let image: UIImage? = await Task.detached(priority: .utility) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let articleDir = appSupport.appendingPathComponent("preread/articles/\(articleID)", isDirectory: true)
            for ext in ["jpg", "jpeg", "png", "webp", "gif", "avif"] {
                let path = articleDir.appendingPathComponent("thumbnail.\(ext)")
                if FileManager.default.fileExists(atPath: path.path),
                   let data = try? Data(contentsOf: path),
                   let img = UIImage(data: data) {
                    return img
                }
            }
            return nil
        }.value
        cachedThumbnailImage = image
        thumbnailLoaded = true
    }

    private var gradientPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.avatarGradient(for: article.title))
            .frame(width: 56, height: 56)
    }

    // MARK: - Cache status icon

    @ViewBuilder
    private var cacheStatusIcon: some View {
        switch article.fetchStatus {
        case .cached:
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        case .partial:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        case .fetching:
            fetchingSpinner
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.textSecondary.opacity(0.4))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 17))
                .foregroundColor(Theme.danger)
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
                            colors: [Theme.teal, Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 16, height: 16)
        }
    }

    private var cacheStatusAccessibilityLabel: String {
        switch article.fetchStatus {
        case .cached: return "Saved"
        case .partial: return "Partially saved"
        case .fetching: return "Saving"
        case .pending: return "Not saved"
        case .failed: return "Save failed"
        }
    }

    // MARK: - Accessibility

    private var rowAccessibilityLabel: String {
        var parts: [String] = [article.title]

        if let published = article.publishedAt {
            parts.append(RelativeTimeFormatter.string(from: published))
        }

        parts.append(article.isRead ? "Read" : "Unread")
        parts.append(cacheStatusAccessibilityLabel)

        return parts.joined(separator: ", ")
    }

    // MARK: - New article border

    @ViewBuilder
    private var newArticleBorder: some View {
        let isNew: Bool = {
            guard let published = article.publishedAt else { return false }
            return appearTime.timeIntervalSince(published) < 60
        }()

        if isNew {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.accentGradient)
                .frame(width: 2)
                .opacity(max(0, 1.0 - appearTime.timeIntervalSince(article.publishedAt ?? appearTime) / 60.0))
        }
    }
}
