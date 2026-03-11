import SwiftUI
import GRDB

struct ArticleListView: View {
    let source: Source

    @Namespace private var namespace
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var detailCoordinator = ArticleDetailCoordinator.shared
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var articles: [Article] = []
    @State private var isLoading = true
    @State private var failedArticle: Article?
    @State private var isLoadingMore = false
    @State private var feedExhausted = false
    @State private var selectedArticle: Article?
    @State private var transitionSourceID: String?
    @State private var showSourceSettings = false
    @State private var currentCacheLevel: CacheLevel = .standard
    @State private var currentFetchFrequency: FetchFrequency = .automatic
    @State private var currentSourceName: String = ""
    @State private var hasInitializedSettings = false
    @State private var heroTitleMinY: CGFloat = 200
    @AppStorage("appAppearance") private var appAppearance: String = "system"
    @State private var navFaviconImage: UIImage?
    @AppStorage("articleLimit") private var articleLimit: Int = 25
    @State private var searchText = ""
    @State private var lastFetchedAt: Date?
    @State private var articleObservation: AnyDatabaseCancellable?

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
                        .font(Theme.scaledFont(size: 17, weight: .medium))
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
                lastFetchedAt = source.lastFetchedAt
                hasInitializedSettings = true
            }
            await loadArticles()
            isLoading = false

            // Observe article changes reactively instead of polling.
            // ValueObservation fires whenever articles for this source
            // are inserted, updated, or deleted in the database.
            startArticleObservation()

            // Retry any pending/failed articles in the background
            let retrySource = currentSource
            Task {
                await coordinator.retryFailedArticles(for: retrySource)
            }
        }
        .onAppear {
            // If the source was deleted (e.g. from Settings while this view
            // was in the navigation stack), pop back to the sources list.
            Task {
                let exists = try? await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: source.id) != nil
                }
                if exists == false {
                    dismiss()
                }
            }
        }
        .onChange(of: coordinator.sourceStatuses[source.id]) { _, newState in
            if newState == .completed || newState == .idle {
                Task {
                    await reloadSourceFromDB()
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
            .navigationTransition(.zoom(sourceID: transitionSourceID ?? "row-\(article.id)", in: namespace))
            .toastOverlay()
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
                .zIndex(-1)

            // Per-source carousel
            if !articles.isEmpty {
                SourceCarouselView(
                    sourceID: source.id,
                    cacheLevel: currentCacheLevel,
                    transitionNamespace: namespace,
                    onOpenArticle: { article in
                        markAsReadLocally(article)
                        transitionSourceID = "source-carousel-\(article.id)"
                        presentArticle(article)
                    }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if articles.isEmpty {
                emptyStateContent
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Text("All articles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(filteredArticles) { article in
                    ArticleRowView(
                        article: article,
                        namespace: namespace,
                        onTap: { transitionSourceID = "row-\(article.id)"; handleTap(article) },
                        onToggleRead: { Task { await toggleRead(article) } },
                        onToggleSave: { Task { await toggleSave(article) } },
                        onRefetch: { Task { await refetchArticle(article) } },
                        onDelete: { Task { await deleteArticle(article) } },
                        sourceName: source.isTopicFeed ? article.displayDomain : nil
                    )
                    .matchedTransitionSource(id: "row-\(article.id)", in: namespace) {
                        $0.clipShape(RoundedRectangle(cornerRadius: 12))
                            .background(Theme.background)
                    }
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
        .searchable(text: $searchText, prompt: "Search articles")
    }

    // MARK: - Hero row

    private var displaySource: Source {
        var s = source
        s.title = currentSourceName
        s.lastFetchedAt = lastFetchedAt ?? source.lastFetchedAt
        return s
    }

    private var heroRow: some View {
        SourceHeroView(
            source: displaySource,
            isRefreshing: coordinator.sourceStatuses[source.id] == .refreshing,
            articleCount: articles.count,
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

    // MARK: - Search filtering

    private var filteredArticles: [Article] {
        let visible = articles.filter { $0.fetchStatus != .failed }
        if searchText.isEmpty { return visible }
        return visible.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Source favicon

    @ViewBuilder
    private var sourceFavicon: some View {
        if let favicon = navFaviconImage {
            Image(uiImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            smallLetterAvatar
                .task {
                    let sourceID = source.id
                    if let cached = await Task.detached(priority: .utility, operation: {
                        await PageCacheService.shared.cachedFavicon(for: sourceID)
                    }).value {
                        navFaviconImage = cached
                    }
                }
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
                Group {
                    if isLoadingMore {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Loading...")
                                .font(Theme.scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline))
                                .foregroundColor(.white)
                        }
                    } else {
                        Text("Load more articles")
                            .font(Theme.scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Theme.accentGradient)
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
            }
            .disabled(isLoadingMore)
            .padding(.vertical, 16)
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

    private func presentArticle(_ article: Article) {
        if detailCoordinator.isSplitView {
            detailCoordinator.selection = ReaderSelection(
                article: article, source: source
            )
        } else {
            selectedArticle = article
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
                    presentArticle(current)
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

        // Always reconcile local state with DB so the spinner never stays stuck
        if let updated = try? await DatabaseManager.shared.dbPool.read({ db in
            try Article.fetchOne(db, key: article.id)
        }) {
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                articles[index] = updated
            }
            if updated.fetchStatus == .failed {
                failedArticle = updated
            } else if openOnSuccess, updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                markAsReadLocally(updated)
                presentArticle(updated)
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
        articles[index].savedAt = nowSaved ? Date() : nil
        if nowSaved {
            articles[index].originalSourceName = source.title
            articles[index].originalSourceIconURL = source.iconURL
        } else {
            articles[index].originalSourceName = nil
            articles[index].originalSourceIconURL = nil
        }
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
            coordinator.savedArticlesVersion += 1
        } catch {
            articles[index].isSaved.toggle()
            articles[index].savedAt = articles[index].isSaved ? Date() : nil
        }
    }

    private func refetchArticle(_ article: Article) async {
        var article = article
        article.retryCount = 0
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles[index].retryCount = 0
            withAnimation(.easeInOut(duration: 0.2)) {
                articles[index].fetchStatus = .fetching
            }
        }
        let cacheLevel = currentCacheLevel
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel, forceReprocess: true)
        // Reconcile local state with DB so the spinner never stays stuck
        if let index = articles.firstIndex(where: { $0.id == article.id }),
           articles[index].fetchStatus == .fetching,
           let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
               try Article.fetchOne(db, key: article.id)
           }) {
            articles[index] = fresh
        }
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
                Theme.sheetBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Source Settings")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundColor(Theme.textPrimary)

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
                        }

                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }
            }
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
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheetBackground)
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
            VStack(spacing: 2) {
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

    /// Starts a GRDB ValueObservation that reactively updates articles
    /// whenever the database changes, replacing the old 1-second polling loop.
    private func startArticleObservation() {
        let sourceID = source.id
        let limit = articleLimit
        let observation = ValueObservation.tracking { db in
            try Article
                .filter(Column("sourceID") == sourceID)
                .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                .limit(limit)
                .fetchAll(db)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { error in
            // Observation failed — keep existing articles
        } onChange: { newArticles in
            articles = newArticles
        }
    }

    /// Re-reads the source from the database to pick up changes like lastFetchedAt.
    private func reloadSourceFromDB() async {
        guard let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
            try Source.fetchOne(db, key: source.id)
        }) else { return }
        currentSourceName = fresh.title
        currentCacheLevel = fresh.cacheLevel ?? .standard
        currentFetchFrequency = fresh.fetchFrequency
        lastFetchedAt = fresh.lastFetchedAt
    }

    private func loadArticles() async {
        let limit = articleLimit
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(limit)
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
                    if index < sorted.count - 1 {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } catch {
            ToastManager.shared.show("Couldn't load more articles", type: .error)
        }
    }
}

// MARK: - Skeleton row

private struct SkeletonRow: View {
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
    }
}
