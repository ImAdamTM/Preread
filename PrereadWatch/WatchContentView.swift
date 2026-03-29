import SwiftUI
import WatchConnectivity

/// Watch companion app showing latest articles as full-screen paging cards.
/// Digital Crown scrolls between articles; tap opens detail view with excerpt.
struct WatchContentView: View {
    @State private var articles: [WatchArticle] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if articles.isEmpty {
                emptyState
            } else {
                articlePager
            }
        }
        .onAppear {
            articles = WatchDataStore.loadArticles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchArticlesDidUpdate)) { _ in
            articles = WatchDataStore.loadArticles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                articles = WatchDataStore.loadArticles()
                requestFreshArticles()
            }
        }
    }

    /// Asks the iPhone to push fresh article data.
    /// Uses sendMessage which works reliably when both devices are active.
    private func requestFreshArticles() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["action": "requestArticles"], replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Pager

    private var articlePager: some View {
        NavigationStack {
            TabView {
                ForEach(articles) { article in
                    NavigationLink {
                        WatchArticleDetailView(article: article)
                    } label: {
                        articleCardLabel(article)
                    }
                    .buttonStyle(.plain)
                    .containerBackground(for: .tabView) {
                        articleCardBackground(article)
                    }
                }
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle("")
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Card

    /// Full-bleed background: thumbnail or gradient + dark overlay for legibility.
    /// Placed in `.containerBackground(for: .tabView)` so it fills the entire screen.
    @ViewBuilder
    private func articleCardBackground(_ article: WatchArticle) -> some View {
        GeometryReader { geo in
            ZStack {
                if let data = article.thumbnailData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: gradientColors(for: article.sourceName),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                // Gradient overlay for text legibility
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.2), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.7), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    /// Foreground text overlay: source pill at top, title + time at bottom.
    /// Respects safe area so text stays readable.
    private func articleCardLabel(_ article: WatchArticle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(article.sourceName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }

            Spacer()

            Text(article.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

            if let published = article.publishedAt {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(RelativeTimeFormatter.string(from: published))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                }
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No articles yet")
                .font(.headline)
            Text("Open Preread on iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Gradient colors

private func gradientColors(for title: String) -> [Color] {
    let pairs: [(Color, Color)] = [
        (Color(red: 0.42, green: 0.42, blue: 0.94), Color(red: 0.66, green: 0.33, blue: 0.97)),
        (Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 0.42, green: 0.42, blue: 0.94)),
        (Color(red: 0.20, green: 0.83, blue: 0.60), Color(red: 0.13, green: 0.83, blue: 0.93)),
        (Color(red: 0.91, green: 0.63, blue: 0.13), Color(red: 0.97, green: 0.44, blue: 0.44)),
        (Color(red: 0.66, green: 0.33, blue: 0.97), Color(red: 0.97, green: 0.44, blue: 0.44)),
        (Color(red: 0.36, green: 0.36, blue: 0.87), Color(red: 0.20, green: 0.83, blue: 0.60)),
    ]
    let hash = title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
    let index = abs(hash) % pairs.count
    return [pairs[index].0, pairs[index].1]
}
