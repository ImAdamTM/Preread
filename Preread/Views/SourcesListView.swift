import SwiftUI
import GRDB

enum NavigationTarget: Hashable {
    case source(UUID)
    case saved
}

struct SourcesListView: View {
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var toastManager: ToastManager
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var sources: [Source] = []
    @State private var articleCounts: [UUID: Int] = [:]
    @State private var unreadCounts: [UUID: Int] = [:]
    @State private var savedCount: Int = 0
    @State private var savedUnreadCount: Int = 0
    @State private var showAddSource = false
    @State private var highlightedSourceID: UUID?
    @State private var navigationPath = NavigationPath()
    @State private var renamingSource: Source?
    @State private var renameText = ""
    @State private var countPollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Theme.background.ignoresSafeArea()

                if sources.isEmpty && savedCount == 0 {
                    emptyState
                } else {
                    sourcesList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    logomark
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showAddSource = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                        }

                        Button {
                            Task { await coordinator.refreshAllSources() }
                        } label: {
                            navRefreshButton
                        }
                        .disabled(coordinator.isFetching)

                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                }
            }
            .task {
                await loadSources()
            }
            .onChange(of: navigationPath) { _, path in
                // Refresh counts when navigating back (e.g. after reading articles)
                if path.isEmpty {
                    Task { await loadSources() }
                }
            }
            .refreshable {
                HapticManager.pullToRefresh()
                // Run in an unstructured Task so SwiftUI's pull-to-refresh
                // lifecycle doesn't cancel the refresh when the spinner dismisses.
                await Task {
                    await coordinator.refreshAllSources()
                }.value
                await loadSources()
            }
            .onChange(of: coordinator.isFetching) { _, isFetching in
                if !isFetching {
                    Task { await loadSources() }
                    checkForFailures()
                }
            }
            .onChange(of: coordinator.sourceStatuses) { _, statuses in
                let isAnyRefreshing = statuses.values.contains { $0 == .refreshing }
                let hasCompleted = statuses.values.contains { $0 == .completed }

                if isAnyRefreshing {
                    startCountPolling()
                } else {
                    stopCountPolling()
                }

                if hasCompleted {
                    Task { await loadSources() }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet(
                    onSourceAdded: { addedSourceID in
                        Task {
                            await loadSources()
                            highlightedSourceID = addedSourceID
                            try? await Task.sleep(for: .seconds(1))
                            highlightedSourceID = nil
                        }
                    },
                    onSavedArticle: {
                        Task {
                            await loadSources()
                            navigationPath.append(NavigationTarget.saved)
                        }
                    }
                )
            }
            .alert("Edit name", isPresented: Binding(
                get: { renamingSource != nil },
                set: { if !$0 { renamingSource = nil } }
            )) {
                TextField("Source name", text: $renameText)
                Button("Save") {
                    guard let source = renamingSource,
                          !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { await renameSource(source, to: renameText.trimmingCharacters(in: .whitespaces)) }
                    renamingSource = nil
                }
                Button("Cancel", role: .cancel) { renamingSource = nil }
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .source(let sourceID):
                    if let source = sources.first(where: { $0.id == sourceID }) {
                        ArticleListView(source: source)
                    }
                case .saved:
                    SavedArticlesView()
                }
            }
            .onChange(of: deepLinkRouter.pendingSourceID) { _, sourceID in
                guard let sourceID else { return }
                navigationPath = NavigationPath()
                navigationPath.append(NavigationTarget.source(sourceID))
                deepLinkRouter.pendingSourceID = nil
            }
            .onChange(of: deepLinkRouter.pendingArticleID) { _, articleID in
                guard let articleID else { return }
                Task {
                    // Look up the article's sourceID for back-stack navigation
                    guard let article = try? await DatabaseManager.shared.dbPool.read({ db in
                        try Article.fetchOne(db, key: articleID)
                    }) else {
                        // Invalid article ID — fail silently
                        deepLinkRouter.pendingArticleID = nil
                        return
                    }
                    navigationPath = NavigationPath()
                    navigationPath.append(NavigationTarget.source(article.sourceID))
                    // pendingArticleID stays set — ArticleListView picks it up
                }
            }
            .onChange(of: deepLinkRouter.pendingSavedNavigation) { _, shouldNavigate in
                guard shouldNavigate else { return }
                navigationPath = NavigationPath()
                navigationPath.append(NavigationTarget.saved)
                deepLinkRouter.pendingSavedNavigation = false
            }
        }
    }

    // MARK: - Sources list

    private var sourcesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if savedCount > 0 {
                    SavedCardView(
                        articleCount: savedCount,
                        unreadCount: savedUnreadCount,
                        onTap: {
                            navigationPath.append(NavigationTarget.saved)
                        }
                    )
                }

                ForEach(sources) { source in
                    let state = coordinator.sourceStatuses[source.id] ?? .idle

                    SourceCardView(
                        source: source,
                        articleCount: articleCounts[source.id] ?? 0,
                        unreadCount: unreadCounts[source.id] ?? 0,
                        refreshState: state,
                        onTap: {
                            navigationPath.append(NavigationTarget.source(source.id))
                        },
                        onRefresh: {
                            Task {
                                await coordinator.refreshSingleSource(source)
                                await loadSources()
                            }
                        },
                        onEditName: {
                            renameText = source.title
                            renamingSource = source
                        },
                        onRemove: {
                            Task { await removeSource(source) }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.accent.opacity(highlightedSourceID == source.id ? 0.15 : 0))
                            .animation(Theme.reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.5).repeatCount(2, autoreverses: true), value: highlightedSourceID)
                            .allowsHitTesting(false)
                            .padding(.horizontal, 16)
                    )
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 80))
                .foregroundStyle(Theme.accentGradient)
                .symbolEffect(.pulse, options: .repeating, isActive: !Theme.reduceMotion)

            Text("Your library is empty")
                .font(Theme.scaledFont(size: 22, weight: .bold, relativeTo: .title2))
                .foregroundColor(Theme.textPrimary)

            Text("Add a site to get started...")
                .font(Theme.scaledFont(size: 15, relativeTo: .subheadline))
                .foregroundColor(Theme.textSecondary)

            Button {
                showAddSource = true
            } label: {
                Text("Add your first source")
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.accentGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Nav refresh button

    private var navRefreshButton: some View {
        let isRefreshing = coordinator.isFetching
        return ZStack {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .opacity(isRefreshing ? 0 : 1)
                .scaleEffect(isRefreshing ? 0.5 : 1)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRefreshing)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
                ZStack {
                    Circle()
                        .stroke(Theme.borderProminent, lineWidth: 2)
                        .frame(width: 20, height: 20)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(
                                colors: [Theme.accent.opacity(0.6), Theme.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(angle))
                }
            }
            .opacity(isRefreshing ? 1 : 0)
            .scaleEffect(isRefreshing ? 1 : 0.5)
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
    }

    // MARK: - Logomark

    private var logomark: some View {
        Image(systemName: "square.stack.3d.down.right.fill")
            .font(.system(size: 20))
            .foregroundStyle(Theme.accentGradient)
    }

    // MARK: - Data loading

    private func loadSources() async {
        do {
            let loadedSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
            }
            sources = loadedSources

            // Load saved article count and unread count
            let (saved, savedUnread) = try await DatabaseManager.shared.dbPool.read { db in
                let total = try Article
                    .filter(Column("isSaved") == true)
                    .fetchCount(db)
                let unread = try Article
                    .filter(Column("isSaved") == true)
                    .filter(Column("isRead") == false)
                    .fetchCount(db)
                return (total, unread)
            }
            savedCount = saved
            savedUnreadCount = savedUnread

            // Load article counts and unread counts
            var counts: [UUID: Int] = [:]
            var unread: [UUID: Int] = [:]
            for source in loadedSources {
                let (total, unreadCount) = try await DatabaseManager.shared.dbPool.read { db in
                    let total = try Article
                        .filter(Column("sourceID") == source.id)
                        .fetchCount(db)
                    let unreadCount = try Article
                        .filter(Column("sourceID") == source.id)
                        .filter(Column("isRead") == false)
                        .fetchCount(db)
                    return (total, unreadCount)
                }
                counts[source.id] = total
                unread[source.id] = unreadCount
            }
            articleCounts = counts
            unreadCounts = unread
        } catch {
            // Silently fail — sources will remain as last loaded
        }
    }

    // MARK: - Live count polling

    private func startCountPolling() {
        guard countPollTask == nil else { return }
        countPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await refreshCounts()
            }
        }
    }

    private func stopCountPolling() {
        countPollTask?.cancel()
        countPollTask = nil
    }

    private func refreshCounts() async {
        do {
            var counts: [UUID: Int] = [:]
            var unread: [UUID: Int] = [:]
            for source in sources {
                let (total, unreadCount) = try await DatabaseManager.shared.dbPool.read { db in
                    let total = try Article
                        .filter(Column("sourceID") == source.id)
                        .fetchCount(db)
                    let unreadCount = try Article
                        .filter(Column("sourceID") == source.id)
                        .filter(Column("isRead") == false)
                        .fetchCount(db)
                    return (total, unreadCount)
                }
                counts[source.id] = total
                unread[source.id] = unreadCount
            }
            articleCounts = counts
            unreadCounts = unread

            // Refresh saved counts
            let (saved, savedUnread) = try await DatabaseManager.shared.dbPool.read { db in
                let total = try Article
                    .filter(Column("isSaved") == true)
                    .fetchCount(db)
                let unread = try Article
                    .filter(Column("isSaved") == true)
                    .filter(Column("isRead") == false)
                    .fetchCount(db)
                return (total, unread)
            }
            savedCount = saved
            savedUnreadCount = savedUnread
        } catch {
            // Silently fail
        }
    }

    // MARK: - Remove source

    private func removeSource(_ source: Source) async {
        HapticManager.deleteConfirm()

        do {
            // Move saved articles to the hidden "Saved Pages" source so they
            // survive the CASCADE delete that follows. Stamp original source
            // info so attribution is preserved after the source is deleted.
            try await DatabaseManager.shared.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE article
                        SET sourceID = ?,
                            originalSourceName = COALESCE(originalSourceName, ?),
                            originalSourceIconURL = COALESCE(originalSourceIconURL, ?)
                        WHERE sourceID = ? AND isSaved = 1
                        """,
                    arguments: [Source.savedPagesID, source.title, source.iconURL, source.id]
                )
            }

            // Delete cached files for unsaved articles only (saved ones were moved)
            let articles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .fetchAll(db)
            }
            for article in articles {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
            }

            // Delete cached source data (favicon, etc.)
            try? await PageCacheService.shared.deleteSourceCache(source.id)

            // Delete source (cascades to remaining unsaved articles + cachedPages)
            _ = try await DatabaseManager.shared.dbPool.write { db in
                try Source.deleteOne(db, key: source.id)
            }

            // Reload saved count (moved articles may have changed it)
            let newSavedCount = try await DatabaseManager.shared.dbPool.read { db in
                try Article.filter(Column("isSaved") == true).fetchCount(db)
            }

            withAnimation(Theme.gentleAnimation()) {
                sources.removeAll { $0.id == source.id }
                articleCounts.removeValue(forKey: source.id)
                unreadCounts.removeValue(forKey: source.id)
                savedCount = newSavedCount
            }
        } catch {
            toastManager.show("Couldn't remove source", type: .error)
        }
    }

    // MARK: - Rename source

    private func renameSource(_ source: Source, to newName: String) async {
        var updated = source
        updated.title = newName
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updated.update(db)
            }
            await loadSources()
        } catch {
            toastManager.show("Couldn't rename source", type: .error)
        }
    }

    // MARK: - Sort order

    private func saveSortOrder() async {
        let orderedSources = sources
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                for (index, var source) in orderedSources.enumerated() {
                    source.sortOrder = index
                    try source.update(db)
                }
            }
        } catch {
            // Sort order save failed silently
        }
    }

    // MARK: - Failure handling

    private func checkForFailures() {
        let failedCount = coordinator.sourceStatuses.values.filter { $0 == .failed }.count
        let totalCount = coordinator.sourceStatuses.count

        if failedCount == totalCount && totalCount > 0 {
            toastManager.showOffline()
        }
    }
}

#Preview {
    SourcesListView()
        .environmentObject(ToastManager.shared)
        .environmentObject(DeepLinkRouter())
}
