import SwiftUI
import GRDB

struct ArticleListView: View {
    let source: Source

    @Namespace private var namespace
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var articles: [Article] = []
    @State private var isLoading = true
    @State private var failedArticle: Article?
    @State private var showFailedSheet = false
    @State private var isLoadingMore = false
    @State private var feedExhausted = false
    @State private var selectedArticle: Article?
    @State private var showSourceSettings = false
    @State private var currentCacheLevel: CacheLevel = .standard
    @State private var currentFetchFrequency: FetchFrequency = .automatic
    @State private var currentSourceName: String = ""
    @State private var hasInitializedSettings = false
    @State private var heroTitleMinY: CGFloat = 200

    private let articleLimit = 50



    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            if isLoading {
                skeletonRows
            } else {
                articleList
            }

        }
        .toolbarBackground(navBarBackgroundOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
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
                .opacity(navBarTitleOpacity)
            }
        }
        .task {
            if !hasInitializedSettings {
                currentCacheLevel = source.cacheLevel ?? .standard
                currentFetchFrequency = source.fetchFrequency
                currentSourceName = source.title
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
            } else if newState == .refreshing {
                // Poll for article status changes while refreshing
                Task {
                    while coordinator.sourceStatuses[source.id] == .refreshing {
                        try? await Task.sleep(for: .seconds(1))
                        guard coordinator.sourceStatuses[source.id] == .refreshing else { break }
                        await loadArticles()
                    }
                }
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

    // MARK: - Article list

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Hero section
                heroRow

                if articles.isEmpty {
                    emptyStateContent
                } else {
                    ForEach(articles) { article in
                        ArticleRowView(
                            article: article,
                            namespace: namespace,
                            onTap: { handleTap(article) },
                            onToggleRead: { Task { await toggleRead(article) } },
                            onToggleSave: { Task { await toggleSave(article) } },
                            onRefetch: { Task { await refetchArticle(article) } },
                            onDelete: { Task { await deleteArticle(article) } }
                        )
                    }

                    loadMoreRow
                }
            }
        }
        .scrollClipDisabled()
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Hero row

    private var heroRow: some View {
        SourceHeroView(
            source: source,
            isRefreshing: coordinator.sourceStatuses[source.id] == .refreshing,
            onSettingsTapped: { showSourceSettings = true },
            onRefreshTapped: {
                Task { await FetchCoordinator.shared.refreshSingleSource(source) }
            },
            onTitlePositionChange: { heroTitleMinY = $0 }
        )
    }

    // MARK: - Nav bar title opacity

    private var navBarTitleOpacity: Double {
        let startFade: CGFloat = 70
        let fullyVisible: CGFloat = 9
        if Theme.reduceMotion {
            return heroTitleMinY < 40 ? 1 : 0
        }
        if heroTitleMinY > startFade { return 0 }
        if heroTitleMinY < fullyVisible { return 1 }
        return Double(1 - (heroTitleMinY - fullyVisible) / (startFade - fullyVisible))
    }

    /// Nav bar blur material starts slightly before the title reaches the bar
    private var navBarBackgroundOpacity: Double {
        let startFade: CGFloat = 80
        let fullyOpaque: CGFloat = 9
        if Theme.reduceMotion {
            return heroTitleMinY < 50 ? 1 : 0
        }
        if heroTitleMinY > startFade { return 0 }
        if heroTitleMinY < fullyOpaque { return 1 }
        return Double(1 - (heroTitleMinY - fullyOpaque) / (startFade - fullyOpaque))
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

    // MARK: - Empty state

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 60)
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
                        Text("Load more articles")
                            .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                            .foregroundColor(Theme.accent)
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
        case .pending:
            Task { await fetchArticleInline(article) }
        case .fetching:
            // Already syncing — do nothing
            break
        case .failed:
            failedArticle = article
            showFailedSheet = true
        }
    }

    private func fetchArticleInline(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            articles[index].fetchStatus = .fetching
        }
        let cacheLevel = source.effectiveCacheLevel
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
        await loadArticles()
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
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                articles[index].fetchStatus = .fetching
            }
        }
        let cacheLevel = source.effectiveCacheLevel
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel, forceReprocess: true)
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
                        // Source name
                        VStack(alignment: .leading, spacing: 10) {
                            Text("NAME")
                                .font(Theme.scaledFont(size: 12, weight: .semibold, relativeTo: .caption))
                                .foregroundColor(Theme.textSecondary)

                            TextField("Source name", text: $currentSourceName)
                                .font(Theme.scaledFont(size: 15, relativeTo: .body))
                                .foregroundColor(Theme.textPrimary)
                                .padding(12)
                                .background(Theme.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Theme.border, lineWidth: 1)
                                )
                                .onSubmit {
                                    let trimmed = currentSourceName.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        Task { await updateSourceName(trimmed) }
                                    } else {
                                        currentSourceName = source.title
                                    }
                                }
                        }

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
        .presentationDetents([.fraction(0.6)])
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

    private func updateSourceName(_ name: String) async {
        var updated = source
        updated.title = name
        try? await DatabaseManager.shared.dbPool.write { db in
            try updated.update(db)
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

        do {
            guard let feedURL = URL(string: source.feedURL) else { return }
            let feed = try await FeedService.shared.parseFeed(
                from: feedURL,
                siteURL: source.siteURL.flatMap { URL(string: $0) }
            )

            // Insert up to 20 more articles that aren't already in the DB
            let newArticles = try await FetchCoordinator.shared.insertNewArticles(
                from: feed.items,
                sourceID: source.id,
                limit: 20
            )

            if newArticles.isEmpty {
                feedExhausted = true
            }

            await loadArticles()

            // Cache the newly inserted articles in background
            if !newArticles.isEmpty {
                let cacheLevel = source.effectiveCacheLevel
                Task {
                    for article in newArticles {
                        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                    }
                    await loadArticles()
                }
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
