import SwiftUI
import GRDB
import Network

struct ArticleListView: View {
    let source: Source

    @Namespace private var namespace
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var articles: [Article] = []
    @State private var filter: ArticleFilter = .all
    @State private var isLoading = true
    @State private var failedArticle: Article?
    @State private var showFailedSheet = false
    @State private var isLoadingMore = false
    @State private var feedExhausted = false
    @State private var cacheRingRotation: Double = 0
    @State private var selectedArticle: Article?
    @State private var showSourceSettings = false
    @State private var currentCacheLevel: CacheLevel = .standard
    @State private var currentFetchFrequency: FetchFrequency = .automatic
    @State private var hasInitializedSettings = false

    private let articleLimit = 50

    private enum ArticleFilter: String, CaseIterable {
        case all = "All"
        case saved = "Saved"
        case unread = "Unread"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoading {
                skeletonRows
            } else {
                VStack(spacing: 0) {
                    filterBar
                        .padding(.bottom, 4)

                    TabView(selection: $filter) {
                        tabContent(for: .all)
                            .tag(ArticleFilter.all)
                        tabContent(for: .saved)
                            .tag(ArticleFilter.saved)
                        tabContent(for: .unread)
                            .tag(ArticleFilter.unread)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    sourceFavicon
                    Text(source.title)
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        showSourceSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                    }
                    navCacheRing
                }
            }
        }
        .task {
            if !hasInitializedSettings {
                currentCacheLevel = source.cacheLevel ?? .standard
                currentFetchFrequency = source.fetchFrequency
                hasInitializedSettings = true
            }
            await loadArticles()
            isLoading = false

            // Handle article deep link — auto-select after load
            if let articleID = deepLinkRouter.pendingArticleID,
               let article = articles.first(where: { $0.id == articleID }) {
                selectedArticle = article
                deepLinkRouter.pendingArticleID = nil
            }
        }
        .onChange(of: coordinator.sourceStatuses[source.id]) { _, newState in
            if newState == .completed || newState == .idle {
                Task { await loadArticles() }
            }
        }
        .sheet(isPresented: $showFailedSheet) {
            if let article = failedArticle {
                FailedArticleSheet(
                    article: article,
                    onRetry: {
                        Task { await refetchArticle(article) }
                    },
                    onRemove: {
                        Task { await deleteArticle(article) }
                    }
                )
            }
        }
        .sheet(isPresented: $showSourceSettings) {
            sourceSettingsSheet
        }
        .navigationDestination(item: $selectedArticle) { article in
            ReaderView(article: article, namespace: namespace)
        }
    }

    // MARK: - Filtered articles

    private func articlesForFilter(_ tab: ArticleFilter) -> [Article] {
        switch tab {
        case .all:
            return articles
        case .saved:
            return articles.filter { $0.isSaved }
        case .unread:
            return articles.filter { !$0.isRead }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(for tab: ArticleFilter) -> some View {
        let items = articlesForFilter(tab)
        if items.isEmpty {
            emptyState(for: tab)
        } else {
            List {
                ForEach(items) { article in
                    ArticleRowView(
                        article: article,
                        namespace: namespace,
                        onTap: { handleTap(article) },
                        onToggleRead: { Task { await toggleRead(article) } },
                        onToggleSave: { Task { await toggleSave(article) } },
                        onRefetch: { Task { await refetchArticle(article) } },
                        onDelete: { Task { await deleteArticle(article) } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }

                if tab == .all {
                    loadMoreRow
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 24) {
            ForEach(ArticleFilter.allCases, id: \.self) { filterOption in
                Button {
                    filter = filterOption
                } label: {
                    VStack(spacing: 6) {
                        Text(filterOption.rawValue)
                            .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                            .foregroundColor(filter == filterOption ? Theme.teal : Theme.textSecondary)

                        Rectangle()
                            .fill(filter == filterOption ? Theme.teal : Color.clear)
                            .frame(height: 2)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: filter)
    }

    // MARK: - Nav cache ring

    private var navCacheRing: some View {
        let isRefreshing = coordinator.sourceStatuses[source.id] == .refreshing
        return ZStack {
            Circle()
                .stroke(Theme.borderProminent, lineWidth: 2)
                .frame(width: 20, height: 20)

            if isRefreshing {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.teal, Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(cacheRingRotation))
                    .onAppear {
                        cacheRingRotation = 0
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            cacheRingRotation = 360
                        }
                    }
            }
        }
    }

    // MARK: - Source favicon

    @ViewBuilder
    private var sourceFavicon: some View {
        if let iconURL = source.iconURL, let url = URL(string: iconURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                default:
                    smallLetterAvatar
                }
            }
            .frame(width: 24, height: 24)
        } else {
            smallLetterAvatar
        }
    }

    private var smallLetterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 24, height: 24)
            Text(letter)
                .font(Theme.scaledFont(size: 12, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Skeleton loading

    private var skeletonRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRow()
            }
        }
        .padding(.top, 80)
    }

    // MARK: - Empty states

    @ViewBuilder
    private func emptyState(for tab: ArticleFilter) -> some View {
        VStack(spacing: 16) {
            Spacer()

            switch tab {
            case .all:
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(Theme.textSecondary)
                Text("Nothing here yet...")
                    .font(Theme.scaledFont(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Articles will appear once the source is refreshed.")
                    .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)

            case .saved:
                Image(systemName: "tray")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(Theme.textSecondary)
                Text("No saved articles yet...")
                    .font(Theme.scaledFont(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Saved articles will show up here.")
                    .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)

            case .unread:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
                Text("You're all caught up.")
                    .font(Theme.scaledFont(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Load more row

    @ViewBuilder
    private var loadMoreRow: some View {
        if feedExhausted {
            HStack {
                Spacer()
                Text("That's everything in the feed.")
                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 20)
        } else if articles.count >= articleLimit {
            HStack {
                Spacer()
                Text("Showing the latest \(articles.count). Change in Settings.")
                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 20)
        } else if !articles.isEmpty {
            Button {
                Task { await loadMoreArticles() }
            } label: {
                VStack(spacing: 4) {
                    if isLoadingMore {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(Theme.textSecondary)
                            Text("Loading...")
                                .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                                .foregroundColor(Theme.textSecondary)
                        }
                    } else {
                        Text("Load 20 more articles")
                            .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                            .foregroundColor(Theme.accent)
                        Text("Preread will fetch and save them in the background.")
                            .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .disabled(isLoadingMore)
        }
    }

    // MARK: - Actions

    private func handleTap(_ article: Article) {
        switch article.fetchStatus {
        case .cached, .partial:
            selectedArticle = article
        case .failed:
            failedArticle = article
            showFailedSheet = true
        default:
            // Check connectivity for uncached articles
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "connectivity")
            monitor.start(queue: queue)
            let path = monitor.currentPath
            monitor.cancel()

            if path.status != .satisfied {
                ToastManager.shared.show("You're offline. This article hasn't been saved yet.", type: .error)
            } else {
                // Could trigger fetch, for now show toast
                ToastManager.shared.show("This article is still being saved...", type: .info)
            }
        }
    }

    private func toggleRead(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isRead.toggle()
        let updatedArticle = articles[index]
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updatedArticle.update(db)
            }
        } catch {
            articles[index].isRead.toggle()
        }
    }

    private func toggleSave(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isSaved.toggle()
        let updatedArticle = articles[index]
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updatedArticle.update(db)
            }
        } catch {
            articles[index].isSaved.toggle()
        }
    }

    private func refetchArticle(_ article: Article) async {
        let cacheLevel = source.effectiveCacheLevel
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
        await loadArticles()
    }

    private func deleteArticle(_ article: Article) async {
        HapticManager.deleteConfirm()
        try? await PageCacheService.shared.deleteCachedArticle(article.id)
        do {
            _ = try await DatabaseManager.shared.dbPool.write { db in
                try Article.deleteOne(db, key: article.id)
            }
            withAnimation(Theme.gentleAnimation()) {
                articles.removeAll { $0.id == article.id }
            }
        } catch {
            // Deletion failed silently
        }
    }

    // MARK: - Source settings sheet

    private var sourceSettingsSheet: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Check for new articles
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CHECK FOR NEW ARTICLES")
                                .font(Theme.scaledFont(size: 12, weight: .semibold, relativeTo: .caption))
                                .foregroundColor(Theme.textSecondary)

                            HStack(spacing: 8) {
                                frequencyOption(.automatic, title: "Auto", subtitle: "Periodically")
                                frequencyOption(.onOpen, title: "On open", subtitle: "When you launch")
                                frequencyOption(.manual, title: "Manual", subtitle: "Only when asked")
                            }
                        }

                        // Save quality
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SAVE QUALITY")
                                .font(Theme.scaledFont(size: 12, weight: .semibold, relativeTo: .caption))
                                .foregroundColor(Theme.textSecondary)

                            CacheFidelitySlider(selectedLevel: $currentCacheLevel)
                                .padding(.horizontal, 4)

                            Text("Applies to articles fetched from now on. Existing saved articles are not affected.")
                                .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                                .foregroundColor(Theme.textSecondary)
                        }

                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Source Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showSourceSettings = false
                    }
                    .foregroundColor(Theme.accent)
                }
            }
        }
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
        .onChange(of: currentCacheLevel) { _, newLevel in
            Task { await updateSourceCacheLevel(newLevel) }
        }
        .onChange(of: currentFetchFrequency) { _, newFrequency in
            Task { await updateSourceFetchFrequency(newFrequency) }
        }
    }

    private func frequencyOption(_ frequency: FetchFrequency, title: String, subtitle: String) -> some View {
        let isSelected = currentFetchFrequency == frequency
        return Button {
            currentFetchFrequency = frequency
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(Theme.scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundColor(isSelected ? .white : Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.scaledFont(size: 11, relativeTo: .caption))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Theme.border, lineWidth: 1)
            )
        }
    }

    private func updateSourceFetchFrequency(_ frequency: FetchFrequency) async {
        var updated = source
        updated.fetchFrequency = frequency
        try? await DatabaseManager.shared.dbPool.write { db in
            try updated.update(db)
        }
    }

    private func updateSourceCacheLevel(_ level: CacheLevel) async {
        var updated = source
        updated.cacheLevel = level
        try? await DatabaseManager.shared.dbPool.write { db in
            try updated.update(db)
        }
    }

    // MARK: - Data loading

    private func loadArticles() async {
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .order(Column("publishedAt").desc)
                    .limit(articleLimit)
                    .fetchAll(db)
            }
            articles = loaded
        } catch {
            // Keep existing articles
        }
    }

    private func loadMoreArticles() async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        // Re-fetch feed to get more articles
        do {
            guard let feedURL = URL(string: source.feedURL) else { return }
            let feed = try await FeedService.shared.parseFeed(
                from: feedURL,
                siteURL: source.siteURL.flatMap { URL(string: $0) }
            )

            let newCount = try await DatabaseManager.shared.dbPool.write { db -> Int in
                var inserted = 0
                for item in feed.items {
                    let exists = try Article
                        .filter(Column("articleURL") == item.url.absoluteString)
                        .fetchCount(db) > 0
                    guard !exists else { continue }

                    let article = Article(
                        id: UUID(),
                        sourceID: source.id,
                        title: item.title,
                        articleURL: item.url.absoluteString,
                        publishedAt: item.publishedAt,
                        thumbnailURL: item.thumbnailURL?.absoluteString,
                        cachedAt: nil,
                        fetchStatus: .pending,
                        isRead: false,
                        isSaved: false,
                        cacheSizeBytes: nil,
                        lastHTTPStatus: nil,
                        etag: nil,
                        lastModified: nil
                    )
                    try article.save(db)
                    inserted += 1
                }
                return inserted
            }

            if newCount == 0 {
                feedExhausted = true
            }

            await loadArticles()

            // Cache new articles in background
            let cacheLevel = source.effectiveCacheLevel
            let pending = articles.filter { $0.fetchStatus == .pending }
            Task {
                for article in pending.prefix(20) {
                    try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                }
                await loadArticles()
            }
        } catch {
            ToastManager.shared.show("Couldn't load more articles", type: .error)
        }
    }
}

// MARK: - Skeleton row

private struct SkeletonRow: View {
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surfaceRaised)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.surfaceRaised)
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.surfaceRaised)
                    .frame(width: 120, height: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Theme.reduceMotion ? nil : shimmerOverlay)
        .onAppear { if !Theme.reduceMotion { startShimmer() } }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Theme.borderProminent.opacity(0),
                    Theme.borderProminent.opacity(0.5),
                    Theme.borderProminent.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 100)
            .rotationEffect(.degrees(25))
            .offset(x: shimmerOffset)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func startShimmer() {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            shimmerOffset = 400
        }
    }
}
