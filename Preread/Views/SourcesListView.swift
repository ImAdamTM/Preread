import SwiftUI
import GRDB

struct SourcesListView: View {
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var toastManager: ToastManager
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var sources: [Source] = []
    @State private var articleCounts: [UUID: Int] = [:]
    @State private var showAddSource = false
    @State private var highlightedSourceID: UUID?
    @State private var navigationPath = NavigationPath()
    @State private var renamingSource: Source?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Theme.background.ignoresSafeArea()

                if sources.isEmpty {
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
            .refreshable {
                HapticManager.pullToRefresh()
                await coordinator.refreshAllSources()
                await loadSources()
            }
            .onChange(of: coordinator.isFetching) { _, isFetching in
                if !isFetching {
                    Task { await loadSources() }
                    checkForFailures()
                }
            }
            .onChange(of: coordinator.sourceStatuses) { _, statuses in
                // Reload when any individual source finishes (e.g. after adding a new feed)
                let hasCompleted = statuses.values.contains { $0 == .completed }
                if hasCompleted {
                    Task { await loadSources() }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet { addedSourceID in
                    Task {
                        await loadSources()
                        highlightedSourceID = addedSourceID
                        try? await Task.sleep(for: .seconds(1))
                        highlightedSourceID = nil
                    }
                }
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
            .navigationDestination(for: UUID.self) { sourceID in
                if let source = sources.first(where: { $0.id == sourceID }) {
                    ArticleListView(source: source)
                }
            }
            .onChange(of: deepLinkRouter.pendingSourceID) { _, sourceID in
                guard let sourceID else { return }
                navigationPath = NavigationPath()
                navigationPath.append(sourceID)
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
                    navigationPath.append(article.sourceID)
                    // pendingArticleID stays set — ArticleListView picks it up
                }
            }
        }
    }

    // MARK: - Sources list

    private var sourcesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    let state = coordinator.sourceStatuses[source.id] ?? .idle

                    SourceCardView(
                        source: source,
                        articleCount: articleCounts[source.id] ?? 0,
                        refreshState: state,
                        onTap: {
                            navigationPath.append(source.id)
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
                    .draggable(source.id.uuidString) {
                        // Drag preview
                        SourceCardView(
                            source: source,
                            articleCount: articleCounts[source.id] ?? 0,
                            refreshState: .idle,
                            onTap: {},
                            onRefresh: {},
                            onEditName: {},
                            onRemove: {}
                        )
                        .scaleEffect(Theme.reduceMotion ? 1.0 : 1.04)
                        .rotationEffect(.degrees(Theme.reduceMotion ? 0 : 2))
                        .shadow(color: .black.opacity(0.3), radius: 12)
                        .onAppear { HapticManager.cardLift() }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let draggedIDString = items.first,
                              let draggedID = UUID(uuidString: draggedIDString),
                              let fromIndex = sources.firstIndex(where: { $0.id == draggedID }),
                              fromIndex != index else { return false }

                        withAnimation(Theme.gentleAnimation()) {
                            sources.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: index > fromIndex ? index + 1 : index)
                        }
                        HapticManager.cardDrop()
                        Task { await saveSortOrder() }
                        return true
                    }
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
                try Source.order(Column("sortOrder")).fetchAll(db)
            }
            sources = loadedSources

            // Load article counts
            var counts: [UUID: Int] = [:]
            for source in loadedSources {
                let count = try await DatabaseManager.shared.dbPool.read { db in
                    try Article
                        .filter(Column("sourceID") == source.id)
                        .fetchCount(db)
                }
                counts[source.id] = count
            }
            articleCounts = counts
        } catch {
            // Silently fail — sources will remain as last loaded
        }
    }

    // MARK: - Remove source

    private func removeSource(_ source: Source) async {
        HapticManager.deleteConfirm()

        do {
            // Delete cached files for all articles in this source
            let articles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .fetchAll(db)
            }
            for article in articles {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
            }

            // Delete source (cascades to articles + cachedPages)
            _ = try await DatabaseManager.shared.dbPool.write { db in
                try Source.deleteOne(db, key: source.id)
            }

            withAnimation(Theme.gentleAnimation()) {
                sources.removeAll { $0.id == source.id }
                articleCounts.removeValue(forKey: source.id)
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
