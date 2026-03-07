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

                // Cache status dot
                cacheDot
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

    /// Checks for a locally cached thumbnail in the article's directory.
    private var localThumbnailURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let articleDir = appSupport.appendingPathComponent("preread/articles/\(article.id.uuidString)", isDirectory: true)
        let fm = FileManager.default
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "avif"] {
            let path = articleDir.appendingPathComponent("thumbnail.\(ext)")
            if fm.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    private var thumbnailView: some View {
        Group {
            if let localURL = localThumbnailURL,
               let data = try? Data(contentsOf: localURL),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let thumbURL = article.thumbnailURL, let url = URL(string: thumbURL) {
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
        }
    }

    private var gradientPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.avatarGradient(for: article.title))
            .frame(width: 56, height: 56)
    }

    // MARK: - Cache dot

    private var cacheDot: some View {
        Circle()
            .fill(cacheDotColor)
            .frame(width: 10, height: 10)
            .accessibilityLabel(cacheDotAccessibilityLabel)
    }

    private var cacheDotAccessibilityLabel: String {
        switch article.fetchStatus {
        case .cached: return "Saved"
        case .partial: return "Partially saved"
        case .fetching: return "Saving"
        case .pending: return "Not saved"
        case .failed: return "Save failed"
        }
    }

    private var cacheDotColor: Color {
        switch article.fetchStatus {
        case .cached:
            return Theme.success
        case .partial:
            return Theme.warning
        case .fetching:
            return Theme.teal
        case .pending:
            return Theme.textSecondary
        case .failed:
            return Theme.danger
        }
    }

    // MARK: - Accessibility

    private var rowAccessibilityLabel: String {
        var parts: [String] = [article.title]

        if let published = article.publishedAt {
            parts.append(RelativeTimeFormatter.string(from: published))
        }

        parts.append(article.isRead ? "Read" : "Unread")
        parts.append(cacheDotAccessibilityLabel)

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
