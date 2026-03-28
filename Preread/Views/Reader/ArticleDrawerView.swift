import SwiftUI
import GRDB

/// A compact bottom sheet showing sibling articles from the same source (or all saved articles),
/// allowing the user to jump between articles without closing the reader.
struct ArticleDrawerView: View {
    let currentArticleID: UUID
    let sourceID: UUID
    let sourceName: String
    let isSavedContext: Bool
    let onSelectArticle: (Article) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var articles: [Article] = []
    @State private var thumbnailImages: [UUID: UIImage] = [:]
    @State private var faviconImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(articles) { article in
                        Button {
                            guard article.id != currentArticleID else {
                                dismiss()
                                return
                            }
                            onSelectArticle(article)
                        } label: {
                            drawerRow(article: article)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            article.id == currentArticleID
                                ? Theme.accent.opacity(0.15)
                                : Color.clear
                        )
                        .id(article.id)
                    }
                }
                .listStyle(.plain)
                .task {
                    await loadFavicon()
                    await loadArticles()
                    await prewarmThumbnails()

                    // Scroll to the current article after a brief layout pass
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation {
                        proxy.scrollTo(currentArticleID, anchor: .center)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        drawerFaviconView
                        Text(isSavedContext ? "Saved Articles" : sourceName)
                            .font(Theme.scaledFont(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheetBackground)
    }

    // MARK: - Row

    private func drawerRow(article: Article) -> some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let image = thumbnailImages[article.id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.textSecondary.opacity(0.1))
                    .frame(width: 52, height: 52)
            }

            // Title + metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(Theme.scaledFont(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let minutes = article.readingMinutes, minutes > 0 {
                        Text("\(minutes) min")
                            .font(Theme.scaledFont(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    let date = article.publishedAt ?? article.addedAt
                    Text(RelativeTimeFormatter.string(from: date))
                        .font(Theme.scaledFont(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 4)

            // Read/unread dot on the right (matches ArticleRowView)
            ZStack {
                Color.clear
                Circle()
                    .fill(article.isRead ? Theme.textSecondary.opacity(0.2) : Theme.accent)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 24)
        }
        .padding(.leading, 20)
        .padding(.trailing, 15)
        .padding(.vertical, 14)
        .frame(minHeight: 96)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Theme.borderProminent
                .frame(height: 0.5)
        }
    }

    // MARK: - Favicon

    @ViewBuilder
    private var drawerFaviconView: some View {
        if let favicon = faviconImage {
            Image(uiImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .background(Theme.faviconBackground, in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            let name = isSavedContext ? "Saved" : sourceName
            let letter = String(name.prefix(1)).uppercased()
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.avatarGradient(for: name))
                    .frame(width: 20, height: 20)
                Text(letter)
                    .font(Theme.scaledFont(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

    private func loadFavicon() async {
        let sid = sourceID
        if let cached = await Task.detached(priority: .utility, operation: {
            await PageCacheService.shared.cachedFavicon(for: sid)
        }).value {
            faviconImage = cached
        }
    }

    // MARK: - Data

    private func loadArticles() async {
        do {
            articles = try await DatabaseManager.shared.dbPool.read { db in
                let cachedStatuses = [ArticleFetchStatus.cached.rawValue,
                                      ArticleFetchStatus.partial.rawValue]
                if isSavedContext {
                    return try Article
                        .filter(Column("isSaved") == true)
                        .filter(cachedStatuses.contains(Column("fetchStatus")))
                        .order(
                            Column("savedAt").desc,
                            Column("addedAt").desc
                        )
                        .fetchAll(db)
                } else {
                    return try Article
                        .filter(Column("sourceID") == sourceID)
                        .filter(cachedStatuses.contains(Column("fetchStatus")))
                        .order(
                            sql: "COALESCE(publishedAt, addedAt) DESC"
                        )
                        .fetchAll(db)
                }
            }
        } catch {
            articles = []
        }
    }

    private func prewarmThumbnails() async {
        await ThumbnailCache.prewarmRowThumbnails(for: articles)
        // Pull cached images into local state for display
        var images: [UUID: UIImage] = [:]
        for article in articles {
            if let cached = ThumbnailCache.shared.rowThumbnail(for: article.id) {
                images[article.id] = cached.image
            }
        }
        thumbnailImages = images
    }
}
