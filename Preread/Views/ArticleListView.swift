import SwiftUI
import GRDB

struct ArticleListView: View {
    let source: Source

    @Namespace private var namespace
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var articles: [Article] = []
    @State private var isLoading = true
    @State private var failedArticle: Article?
    @State private var isLoadingMore = false
    @State private var feedExhausted = false
    @State private var selectedArticle: Article?
    @State private var showSourceSettings = false
    @State private var currentCacheLevel: CacheLevel = .standard
    @State private var currentFetchFrequency: FetchFrequency = .automatic
    @State private var currentSourceName: String = ""
    @State private var hasInitializedSettings = false
    @State private var heroTitleMinY: CGFloat = 200
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private let articleLimit = 50

    private var preferredScheme: ColorScheme {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme
        }
    }

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
                    Text(currentSourceName)
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                .opacity(navBarTitleOpacity)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.textPrimary)
                }
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

            // Retry any pending/failed articles in the background
            let retrySource = currentSource
            Task {
                await coordinator.retryFailedArticles(for: retrySource)
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
        .sheet(item: $failedArticle) { article in
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
        .sheet(isPresented: $showSourceSettings, onDismiss: {
            let trimmed = currentSourceName.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed != source.title {
                Task { await updateSourceName(trimmed) }
            } else if trimmed.isEmpty {
                currentSourceName = source.title
            }
        }) {
            sourceSettingsSheet
        }
        .sheet(item: $selectedArticle) { article in
            NavigationStack {
                ReaderView(article: article, source: source)
            }
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(preferredScheme)
        }
    }

    // MARK: - Article list

    private var articleList: some View {
        List {
            // Hero section
            heroRow
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .buttonStyle(.borderless)

            if articles.isEmpty {
                emptyStateContent
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                loadMoreRow
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Hero row

    private var displaySource: Source {
        var s = source
        s.title = currentSourceName
        return s
    }

    private var heroRow: some View {
        SourceHeroView(
            source: displaySource,
            isRefreshing: coordinator.sourceStatuses[source.id] == .refreshing,
            onSettingsTapped: { showSourceSettings = true },
            onRefreshTapped: {
                Task { await FetchCoordinator.shared.refreshSingleSource(currentSource) }
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

    private func markAsReadLocally(_ article: Article) {
        guard !article.isRead, let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isRead = true
        let updated = articles[index]
        Task {
            try? await DatabaseManager.shared.dbPool.write { db in
                try updated.update(db)
            }
        }
    }

    private func handleTap(_ article: Article) {
        Task {
            // Re-read the article's current status from the DB in case
            // the local array is stale (e.g. background retry just finished).
            let current: Article
            if let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
                try Article.fetchOne(db, key: article.id)
            }) {
                current = fresh
                // Update the local array so the row reflects the latest state
                if let index = articles.firstIndex(where: { $0.id == article.id }) {
                    articles[index] = fresh
                }
            } else {
                current = article
            }

            switch current.fetchStatus {
            case .cached, .partial:
                let hasCachedContent = await checkCachedContentExists(for: current)
                if hasCachedContent {
                    markAsReadLocally(current)
                    selectedArticle = current
                } else {
                    await fetchArticleInline(current, openOnSuccess: true)
                }
            case .pending:
                await fetchArticleInline(current, openOnSuccess: true)
            case .fetching:
                break
            case .failed:
                failedArticle = current
            }
        }
    }

    private func checkCachedContentExists(for article: Article) async -> Bool {
        await PageCacheService.shared.hasCachedContent(for: article)
    }

    private func fetchArticleInline(_ article: Article, openOnSuccess: Bool = false) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            articles[index].fetchStatus = .fetching
        }

        // Clear stale conditional headers so we get a fresh response
        // (e.g. after cache wipe, the file is gone but etag/lastModified remain)
        var articleToCache = article
        if articleToCache.etag != nil || articleToCache.lastModified != nil {
            articleToCache.etag = nil
            articleToCache.lastModified = nil
            try? await DatabaseManager.shared.dbPool.write { db in
                try articleToCache.update(db)
            }
        }

        let cacheLevel = currentCacheLevel
        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel)
        await loadArticles()

        if let updatedIndex = articles.firstIndex(where: { $0.id == article.id }) {
            let updated = articles[updatedIndex]
            if updated.fetchStatus == .failed {
                failedArticle = updated
            } else if openOnSuccess, updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                markAsReadLocally(updated)
                selectedArticle = updated
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
        let nowSaved = articles[index].isSaved
        let updatedArticle = articles[index]
        HapticManager.articleCached()
        ToastManager.shared.snack(
            nowSaved ? "Saved" : "Unsaved",
            icon: nowSaved ? "bookmark.fill" : "bookmark.slash"
        )
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
        let cacheLevel = currentCacheLevel
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

    /// Builds a source with all current local state applied, so updates don't overwrite each other.
    private var currentSource: Source {
        var s = source
        s.title = currentSourceName.trimmingCharacters(in: .whitespaces).isEmpty ? source.title : currentSourceName
        s.fetchFrequency = currentFetchFrequency
        s.cacheLevel = currentCacheLevel
        return s
    }

    private func updateSourceName(_ name: String) async {
        var updated = currentSource
        updated.title = name
        try? await DatabaseManager.shared.dbPool.write { db in
            try updated.update(db)
        }
    }

    private func updateSourceFetchFrequency(_ frequency: FetchFrequency) async {
        var updated = currentSource
        updated.fetchFrequency = frequency
        try? await DatabaseManager.shared.dbPool.write { db in
            try updated.update(db)
        }
    }

    private func updateSourceCacheLevel(_ level: CacheLevel) async {
        var updated = currentSource
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
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
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

            // Sort feed items newest-first so we insert in chronological order,
            // matching the display sort. Items without a date go last.
            let sortedItems = feed.items.sorted {
                ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }

            // Insert up to 10 more articles that aren't already in the DB
            let newArticles = try await FetchCoordinator.shared.insertNewArticles(
                from: sortedItems,
                sourceID: source.id,
                limit: 10
            )

            if newArticles.isEmpty {
                feedExhausted = true
            }

            // Cache newly inserted articles before showing them,
            // processing newest-first so the list updates in order.
            if !newArticles.isEmpty {
                let cacheLevel = currentCacheLevel
                let sorted = newArticles.sorted {
                    ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                }
                for (index, article) in sorted.enumerated() {
                    try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                    // Refresh the list periodically so the user sees progress
                    if (index + 1) % 5 == 0 || index == sorted.count - 1 {
                        await loadArticles()
                    }
                    if index < sorted.count - 1 {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }

            await loadArticles()
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
